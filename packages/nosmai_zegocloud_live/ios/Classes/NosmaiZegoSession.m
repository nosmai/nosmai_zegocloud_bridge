#import "NosmaiZegoSession.h"

#import <ZegoExpressEngine/ZegoExpressEngine.h>

/// Room command and stream extra info a broadcaster sets when it ends the live for everyone.
/// Same value as the Android plugin.
static NSString *const kEndMark = @"nosmai_zegocloud_live:end";
static const NSTimeInterval kEndNoticeWait = 0.8;
static NSString *const kErrorDomain = @"nosmai_zegocloud_live";

@implementation NosmaiZegoJoinRequest
@end

@interface NosmaiZegoSession () <ZegoEventHandler>
@end

@implementation NosmaiZegoSession {
  ZegoExpressEngine *_engine;
  unsigned int _engineAppId;
  NSString *_engineAppSign;

  NosmaiZegoJoinRequest *_request;
  NosmaiZegoVideoSource *_source;
  BOOL _loggedIn;
  NSTimeInterval _joinedAt;
  BOOL _foreground;
  BOOL _micMuted;
  BOOL _videoMuted;
  BOOL _speakerMuted;

  // Broadcaster.
  ZegoPublisherState _publisherState;
  BOOL _capturing;
  NSNumber *_reportedSending;
  ZegoPublishStreamQuality *_publishQuality;

  // Viewer.
  NSMutableArray<ZegoStream *> *_roomStreams;  // Arrival order, newest last.
  /// Streams that failed to play (e.g. left behind by a crashed broadcaster) until they show video.
  NSMutableSet<NSString *> *_failedStreams;
  ZegoStream *_playing;
  ZegoPlayerState _playerState;
  BOOL _firstFrameShown;
  BOOL _remoteCameraOn;
  UIView *_remoteView;
  ZegoPlayStreamQuality *_playQuality;
  CGSize _playSize;
  NSArray *_reportedRemote;

  // Both.
  NSMutableSet<NSString *> *_others;
  int _onlineCount;
  /// Identifies the pending end-of-live fallback; nil when not leaving.
  NSObject *_leavingToken;
}

+ (instancetype)shared {
  static NosmaiZegoSession *session;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ session = [[NosmaiZegoSession alloc] init]; });
  return session;
}

- (instancetype)init {
  if ((self = [super init])) {
    _emit = ^(NSDictionary *event) {};
    _onLeft = ^(NosmaiZegoJoinRequest *request) {};
    _roomStreams = [NSMutableArray array];
    _failedStreams = [NSMutableSet set];
    _others = [NSMutableSet set];
    [self resetState];
  }
  return self;
}

- (NosmaiZegoJoinRequest *)request {
  return _request;
}

- (BOOL)active {
  return _request != nil;
}

- (BOOL)ownsEngine:(ZegoExpressEngine *)engine {
  return engine != nil && _engine == engine;
}

- (NSString *)sdkVersion {
  return [ZegoExpressEngine getVersion] ?: @"";
}

#pragma mark - Engine

static NSError *BridgeError(NSString *code, NSString *message) {
  return [NSError errorWithDomain:kErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey : message, @"code" : code}];
}

/// Creates the engine for appId/appSign, replacing one made for other credentials.
- (ZegoExpressEngine *)ensureEngineWithAppId:(unsigned int)appId appSign:(NSString *)appSign error:(NSError **)error {
  if (_engine && _engine == [ZegoExpressEngine sharedEngine] && _engineAppId == appId && [_engineAppSign isEqualToString:appSign]) return _engine;
  [self releaseEngine];
  ZegoEngineProfile *profile = [[ZegoEngineProfile alloc] init];
  profile.appID = appId;
  profile.appSign = appSign;
  profile.scenario = ZegoScenarioBroadcast;
  ZegoExpressEngine *created = [ZegoExpressEngine createEngineWithProfile:profile eventHandler:self];
  if (!created) {
    if (error) *error = BridgeError(@"start_failed", @"ZEGOCLOUD engine could not be created.");
    return nil;
  }
  _engine = created;
  _engineAppId = appId;
  _engineAppSign = [appSign copy];
  return created;
}

- (void)releaseEngine {
  if (_engine == nil || _request != nil) return;
  NSLog(@"[NosmaiZegoLive] Releasing the idle ZEGO engine");
  if (_engine == [ZegoExpressEngine sharedEngine]) [ZegoExpressEngine destroyEngine:nil];
  _engine = nil;
  _engineAppSign = nil;
  _engineAppId = 0;
}

- (void)releaseNow {
  if (_request == nil) [self releaseEngine];
}

- (BOOL)renewToken:(NSString *)token sessionId:(NSNumber *)sessionId error:(NSError **)error {
  NosmaiZegoJoinRequest *current = _request;
  if (current == nil || (sessionId != nil && current.sessionId != sessionId.longLongValue) || _engine == nil) {
    if (error) *error = BridgeError(@"not_active", @"No ZEGOCLOUD session is active.");
    return NO;
  }
  [_engine renewToken:token roomID:current.roomId];
  return YES;
}

#pragma mark - Join and leave

- (BOOL)join:(NosmaiZegoJoinRequest *)join source:(NosmaiZegoVideoSource *)videoSource error:(NSError **)error {
  // Dart allows one active session at a time, so one still here was abandoned (its Dart side is
  // gone). The newest caller wins: end the old one and tell its listeners.
  if (_request) {
    NSLog(@"[NosmaiZegoLive] Replacing abandoned session %lld with %lld", _request.sessionId, join.sessionId);
    [self finishLeaveWithReason:@"Replaced"];
  }
  if (join.host && videoSource == nil) {
    if (error) *error = BridgeError(@"start_failed", @"No video source.");
    return NO;
  }
  ZegoExpressEngine *zego = [self ensureEngineWithAppId:join.appId appSign:join.appSign error:error];
  if (!zego) return NO;
  [self resetState];
  _request = join;
  _source = join.host ? videoSource : nil;
  _micMuted = join.micMuted;
  _videoMuted = join.videoMuted;
  _speakerMuted = join.speakerMuted;

  if (join.host) {
    [self configurePublisher:zego request:join source:videoSource];
  } else {
    [zego muteSpeaker:join.speakerMuted];
  }

  ZegoUser *user = [ZegoUser userWithUserID:join.userId userName:join.userName];
  ZegoRoomConfig *config = [ZegoRoomConfig defaultConfig];
  config.isUserStatusNotify = YES;
  config.token = join.token ?: @"";
  [zego loginRoom:join.roomId
             user:user
           config:config
         callback:^(int code, NSDictionary *extendedData) {
           [self onLoginResult:join code:code];
         }];
  return YES;
}

- (void)configurePublisher:(ZegoExpressEngine *)zego
                   request:(NosmaiZegoJoinRequest *)join
                    source:(NosmaiZegoVideoSource *)source {
  // Custom capture can only change outside a room; it is set before every login.
  ZegoCustomVideoCaptureConfig *capture = [[ZegoCustomVideoCaptureConfig alloc] init];
  capture.bufferType = ZegoVideoBufferTypeCVPixelBuffer;
  [zego enableCustomVideoCapture:YES config:capture channel:ZegoPublishChannelMain];
  source.engine = zego;
  [zego setCustomVideoCaptureHandler:source];
  // Nosmai frames are 9:16 like the encode size; never crop if a size differs slightly.
  [zego setCustomVideoCaptureFillMode:ZegoViewModeAspectFit channel:ZegoPublishChannelMain];
  // A previous live on this stream ID may have left the end mark behind.
  [zego setStreamExtraInfo:@"" callback:nil];
  // Viewers must see exactly the Nosmai preview, as rendered.
  [zego setVideoMirrorMode:ZegoVideoMirrorModeNoMirror];
  ZegoVideoConfig *video = [ZegoVideoConfig defaultConfig];
  video.captureResolution = CGSizeMake(join.encodeWidth, join.encodeHeight);
  video.encodeResolution = CGSizeMake(join.encodeWidth, join.encodeHeight);
  video.fps = join.fps;
  video.bitrate = join.bitrateKbps;
  [zego setVideoConfig:video];
  // Bad network: keep the frame rate and lower resolution, or let ZEGO lower both.
  ZegoTrafficControlProperty property =
      join.prioritizeFrameRate ? ZegoTrafficControlPropertyAdaptiveResolution
                               : (ZegoTrafficControlPropertyAdaptiveFPS | ZegoTrafficControlPropertyAdaptiveResolution);
  [zego enableTrafficControl:YES property:property];
  [zego enableAudioCaptureDevice:join.publishAudio];
  [zego mutePublishStreamAudio:(join.micMuted || !join.publishAudio)];
  [zego mutePublishStreamVideo:join.videoMuted];
  [source setPaused:join.videoMuted];
}

- (void)onLoginResult:(NosmaiZegoJoinRequest *)join code:(int)code {
  if (_request != join) return;  // Left while logging in.
  if (code != 0) {
    NSLog(@"[NosmaiZegoLive] loginRoom failed: %d", code);
    NSString *message = [NosmaiZegoSession describeError:code];
    [self cleanUpEngine:join];
    [self resetState];
    [self releaseEngine];
    [self send:@{@"type" : @"error", @"code" : @(code), @"message" : message, @"fatal" : @YES}
       session:@(join.sessionId)];
    // The plugin stops the video source as for any ended session.
    self.onLeft(join);
    return;
  }
  _loggedIn = YES;
  _joinedAt = [NSDate timeIntervalSinceReferenceDate];
  [self send:@{@"type" : @"joined"}];
  ZegoExpressEngine *zego = _engine;
  if (!zego) return;
  if (join.host) {
    if (join.streamId) [zego startPublishingStream:join.streamId channel:ZegoPublishChannelMain];
  } else {
    [self refreshPlayback];
  }
}

/// Leaves the room. A broadcaster with endSession first tells viewers the live is over, so they
/// stop instead of waiting for a new broadcaster. `left` follows.
- (void)leaveSession:(NSNumber *)sessionId endSession:(BOOL)endSession {
  NosmaiZegoJoinRequest *current = _request;
  if (current == nil || (sessionId != nil && current.sessionId != sessionId.longLongValue)) {
    // Not this session's to end (already over, or a newer session is active): confirm at once so
    // Dart never waits, and leave any newer session alone.
    [self send:@{@"type" : @"left", @"reason" : @"BySelf"} session:sessionId];
    return;
  }
  if (_leavingToken) return;
  ZegoExpressEngine *zego = _engine;
  if (current.host && endSession && _loggedIn && zego != nil) {
    // Two signals: a room command (instant, unreliable) and the stream's extra info (kept by the
    // server, so viewers also see it on the stream's removal). Never wait long.
    NSObject *token = [[NSObject alloc] init];
    _leavingToken = token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEndNoticeWait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     if (self->_leavingToken == token) [self finishLeaveWithReason:@"BySelf"];
                   });
    __block int pending = 2;
    void (^done)(int) = ^(int code) {
      if (code != 0) NSLog(@"[NosmaiZegoLive] End-of-live notice failed: %d", code);
      dispatch_async(dispatch_get_main_queue(), ^{
        if (--pending == 0 && self->_leavingToken == token) [self finishLeaveWithReason:@"BySelf"];
      });
    };
    [zego setStreamExtraInfo:kEndMark callback:^(int code) { done(code); }];
    [zego sendCustomCommand:kEndMark toUserList:nil roomID:current.roomId callback:^(int code) { done(code); }];
    return;
  }
  [self finishLeaveWithReason:@"BySelf"];
}

- (void)finishLeaveWithReason:(NSString *)reason {
  NosmaiZegoJoinRequest *current = _request;
  if (!current) return;
  _leavingToken = nil;
  [self cleanUpEngine:current];
  [self resetState];
  [self send:@{@"type" : @"left", @"reason" : reason} session:@(current.sessionId)];
  self.onLeft(current);
  [self releaseEngine];
}

/// Viewer: stream is the watched broadcaster's and carries the end mark. Ends the live.
- (BOOL)endedLive:(ZegoStream *)stream {
  NosmaiZegoJoinRequest *current = _request;
  if (!current || current.host || ![stream.extraInfo isEqualToString:kEndMark]) return NO;
  if (![stream.streamID isEqualToString:_playing.streamID]) {
    // An ended stream still listed (e.g. a leftover): never pick it.
    if (stream.streamID) [_failedStreams addObject:stream.streamID];
    return NO;
  }
  [self finishLeaveWithReason:@"EndByHost"];
  return YES;
}

- (void)send:(NSDictionary<NSString *, id> *)event {
  [self send:event session:_request ? @(_request.sessionId) : nil];
}

- (void)send:(NSDictionary<NSString *, id> *)event session:(NSNumber *)sessionId {
  NSMutableDictionary *tagged = [event mutableCopy];
  tagged[@"session"] = sessionId ?: [NSNull null];
  self.emit(tagged);
}

- (void)cleanUpEngine:(NosmaiZegoJoinRequest *)current {
  ZegoExpressEngine *zego = _engine;
  if (!zego) return;
  if (current.host) {
    [zego stopPublishingStream];
    [zego mutePublishStreamAudio:NO];
    [zego mutePublishStreamVideo:NO];
    [zego enableAudioCaptureDevice:YES];
  } else {
    if (_playing.streamID) [zego stopPlayingStream:_playing.streamID];
    [zego muteSpeaker:NO];
  }
  [zego logoutRoom:current.roomId];
  if (current.host) {
    [zego setCustomVideoCaptureHandler:nil];
    [zego enableCustomVideoCapture:NO config:nil channel:ZegoPublishChannelMain];
  }
  // The plugin shuts the video source down when onLeft runs.
}

#pragma mark - Media state

- (void)setMicMuted:(BOOL)muted {
  _micMuted = muted;
  [self applyMedia];
}

- (void)setVideoMuted:(BOOL)muted {
  _videoMuted = muted;
  [self applyMedia];
}

- (void)setSpeakerMuted:(BOOL)muted {
  _speakerMuted = muted;
  [self applyMedia];
}

/// Backgrounded: stop sending (broadcaster) or receiving (viewer) until foregrounded.
- (void)setForeground:(BOOL)foreground {
  if (_foreground == foreground) return;
  _foreground = foreground;
  [self applyMedia];
}

- (void)applyMedia {
  NosmaiZegoJoinRequest *current = _request;
  ZegoExpressEngine *zego = _engine;
  if (!current || !zego) return;
  if (current.host) {
    BOOL stopVideo = _videoMuted || !_foreground;
    [_source setPaused:stopVideo];
    [zego mutePublishStreamVideo:stopVideo];
    [zego mutePublishStreamAudio:(_micMuted || !_foreground || !current.publishAudio)];
  } else {
    [zego muteSpeaker:_speakerMuted];
    NSString *streamId = _playing.streamID;
    if (streamId) {
      [zego mutePlayStreamVideo:!_foreground streamID:streamId];
      [zego mutePlayStreamAudio:!_foreground streamID:streamId];
    }
    [self reportRemote];
  }
}

#pragma mark - Broadcaster

/// From the video source (main thread): ZEGO started or stopped asking for frames.
- (void)onCapturingChanged {
  NosmaiZegoJoinRequest *current = _request;
  if (!current || !current.host) return;
  // Read the source itself: a late notice from a previous broadcast must not count.
  _capturing = _source.isCapturing;
  [self reportSending];
}

- (void)onPublisherState:(ZegoPublisherState)state code:(int)code streamId:(NSString *)streamId {
  NosmaiZegoJoinRequest *current = _request;
  if (!current || !current.host || ![streamId isEqualToString:current.streamId]) return;
  _publisherState = state;
  NSLog(@"[NosmaiZegoLive] Publisher state %lu (%d)", (unsigned long)state, code);
  if (code == 0) {
    // Fine.
  } else if (state == ZegoPublisherStateNoPublish) {
    [self send:@{
      @"type" : @"error",
      @"code" : @(code),
      @"message" : [NosmaiZegoSession describeError:code],
      @"fatal" : @YES,
    }];
  } else {
    // ZEGO keeps retrying (PublishRequesting) on network trouble.
    [self warn:[NSString stringWithFormat:@"Publishing is retrying: %@", [NosmaiZegoSession describeError:code]]];
  }
  [self reportSending];
}

- (void)reportSending {
  // A real BOOL: a C expression like `a && b` would box as an int, which Dart does not read as true.
  BOOL sending = _capturing && _publisherState == ZegoPublisherStatePublishing;
  NSNumber *on = [NSNumber numberWithBool:sending];
  if (_reportedSending && [_reportedSending isEqualToNumber:on]) return;
  _reportedSending = on;
  [self send:@{@"type" : @"sending", @"on" : on}];
}

#pragma mark - Viewer

- (void)attachRemoteView:(UIView *)view {
  _remoteView = view;
  NSString *streamId = _playing.streamID;
  if (!streamId) return;
  [_engine startPlayingStream:streamId canvas:[self canvasFor:view]];
}

- (void)detachRemoteView:(UIView *)view {
  if (_remoteView != view) return;
  _remoteView = nil;
  NSString *streamId = _playing.streamID;
  if (!streamId || !_engine) return;
  // Keep the audio; drop only the picture.
  [_engine startPlayingStream:streamId canvas:nil];
  _firstFrameShown = NO;
  [self reportRemote];
}

- (ZegoCanvas *)canvasFor:(UIView *)view {
  ZegoCanvas *canvas = [ZegoCanvas canvasWithView:view];
  canvas.viewMode = ZegoViewModeAspectFit;
  return canvas;
}

/// Plays the stream to watch, switching when it changes, and reports what is shown.
- (void)refreshPlayback {
  NosmaiZegoJoinRequest *current = _request;
  if (!current || current.host || !_loggedIn) return;
  ZegoExpressEngine *zego = _engine;
  if (!zego) return;
  ZegoStream *target = [self pickStream:current];
  if (!(target.streamID == _playing.streamID || [target.streamID isEqualToString:_playing.streamID])) {
    if (_playing.streamID) [zego stopPlayingStream:_playing.streamID];
    _playing = target;
    _playerState = ZegoPlayerStateNoPlay;
    _firstFrameShown = NO;
    _remoteCameraOn = YES;
    _playQuality = nil;
    _playSize = CGSizeZero;
    NSString *streamId = target.streamID;
    if (streamId) {
      if (_remoteView) {
        [zego startPlayingStream:streamId canvas:[self canvasFor:_remoteView]];
      } else {
        [zego startPlayingStream:streamId];
      }
      if (!_foreground) {
        [zego mutePlayStreamVideo:YES streamID:streamId];
        [zego mutePlayStreamAudio:YES streamID:streamId];
      }
    }
  }
  [self reportRemote];
}

/// The stream to watch: the requested stream ID, else the requested user's, else the newest
/// stream that has not failed. A stream a crashed broadcaster left behind stays listed until
/// ZEGOCLOUD times it out, so the newest working one is the likely live one.
- (ZegoStream *)pickStream:(NosmaiZegoJoinRequest *)current {
  NSMutableArray<ZegoStream *> *streams = [NSMutableArray array];
  for (ZegoStream *stream in _roomStreams) {
    if ([stream.user.userID isEqualToString:current.userId]) continue;
    if ([stream.extraInfo isEqualToString:kEndMark]) continue;
    [streams addObject:stream];
  }
  if (current.streamId) {
    for (ZegoStream *stream in [streams reverseObjectEnumerator]) {
      if ([stream.streamID isEqualToString:current.streamId]) return stream;
    }
    return nil;
  }
  NSArray<ZegoStream *> *candidates = streams;
  if (current.hostUserId) {
    NSMutableArray *theirs = [NSMutableArray array];
    for (ZegoStream *stream in streams) {
      if ([stream.user.userID isEqualToString:current.hostUserId]) [theirs addObject:stream];
    }
    candidates = theirs;
  }
  for (ZegoStream *stream in [candidates reverseObjectEnumerator]) {
    if (![_failedStreams containsObject:stream.streamID]) return stream;
  }
  return candidates.lastObject;
}

- (void)onPlayerState:(ZegoPlayerState)state code:(int)code streamId:(NSString *)streamId {
  NosmaiZegoJoinRequest *current = _request;
  if (!current || current.host || ![streamId isEqualToString:_playing.streamID]) return;
  _playerState = state;
  NSLog(@"[NosmaiZegoLive] Player state %lu (%d)", (unsigned long)state, code);
  if (state != ZegoPlayerStatePlaying) _firstFrameShown = NO;
  if (code != 0) {
    if (streamId) [_failedStreams addObject:streamId];
    NSString *before = _playing.streamID;
    [self refreshPlayback];  // Moves to another stream if one has not failed.
    if (![_playing.streamID isEqualToString:before]) return;
    [self warn:[NSString stringWithFormat:@"Playing the broadcaster's stream: %@",
                                          [NosmaiZegoSession describeError:code]]];
  }
  [self reportRemote];
}

- (void)reportRemote {
  NosmaiZegoJoinRequest *current = _request;
  if (!current || current.host) return;
  ZegoStream *stream = _playing;
  BOOL on = stream != nil && _loggedIn && _foreground && _remoteView != nil &&
            _playerState == ZegoPlayerStatePlaying && _firstFrameShown && _remoteCameraOn;
  NSArray *next = @[ stream.streamID ?: [NSNull null], stream.user.userID ?: [NSNull null], @(on) ];
  if (_reportedRemote && [next isEqualToArray:_reportedRemote]) return;
  _reportedRemote = next;
  [self send:@{
    @"type" : @"remoteVideo",
    @"streamId" : stream.streamID ?: [NSNull null],
    @"userId" : stream.user.userID ?: [NSNull null],
    @"userName" : stream.user.userName ?: [NSNull null],
    @"on" : @(on),
  }];
}

#pragma mark - ZegoEventHandler (main thread)

- (BOOL)isMyRoom:(NSString *)roomID {
  return _request != nil && [roomID isEqualToString:_request.roomId];
}

- (void)onRoomStateChanged:(ZegoRoomStateChangedReason)reason
                 errorCode:(int)errorCode
              extendedData:(NSDictionary *)extendedData
                    roomID:(NSString *)roomID {
  NosmaiZegoJoinRequest *current = _request;
  if (!current || ![roomID isEqualToString:current.roomId]) return;
  NSLog(@"[NosmaiZegoLive] Room state %lu (%d)", (unsigned long)reason, errorCode);
  switch (reason) {
    case ZegoRoomStateChangedReasonReconnecting:
      if (_loggedIn) [self send:@{@"type" : @"reconnecting"}];
      break;
    case ZegoRoomStateChangedReasonReconnected:
      if (_loggedIn) [self send:@{@"type" : @"reconnected"}];
      break;
    case ZegoRoomStateChangedReasonReconnectFailed:
      [self finishLeaveWithReason:@"NetworkError"];
      break;
    case ZegoRoomStateChangedReasonKickOut:
      [self finishLeaveWithReason:(errorCode == ZegoErrorCodeRoomKickedOut ? @"SignedInElsewhere" : @"KickedOut")];
      break;
    default:
      break;  // Login results arrive through the loginRoom callback.
  }
}

- (void)onRoomUserUpdate:(ZegoUpdateType)updateType userList:(NSArray<ZegoUser *> *)userList roomID:(NSString *)roomID {
  if (![self isMyRoom:roomID]) return;
  for (ZegoUser *user in userList) {
    if (!user.userID || [user.userID isEqualToString:_request.userId]) continue;
    if (updateType == ZegoUpdateTypeAdd) {
      [_others addObject:user.userID];
    } else {
      [_others removeObject:user.userID];
    }
  }
}

- (void)onRoomOnlineUserCountUpdate:(int)count roomID:(NSString *)roomID {
  if ([self isMyRoom:roomID]) _onlineCount = count;
}

- (void)onRoomStreamUpdate:(ZegoUpdateType)updateType
                streamList:(NSArray<ZegoStream *> *)streamList
              extendedData:(NSDictionary *)extendedData
                    roomID:(NSString *)roomID {
  if (![self isMyRoom:roomID]) return;
  for (ZegoStream *stream in streamList) {
    NSString *streamId = stream.streamID;
    if (!streamId) continue;
    if (updateType != ZegoUpdateTypeAdd && [self endedLive:stream]) return;
    // Re-insert so the list stays in arrival order (newest last).
    [self removeRoomStream:streamId];
    [_failedStreams removeObject:streamId];
    if (updateType == ZegoUpdateTypeAdd) [_roomStreams addObject:stream];
  }
  [self refreshPlayback];
}

- (void)removeRoomStream:(NSString *)streamId {
  for (NSInteger i = (NSInteger)_roomStreams.count - 1; i >= 0; i--) {
    if ([_roomStreams[(NSUInteger)i].streamID isEqualToString:streamId]) [_roomStreams removeObjectAtIndex:(NSUInteger)i];
  }
}

- (void)onRoomStreamExtraInfoUpdate:(NSArray<ZegoStream *> *)streamList roomID:(NSString *)roomID {
  if (![self isMyRoom:roomID]) return;
  for (ZegoStream *stream in streamList) {
    if ([self endedLive:stream]) return;
    for (ZegoStream *known in _roomStreams) {
      if ([known.streamID isEqualToString:stream.streamID]) known.extraInfo = stream.extraInfo;
    }
  }
}

- (void)onRoomTokenWillExpire:(int)remainTimeInSecond roomID:(NSString *)roomID {
  if ([self isMyRoom:roomID]) [self send:@{@"type" : @"tokenWillExpire", @"seconds" : @(remainTimeInSecond)}];
}

- (void)onPublisherStateUpdate:(ZegoPublisherState)state
                     errorCode:(int)errorCode
                  extendedData:(NSDictionary *)extendedData
                      streamID:(NSString *)streamID {
  [self onPublisherState:state code:errorCode streamId:streamID];
}

- (void)onPublisherQualityUpdate:(ZegoPublishStreamQuality *)quality streamID:(NSString *)streamID {
  if (_request.host) _publishQuality = quality;
}

- (void)onPlayerStateUpdate:(ZegoPlayerState)state
                  errorCode:(int)errorCode
               extendedData:(NSDictionary *)extendedData
                   streamID:(NSString *)streamID {
  [self onPlayerState:state code:errorCode streamId:streamID];
}

- (void)onPlayerQualityUpdate:(ZegoPlayStreamQuality *)quality streamID:(NSString *)streamID {
  if ([streamID isEqualToString:_playing.streamID]) _playQuality = quality;
}

- (void)onPlayerRenderVideoFirstFrame:(NSString *)streamID {
  if (![streamID isEqualToString:_playing.streamID]) return;
  _firstFrameShown = YES;
  [_failedStreams removeObject:streamID];
  [self reportRemote];
}

- (void)onPlayerVideoSizeChanged:(CGSize)size streamID:(NSString *)streamID {
  if ([streamID isEqualToString:_playing.streamID]) _playSize = size;
}

- (void)onRemoteCameraStateUpdate:(ZegoRemoteDeviceState)state streamID:(NSString *)streamID {
  if (![streamID isEqualToString:_playing.streamID]) return;
  _remoteCameraOn = state == ZegoRemoteDeviceStateOpen;
  [self reportRemote];
}

- (void)onIMRecvCustomCommand:(NSString *)command fromUser:(ZegoUser *)fromUser roomID:(NSString *)roomID {
  NosmaiZegoJoinRequest *current = _request;
  if (!current || current.host || ![self isMyRoom:roomID] || ![command isEqualToString:kEndMark]) return;
  // Only the broadcaster being watched may end the live for this viewer.
  NSString *from = fromUser.userID;
  if (from && _playing && ![_playing.user.userID isEqualToString:from]) return;
  [self finishLeaveWithReason:@"EndByHost"];
}

- (void)onDebugError:(int)errorCode funcName:(NSString *)funcName info:(NSString *)info {
  NSLog(@"[NosmaiZegoLive] ZEGO %@: %d %@", funcName, errorCode, info);
}

#pragma mark - Stats

- (NSDictionary<NSString *, id> *)stats {
  NosmaiZegoJoinRequest *current = _request;
  NSMutableDictionary *stats = [NSMutableDictionary dictionary];
  stats[@"inRoom"] = @(_loggedIn);
  if (!current || !_loggedIn) return stats;
  stats[@"participants"] = @(MAX(MAX((NSInteger)_others.count, (NSInteger)_onlineCount - 1), 0));
  stats[@"secondsLive"] = @(_joinedAt > 0 ? (long long)([NSDate timeIntervalSinceReferenceDate] - _joinedAt) : 0);
  if (current.host) {
    stats[@"micMuted"] = [NSNumber numberWithBool:(_micMuted || !current.publishAudio)];
    stats[@"width"] = @(current.encodeWidth);
    stats[@"height"] = @(current.encodeHeight);
    ZegoPublishStreamQuality *q = _publishQuality;
    if (q) {
      stats[@"fps"] = @(q.videoSendFPS);
      stats[@"encodeFps"] = @(q.videoEncodeFPS);
      stats[@"bitrateKbps"] = @(MAX(q.videoKBPS, 0.0));
      stats[@"rttMs"] = @(MAX(q.rtt, 0));
      stats[@"lossPercent"] = @(MAX(q.packetLostRate * 100, 0.0));
      stats[@"network"] = [NosmaiZegoSession qualityName:q.level];
      stats[@"hardwareCodec"] = @(q.isHardwareEncode);
    }
  } else {
    stats[@"width"] = @((int)_playSize.width);
    stats[@"height"] = @((int)_playSize.height);
    ZegoPlayStreamQuality *q = _playQuality;
    if (q) {
      stats[@"fps"] = @(q.videoRenderFPS > 0 ? q.videoRenderFPS : q.videoRecvFPS);
      stats[@"bitrateKbps"] = @(MAX(q.videoKBPS, 0.0));
      stats[@"latencyMs"] = @(MAX(q.peerToPeerDelay, 0));
      stats[@"rttMs"] = @(MAX(q.rtt, 0));
      stats[@"lossPercent"] = @(MAX(q.packetLostRate * 100, 0.0));
      stats[@"network"] = [NosmaiZegoSession qualityName:q.level];
      stats[@"hardwareCodec"] = @(q.isHardwareDecode);
    }
  }
  return stats;
}

+ (NSString *)qualityName:(ZegoStreamQualityLevel)level {
  switch (level) {
    case ZegoStreamQualityLevelExcellent:
      return @"Excellent";
    case ZegoStreamQualityLevelGood:
      return @"Good";
    case ZegoStreamQualityLevelMedium:
      return @"Medium";
    case ZegoStreamQualityLevelBad:
      return @"Bad";
    case ZegoStreamQualityLevelDie:
      return @"Down";
    default:
      return @"Unknown";
  }
}

#pragma mark - Helpers

- (void)warn:(NSString *)message {
  NSLog(@"[NosmaiZegoLive] %@", message);
  [self send:@{@"type" : @"warning", @"message" : message}];
}

- (void)resetState {
  _request = nil;
  _source = nil;
  _loggedIn = NO;
  _joinedAt = 0;
  _foreground = YES;
  _publisherState = ZegoPublisherStateNoPublish;
  _capturing = NO;
  _reportedSending = nil;
  _publishQuality = nil;
  [_roomStreams removeAllObjects];
  [_failedStreams removeAllObjects];
  _playing = nil;
  _playerState = ZegoPlayerStateNoPlay;
  _firstFrameShown = NO;
  _remoteCameraOn = YES;
  _playQuality = nil;
  _playSize = CGSizeZero;
  _reportedRemote = nil;
  [_others removeAllObjects];
  _onlineCount = 0;
}

+ (NSString *)describeError:(int)code {
  switch (code) {
    case ZegoErrorCodeEngineAppsignIncorrect:
    case ZegoErrorCodeEngineAppidIncorrectOrNotOnline:
    case ZegoErrorCodeEngineAppsignInvalidLength:
    case ZegoErrorCodeEngineAppsignInvalidCharacter:
      return @"ZEGOCLOUD rejected the AppID or AppSign. Copy both from the same project in the ZEGOCLOUD console.";
    case ZegoErrorCodeRoomErrorAuthenticationFailed:
      return @"ZEGOCLOUD authentication failed. Check the AppID, AppSign or token.";
    case ZegoErrorCodeRoomNoToken:
      return @"This ZEGOCLOUD project needs a token to log in.";
    case ZegoErrorCodeRoomErrorConnectFailed:
    case ZegoErrorCodeRoomErrorLoginTimeout:
      return @"Could not reach ZEGOCLOUD. Check the network.";
    case ZegoErrorCodeRoomRetryTimeout:
      return @"Lost the connection to ZEGOCLOUD.";
    case ZegoErrorCodeRoomErrorExceedMaximumMember:
      return @"The room is full.";
    case ZegoErrorCodeRoomKickedOut:
      return @"Signed out: the same user ID joined from another device.";
    case ZegoErrorCodeRoomUserInBlacklist:
      return @"This user is blocked from the room.";
    case ZegoErrorCodeRoomCountExceed:
      return @"Already in a ZEGOCLOUD room.";
    case ZegoErrorCodePublisherErrorRepetitivePublishStream:
      return @"Another broadcaster is already publishing this stream ID.";
    case ZegoErrorCodePublisherErrorServerForbid:
      return @"ZEGOCLOUD does not allow publishing this stream.";
    default:
      break;
  }
  if (code >= 1002000 && code <= 1002999) return [NSString stringWithFormat:@"ZEGOCLOUD room error %d.", code];
  if (code >= 1003000 && code <= 1003999) return [NSString stringWithFormat:@"ZEGOCLOUD publishing error %d.", code];
  if (code >= 1004000 && code <= 1004999) return [NSString stringWithFormat:@"ZEGOCLOUD playing error %d.", code];
  return [NSString stringWithFormat:@"ZEGOCLOUD error %d.", code];
}

@end
