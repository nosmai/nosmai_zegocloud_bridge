#import <Foundation/Foundation.h>
#import <ZegoExpressEngine/ZegoExpressEngine.h>

NS_ASSUME_NONNULL_BEGIN

/// ZEGO custom video capture fed by Nosmai's processed camera frames. Nosmai owns the camera;
/// ZEGO never opens it.
///
/// Nosmai hands over a CVPixelBuffer per processed frame (BGRA or NV12), upright portrait. ZEGO's
/// CVPixelBuffer capture takes both formats as they are and scales to the encode size itself, so
/// no conversion happens here: a frame is paced to the target rate and passed on. Only frames
/// between ZEGO's onStart and onStop are taken from Nosmai, and never while paused (video muted
/// or app in the background).
@interface NosmaiZegoVideoSource : NSObject <ZegoCustomVideoCaptureHandler>

/// The engine that receives the frames; set before the session logs in.
@property(atomic, strong, nullable) ZegoExpressEngine *engine;

/// Called on the main queue whenever ZEGO starts or stops asking for frames.
@property(nonatomic, copy, nullable) void (^onCapturingChanged)(BOOL capturing);

@property(atomic, readonly) BOOL isCapturing;

- (void)configureWithFps:(NSInteger)fps adaptToThermalState:(BOOL)adapt;
- (void)setMaxFps:(NSInteger)fps;
- (void)setPaused:(BOOL)paused;
- (void)resetCounters;

/// Detaches from Nosmai and ignores late frames. Safe to call repeatedly.
- (void)shutdown;

/// Pipeline counters for the Dart stats overlay; call about once per second.
- (NSDictionary<NSString *, id> *)stats;

@end

NS_ASSUME_NONNULL_END
