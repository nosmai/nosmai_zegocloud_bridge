#import "NosmaiZegoLivePlugin.h"

#import <AVFoundation/AVFoundation.h>
#import <mach/mach.h>

#import "NosmaiZegoSession.h"
#import "NosmaiZegoVideoSource.h"

static NSString *const kChannel = @"nosmai_zegocloud_live";

#pragma mark - Remote video platform view

/// Shows the broadcaster through ZEGO's own renderer. Detaches from the session when Flutter
/// releases the view.
@interface NosmaiZegoRemoteVideoView : NSObject <FlutterPlatformView>
@end

@implementation NosmaiZegoRemoteVideoView {
  UIView *_view;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super init])) {
    _view = [[UIView alloc] initWithFrame:frame];
    _view.backgroundColor = UIColor.blackColor;
    _view.clipsToBounds = YES;
    [[NosmaiZegoSession shared] attachRemoteView:_view];
  }
  return self;
}

- (UIView *)view {
  return _view;
}

- (void)dealloc {
  UIView *view = _view;
  void (^detach)(void) = ^{ [[NosmaiZegoSession shared] detachRemoteView:view]; };
  if ([NSThread isMainThread]) {
    detach();
  } else {
    dispatch_async(dispatch_get_main_queue(), detach);
  }
}

@end

@interface NosmaiZegoRemoteVideoFactory : NSObject <FlutterPlatformViewFactory>
@end

@implementation NosmaiZegoRemoteVideoFactory

- (NSObject<FlutterPlatformView> *)createWithFrame:(CGRect)frame
                                    viewIdentifier:(int64_t)viewId
                                         arguments:(id)args {
  return [[NosmaiZegoRemoteVideoView alloc] initWithFrame:frame];
}

- (NSObject<FlutterMessageCodec> *)createArgsCodec {
  return [FlutterStandardMessageCodec sharedInstance];
}

@end

#pragma mark - Plugin

@implementation NosmaiZegoLivePlugin {
  FlutterEventSink _sink;
  BOOL _screenOn;
  void (^_emitter)(NSDictionary<NSString *, id> *);
  // Process CPU sampling.
  CFAbsoluteTime _lastCpuAt;
  double _lastCpuSeconds;
}

// Process-wide, like ZEGO and Nosmai themselves.
static NosmaiZegoVideoSource *sSource;
static NosmaiZegoVideoSource *sAttachedCamera;
static __weak NosmaiZegoLivePlugin *sCameraOwner;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  NosmaiZegoLivePlugin *instance = [[NosmaiZegoLivePlugin alloc] init];
  FlutterMethodChannel *methods = [FlutterMethodChannel methodChannelWithName:kChannel
                                                              binaryMessenger:[registrar messenger]];
  [registrar addMethodCallDelegate:instance channel:methods];
  FlutterEventChannel *events =
      [FlutterEventChannel eventChannelWithName:[kChannel stringByAppendingString:@"/events"]
                                binaryMessenger:[registrar messenger]];
  [events setStreamHandler:instance];
  [registrar registerViewFactory:[[NosmaiZegoRemoteVideoFactory alloc] init]
                          withId:[kChannel stringByAppendingString:@"/remote_video"]];
  [registrar publish:instance];

  __weak NosmaiZegoLivePlugin *weakInstance = instance;
  instance->_emitter = ^(NSDictionary<NSString *, id> *event) {
    void (^deliver)(void) = ^{ [weakInstance onSessionEvent:event]; };
    if ([NSThread isMainThread]) {
      deliver();
    } else {
      dispatch_async(dispatch_get_main_queue(), deliver);
    }
  };
  NosmaiZegoSession *session = [NosmaiZegoSession shared];
  session.emit = instance->_emitter;
  session.onLeft = ^(NosmaiZegoJoinRequest *request) {
    // Main thread, before any newer session's capture start, so it never stops that one.
    if (request.host) [sSource shutdown];
  };
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  // Hot restart or engine teardown: never leave a room or the frame stream running.
  NosmaiZegoSession *session = [NosmaiZegoSession shared];
  void (^emitter)(NSDictionary *) = _emitter;
  void (^teardown)(void) = ^{
    // A new engine (hot restart) may already own the session; leave it alone then.
    [self detachCamera];
    if (session.emit != emitter) return;
    session.emit = ^(NSDictionary *event) {};
    [session leaveSession:nil endSession:NO];
    [session releaseNow];
  };
  if ([NSThread isMainThread]) {
    teardown();
  } else {
    dispatch_async(dispatch_get_main_queue(), teardown);
  }
  [self setScreenOn:NO];
}

#pragma mark - Events

- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
  _sink = events;
  return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
  _sink = nil;
  return nil;
}

- (void)onSessionEvent:(NSDictionary<NSString *, id> *)event {
  NSString *type = event[@"type"];
  if ([type isEqualToString:@"joined"]) {
    if ([NosmaiZegoSession shared].request.keepScreenOn) [self setScreenOn:YES];
  } else if ([type isEqualToString:@"left"] || [type isEqualToString:@"error"]) {
    if (![NosmaiZegoSession shared].active) [self setScreenOn:NO];
  }
  if (_sink) _sink(event);
}

#pragma mark - Methods

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
  NosmaiZegoSession *session = [NosmaiZegoSession shared];
  NSString *method = call.method;
  @try {
    if ([method isEqualToString:@"prepare"]) {
      // iOS needs no shared GPU context: Nosmai hands over CVPixelBuffers.
      result(@{@"sharedContext" : @NO, @"nosmaiAlreadyInitialized" : @NO});
    } else if ([method isEqualToString:@"requestPermissions"]) {
      [self requestPermissionsWithCamera:![args[@"camera"] isEqual:@NO] result:result];
    } else if ([method isEqualToString:@"attachCamera"]) {
      [self attachCamera:result];
    } else if ([method isEqualToString:@"detachCamera"]) {
      [self detachCamera];
      result(nil);
    } else if ([method isEqualToString:@"join"]) {
      [self join:args result:result];
    } else if ([method isEqualToString:@"leave"]) {
      NSNumber *sessionId = [args[@"sessionId"] isKindOfClass:[NSNumber class]] ? args[@"sessionId"] : nil;
      [session leaveSession:sessionId endSession:[args[@"endSession"] boolValue]];
      result(nil);
    } else if ([method isEqualToString:@"renewToken"]) {
      NSString *token = [args[@"token"] isKindOfClass:[NSString class]] ? args[@"token"] : @"";
      NSNumber *sessionId = [args[@"sessionId"] isKindOfClass:[NSNumber class]] ? args[@"sessionId"] : nil;
      NSError *error = nil;
      if ([token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length == 0) {
        result([FlutterError errorWithCode:@"invalid_config" message:@"Missing token." details:nil]);
      } else if ([session renewToken:token sessionId:sessionId error:&error]) {
        result(nil);
      } else {
        result([FlutterError errorWithCode:error.userInfo[@"code"] ?: @"native_error"
                                   message:error.localizedDescription
                                   details:nil]);
      }
    } else if ([method isEqualToString:@"setMicMuted"]) {
      [session setMicMuted:[args[@"muted"] boolValue]];
      result(nil);
    } else if ([method isEqualToString:@"setVideoMuted"]) {
      [session setVideoMuted:[args[@"muted"] boolValue]];
      result(nil);
    } else if ([method isEqualToString:@"setSpeakerMuted"]) {
      [session setSpeakerMuted:[args[@"muted"] boolValue]];
      result(nil);
    } else if ([method isEqualToString:@"setForeground"]) {
      [session setForeground:[args[@"foreground"] boolValue]];
      result(nil);
    } else if ([method isEqualToString:@"setMaxFps"]) {
      NSNumber *fps = [args[@"fps"] isKindOfClass:[NSNumber class]] ? args[@"fps"] : @30;
      [sSource setMaxFps:fps.integerValue];
      result(nil);
    } else if ([method isEqualToString:@"stats"]) {
      BOOL host = session.request.host;
      result(@{
        @"engine" : [session stats],
        @"source" : (host && sSource) ? [sSource stats] : [NSNull null],
        @"process" : [self processSample],
      });
    } else if ([method isEqualToString:@"version"]) {
      result(@{@"zego" : [session sdkVersion], @"sharedContext" : @NO});
    } else {
      result(FlutterMethodNotImplemented);
    }
  } @catch (NSException *exception) {
    NSLog(@"[NosmaiZegoLive] %@ failed: %@", method, exception);
    result([FlutterError errorWithCode:@"native_error" message:exception.reason details:nil]);
  }
}

static NSString *TextArg(NSDictionary *args, NSString *key) {
  id value = args[key];
  if (![value isKindOfClass:[NSString class]]) return nil;
  NSString *text = value;
  return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length > 0 ? text : nil;
}

static NSInteger IntArg(NSDictionary *args, NSString *key, NSInteger fallback) {
  id value = args[key];
  return [value isKindOfClass:[NSNumber class]] ? [value integerValue] : fallback;
}

- (void)attachCamera:(FlutterResult)result {
  ZegoExpressEngine *engine = [ZegoExpressEngine sharedEngine];
  NosmaiZegoSession *session = [NosmaiZegoSession shared];
  if (!engine) {
    result([FlutterError errorWithCode:@"engine_missing" message:@"Create the ZEGO engine before attaching the Nosmai camera." details:nil]);
    return;
  }
  if (session.active || [session ownsEngine:engine]) {
    result([FlutterError errorWithCode:@"engine_in_use" message:@"The bridge-managed session owns this engine." details:nil]);
    return;
  }
  if (sAttachedCamera) {
    if (sCameraOwner == self && sAttachedCamera.engine == engine) result(nil);
    else result([FlutterError errorWithCode:@"camera_in_use" message:@"Detach the previous Nosmai camera first." details:nil]);
    return;
  }

  sAttachedCamera = [[NosmaiZegoVideoSource alloc] init];
  sCameraOwner = self;
  sAttachedCamera.engine = engine;
  [sAttachedCamera configureWithFps:30 adaptToThermalState:YES];
  @try {
    ZegoCustomVideoCaptureConfig *config = [[ZegoCustomVideoCaptureConfig alloc] init];
    config.bufferType = ZegoVideoBufferTypeCVPixelBuffer;
    [engine setCustomVideoCaptureHandler:sAttachedCamera];
    [engine enableCustomVideoCapture:YES config:config channel:ZegoPublishChannelMain];
  } @catch (NSException *exception) {
    [self detachCamera];
    @throw;
  }
  result(nil);
}

- (void)detachCamera {
  if (sCameraOwner != self || !sAttachedCamera) return;
  ZegoExpressEngine *engine = sAttachedCamera.engine;
  [sAttachedCamera shutdown];
  @try {
    if (engine && engine == [ZegoExpressEngine sharedEngine]) {
      [engine setCustomVideoCaptureHandler:nil];
      [engine enableCustomVideoCapture:NO config:nil channel:ZegoPublishChannelMain];
    }
  } @finally {
    sAttachedCamera = nil;
    sCameraOwner = nil;
  }
}

- (void)join:(NSDictionary *)args result:(FlutterResult)result {
  if (sAttachedCamera) {
    result([FlutterError errorWithCode:@"camera_in_use" message:@"Detach the host camera first." details:nil]);
    return;
  }
  NSString *missing = nil;
  for (NSString *key in @[ @"roomId", @"userId" ]) {
    if (!TextArg(args, key)) {
      missing = key;
      break;
    }
  }
  NSInteger appId = IntArg(args, @"appId", 0);
  if (!missing && appId <= 0) missing = @"appId";
  if (missing) {
    result([FlutterError errorWithCode:@"invalid_config"
                               message:[NSString stringWithFormat:@"Missing %@.", missing]
                               details:nil]);
    return;
  }

  NosmaiZegoJoinRequest *request = [[NosmaiZegoJoinRequest alloc] init];
  request.sessionId = [args[@"sessionId"] isKindOfClass:[NSNumber class]] ? [args[@"sessionId"] longLongValue]
                                                                         : (long long)(CACurrentMediaTime() * 1e9);
  request.host = [args[@"host"] boolValue];
  request.appId = (unsigned int)appId;
  request.appSign = TextArg(args, @"appSign") ?: @"";
  request.token = TextArg(args, @"token") ?: @"";
  request.roomId = TextArg(args, @"roomId");
  request.userId = TextArg(args, @"userId");
  request.userName = TextArg(args, @"userName") ?: request.userId;
  request.streamId = TextArg(args, @"streamId");
  request.hostUserId = TextArg(args, @"hostUserId");
  request.publishAudio = ![args[@"publishAudio"] isEqual:@NO];
  request.micMuted = [args[@"micMuted"] boolValue];
  request.videoMuted = [args[@"videoMuted"] boolValue];
  request.speakerMuted = [args[@"speakerMuted"] boolValue];
  request.keepScreenOn = ![args[@"keepScreenOn"] isEqual:@NO];
  request.fps = (int)MAX(1, MIN(30, IntArg(args, @"fps", 24)));
  // Even sizes, as the encoder wants.
  request.encodeWidth = (int)((MAX(96, MIN(1920, IntArg(args, @"width", 540))) / 2) * 2);
  request.encodeHeight = (int)((MAX(160, MIN(1920, IntArg(args, @"height", 960))) / 2) * 2);
  request.bitrateKbps = (int)MAX(100, MIN(10000, IntArg(args, @"bitrateKbps", 1200)));
  request.prioritizeFrameRate = ![args[@"prioritizeFrameRate"] isEqual:@NO];

  if (request.appSign.length == 0 && request.token.length == 0) {
    result([FlutterError errorWithCode:@"invalid_config"
                               message:@"Pass the ZEGOCLOUD AppSign or a token."
                               details:nil]);
    return;
  }

  NosmaiZegoVideoSource *source = nil;
  if (request.host) {
    if (request.streamId == nil) {
      result([FlutterError errorWithCode:@"invalid_config" message:@"Missing streamId." details:nil]);
      return;
    }
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized) {
      result([FlutterError errorWithCode:@"permission_denied"
                                 message:@"Camera access is required to broadcast."
                                 details:nil]);
      return;
    }
    if (sSource == nil) sSource = [[NosmaiZegoVideoSource alloc] init];
    source = sSource;
    [source configureWithFps:request.fps adaptToThermalState:![args[@"adaptToThermalState"] isEqual:@NO]];
    [source resetCounters];
    source.onCapturingChanged = ^(BOOL capturing) {
      [[NosmaiZegoSession shared] onCapturingChanged];
    };
  }

  NSError *error = nil;
  if (![[NosmaiZegoSession shared] join:request source:source error:&error]) {
    result([FlutterError errorWithCode:error.userInfo[@"code"] ?: @"start_failed"
                               message:error.localizedDescription
                               details:nil]);
    return;
  }
  result(@{@"sharedContext" : @NO});
}

- (void)setScreenOn:(BOOL)on {
  if (_screenOn == on) return;
  _screenOn = on;
  dispatch_async(dispatch_get_main_queue(), ^{ [UIApplication sharedApplication].idleTimerDisabled = on; });
}

#pragma mark - Permissions

- (void)requestPermissionsWithCamera:(BOOL)camera result:(FlutterResult)result {
  void (^askMicrophone)(BOOL) = ^(BOOL cameraGranted) {
    // ZEGO's audio engine needs the microphone, even when muted.
    [self requestAccessFor:AVMediaTypeAudio
                completion:^(BOOL microphone) {
                  result(@{@"camera" : @(cameraGranted), @"microphone" : @(microphone)});
                }];
  };
  if (!camera) {
    askMicrophone([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] ==
                  AVAuthorizationStatusAuthorized);
    return;
  }
  [self requestAccessFor:AVMediaTypeVideo completion:askMicrophone];
}

- (void)requestAccessFor:(AVMediaType)type completion:(void (^)(BOOL))completion {
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:type];
  if (status != AVAuthorizationStatusNotDetermined) {
    completion(status == AVAuthorizationStatusAuthorized);
    return;
  }
  [AVCaptureDevice requestAccessForMediaType:type
                           completionHandler:^(BOOL granted) {
                             dispatch_async(dispatch_get_main_queue(), ^{ completion(granted); });
                           }];
}

#pragma mark - Process diagnostics

/// App CPU (percent of one core, like `top`) and memory footprint.
- (NSDictionary<NSString *, id> *)processSample {
  double cpuSeconds = 0;
  struct task_thread_times_info threadTimes;
  mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t)&threadTimes, &count) == KERN_SUCCESS) {
    cpuSeconds += threadTimes.user_time.seconds + threadTimes.user_time.microseconds / 1e6;
    cpuSeconds += threadTimes.system_time.seconds + threadTimes.system_time.microseconds / 1e6;
  }
  struct task_basic_info_64 basic;
  count = TASK_BASIC_INFO_64_COUNT;
  if (task_info(mach_task_self(), TASK_BASIC_INFO_64, (task_info_t)&basic, &count) == KERN_SUCCESS) {
    // Threads that already exited.
    cpuSeconds += basic.user_time.seconds + basic.user_time.microseconds / 1e6;
    cpuSeconds += basic.system_time.seconds + basic.system_time.microseconds / 1e6;
  }
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  double cpuPercent = 0;
  if (_lastCpuAt > 0 && now > _lastCpuAt) {
    cpuPercent = MAX(0, (cpuSeconds - _lastCpuSeconds) / (now - _lastCpuAt) * 100.0);
  }
  _lastCpuAt = now;
  _lastCpuSeconds = cpuSeconds;

  double memoryMb = 0;
  task_vm_info_data_t vm;
  count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS) {
    memoryMb = vm.phys_footprint / (1024.0 * 1024.0);
  }
  return @{@"cpuPercent" : @(cpuPercent), @"cpuCores" : @([NSProcessInfo processInfo].activeProcessorCount),
           @"rssMb" : @(memoryMb)};
}

@end
