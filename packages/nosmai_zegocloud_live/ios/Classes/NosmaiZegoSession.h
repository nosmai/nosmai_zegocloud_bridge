#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "NosmaiZegoVideoSource.h"

NS_ASSUME_NONNULL_BEGIN

/// What Dart asked for when joining.
@interface NosmaiZegoJoinRequest : NSObject
/// Chosen by Dart; tags every event so a late event never reaches a newer session.
@property(nonatomic) long long sessionId;
@property(nonatomic) BOOL host;
@property(nonatomic) unsigned int appId;
@property(nonatomic, copy) NSString *appSign;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *roomId;
@property(nonatomic, copy) NSString *userId;
@property(nonatomic, copy) NSString *userName;
/// Broadcaster: the stream to publish. Viewer: the stream to watch, or nil for any.
@property(nonatomic, copy, nullable) NSString *streamId;
@property(nonatomic, copy, nullable) NSString *hostUserId;
@property(nonatomic) BOOL publishAudio;
@property(nonatomic) BOOL micMuted;
@property(nonatomic) BOOL videoMuted;
@property(nonatomic) BOOL speakerMuted;
@property(nonatomic) BOOL keepScreenOn;
@property(nonatomic) int fps;
@property(nonatomic) int encodeWidth;
@property(nonatomic) int encodeHeight;
@property(nonatomic) int bitrateKbps;
@property(nonatomic) BOOL prioritizeFrameRate;
@end

/// The process-wide ZEGO Express room: one broadcaster (publishes NosmaiZegoVideoSource through
/// custom video capture) or one viewer (plays the broadcaster's stream into a UIView).
///
/// Main thread only: ZEGO delivers its callbacks there. Outcomes reach Dart through `emit`, each
/// tagged with `session` (the request's sessionId): `joined`, `reconnecting`, `reconnected`,
/// `left {reason}`, `error {code, message, fatal}`, `warning {message}`,
/// `remoteVideo {userId, userName, streamId, on}`, `sending {on}` and `tokenWillExpire {seconds}`.
@interface NosmaiZegoSession : NSObject

+ (instancetype)shared;

@property(nonatomic, copy) void (^emit)(NSDictionary<NSString *, id> *event);
/// Told (main thread) after a session ended; the plugin shuts the video source down.
@property(nonatomic, copy) void (^onLeft)(NosmaiZegoJoinRequest *request);
@property(nonatomic, readonly, nullable) NosmaiZegoJoinRequest *request;
@property(nonatomic, readonly) BOOL active;

- (NSString *)sdkVersion;
- (BOOL)ownsEngine:(ZegoExpressEngine *)engine;

/// Logs in asynchronously; success arrives as the `joined` event. A broadcaster passes `source`
/// so ZEGO publishes Nosmai's frames instead of opening a camera. NO and `error` on failure.
- (BOOL)join:(NosmaiZegoJoinRequest *)request source:(nullable NosmaiZegoVideoSource *)source error:(NSError **)error;
- (void)leaveSession:(nullable NSNumber *)sessionId endSession:(BOOL)endSession;
- (BOOL)renewToken:(NSString *)token sessionId:(nullable NSNumber *)sessionId error:(NSError **)error;
- (void)setMicMuted:(BOOL)muted;
- (void)setVideoMuted:(BOOL)muted;
- (void)setSpeakerMuted:(BOOL)muted;
- (void)setForeground:(BOOL)foreground;
- (void)attachRemoteView:(UIView *)view;
- (void)detachRemoteView:(UIView *)view;
- (void)onCapturingChanged;
/// Destroys the idle engine now, e.g. when Flutter detaches.
- (void)releaseNow;
- (NSDictionary<NSString *, id> *)stats;

@end

NS_ASSUME_NONNULL_END
