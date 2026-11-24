#import "NosmaiZegoVideoSource.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <nosmai_effects_sdk/NosmaiFlutterPlugin.h>

static const CFTimeInterval kResyncAfter = 0.2;
/// Targets at or above this rate send every Nosmai frame (the camera's own rate) unpaced.
static const NSInteger kNoPacingFps = 30;

@implementation NosmaiZegoVideoSource {
  NSLock *_lock;
  dispatch_group_t _submissions;

  // Configuration (under _lock).
  NSInteger _maxFps;
  BOOL _adaptToThermalState;

  // State (under _lock).
  BOOL _capturing;
  BOOL _paused;
  BOOL _attached;

  // Pacing and counters (under _lock).
  CFTimeInterval _nextDeadline;
  uint64_t _framesIn;
  uint64_t _sent;
  uint64_t _dropped;
  uint64_t _paced;
  uint64_t _errors;
  double _sendMsTotal;
  double _sendMsMax;
  size_t _lastWidth;
  size_t _lastHeight;
  NSString *_lastError;

  // Rate bookkeeping for -stats (under _lock).
  CFTimeInterval _lastStatsAt;
  uint64_t _lastStatsIn;
  uint64_t _lastStatsSent;
  double _lastStatsSendMs;
}

- (instancetype)init {
  if ((self = [super init])) {
    _lock = [[NSLock alloc] init];
    _submissions = dispatch_group_create();
    _maxFps = 24;
    _adaptToThermalState = YES;
    _lastError = @"";
  }
  return self;
}

#pragma mark - Configuration

- (void)configureWithFps:(NSInteger)fps adaptToThermalState:(BOOL)adapt {
  [_lock lock];
  _maxFps = MAX(1, MIN(60, fps));
  _adaptToThermalState = adapt;
  [_lock unlock];
}

- (void)setMaxFps:(NSInteger)fps {
  [_lock lock];
  _maxFps = MAX(1, MIN(60, fps));
  [_lock unlock];
}

- (void)setPaused:(BOOL)paused {
  [_lock lock];
  _paused = paused;
  if (!paused) _nextDeadline = 0;
  [_lock unlock];
}

- (BOOL)isCapturing {
  [_lock lock];
  BOOL value = _capturing;
  [_lock unlock];
  return value;
}

- (void)resetCounters {
  [_lock lock];
  _framesIn = _sent = _dropped = _paced = _errors = 0;
  _sendMsTotal = _sendMsMax = 0;
  _lastWidth = _lastHeight = 0;
  _lastError = @"";
  _nextDeadline = 0;
  _paused = NO;
  _lastStatsAt = 0;
  _lastStatsIn = _lastStatsSent = 0;
  _lastStatsSendMs = 0;
  [_lock unlock];
}

#pragma mark - ZegoCustomVideoCaptureHandler (called by ZEGO)

- (void)onStart:(ZegoPublishChannel)channel {
  @synchronized (self) {
    if (channel != ZegoPublishChannelMain || self.engine == nil) return;
    [_lock lock];
    BOOL was = _capturing;
    _capturing = YES;
    _nextDeadline = 0;
    BOOL attach = !_attached;
    _attached = YES;
    [_lock unlock];
    if (was) return;
    if (attach) {
      __weak NosmaiZegoVideoSource *weakSelf = self;
      [NosmaiFlutterPlugin setLiveStreamFrameCallback:^(CVPixelBufferRef pixelBuffer, double timestamp) {
        [weakSelf onFrame:pixelBuffer];
      }];
    }
    [self notifyCapturing:YES];
  }
}

- (void)onStop:(ZegoPublishChannel)channel {
  @synchronized (self) {
    if (channel != ZegoPublishChannelMain) return;
    [_lock lock];
    BOOL was = _capturing;
    _capturing = NO;
    BOOL detach = _attached;
    _attached = NO;
    [_lock unlock];
    if (detach) [NosmaiFlutterPlugin clearLiveStreamFrameCallback];
    if (was) [self notifyCapturing:NO];
  }
}

- (void)shutdown {
  @synchronized (self) {
    [_lock lock];
    _capturing = NO;
    BOOL detach = _attached;
    _attached = NO;
    [_lock unlock];
    self.engine = nil;
    if (detach) [NosmaiFlutterPlugin clearLiveStreamFrameCallback];
  }
  // A frame already handed to ZEGO must finish before the host can destroy its engine.
  dispatch_group_wait(_submissions, DISPATCH_TIME_FOREVER);
}

- (void)notifyCapturing:(BOOL)capturing {
  void (^callback)(BOOL) = self.onCapturingChanged;
  if (!callback) return;
  dispatch_async(dispatch_get_main_queue(), ^{ callback(capturing); });
}

#pragma mark - Frames

/// Nosmai's processing thread, once per processed frame. Never blocks on the network.
- (void)onFrame:(CVPixelBufferRef)pixelBuffer {
  if (pixelBuffer == NULL) return;
  CFTimeInterval now = CACurrentMediaTime();
  NSInteger fps = [self effectiveFps];
  ZegoExpressEngine *engine = self.engine;
  OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
  BOOL supported = type == kCVPixelFormatType_32BGRA || type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                   type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  [_lock lock];
  _framesIn++;
  if (!_capturing || _paused || engine == nil) {
    [_lock unlock];
    return;
  }
  // Even spacing at the target rate; a frame may arrive up to a quarter interval early.
  // At kNoPacingFps or more every frame passes: the camera runs at 30, so pacing at the
  // camera's own rate would only drop frames that arrive with a little jitter.
  CFTimeInterval interval = 1.0 / (double)fps;
  if (fps < kNoPacingFps && _nextDeadline > 0 && now + interval / 4 < _nextDeadline) {
    _paced++;
    [_lock unlock];
    return;
  }
  _nextDeadline = (_nextDeadline == 0 || now - _nextDeadline > kResyncAfter) ? now + interval
                                                                             : _nextDeadline + interval;
  if (!supported) {
    _dropped++;
    _errors++;
    _lastError = [NSString stringWithFormat:@"Unsupported pixel format 0x%08X", (unsigned)type];
    [_lock unlock];
    return;
  }
  dispatch_group_enter(_submissions);
  [_lock unlock];

  CFTimeInterval started = CACurrentMediaTime();
  @try {
    [engine sendCustomVideoCapturePixelBuffer:pixelBuffer
                                    timestamp:CMTimeMakeWithSeconds(started, 1000000)
                                      channel:ZegoPublishChannelMain];
  } @finally {
    dispatch_group_leave(_submissions);
  }
  double sendMs = (CACurrentMediaTime() - started) * 1000.0;

  [_lock lock];
  _sent++;
  _sendMsTotal += sendMs;
  _sendMsMax = MAX(_sendMsMax, sendMs);
  _lastWidth = CVPixelBufferGetWidth(pixelBuffer);
  _lastHeight = CVPixelBufferGetHeight(pixelBuffer);
  [_lock unlock];
}

#pragma mark - Rate and stats

- (NSInteger)effectiveFps {
  [_lock lock];
  NSInteger fps = _maxFps;
  BOOL adapt = _adaptToThermalState;
  [_lock unlock];
  if (!adapt) return fps;
  switch ([NSProcessInfo processInfo].thermalState) {
    case NSProcessInfoThermalStateCritical:
      return MIN(fps, 10);
    case NSProcessInfoThermalStateSerious:
      return MIN(fps, 15);
    default:
      return fps;
  }
}

+ (NSString *)thermalName {
  switch ([NSProcessInfo processInfo].thermalState) {
    case NSProcessInfoThermalStateNominal:
      return @"nominal";
    case NSProcessInfoThermalStateFair:
      return @"fair";
    case NSProcessInfoThermalStateSerious:
      return @"serious";
    case NSProcessInfoThermalStateCritical:
      return @"critical";
  }
  return @"unknown";
}

- (NSDictionary<NSString *, id> *)stats {
  NSInteger targetFps = [self effectiveFps];
  CFTimeInterval now = CACurrentMediaTime();
  [_lock lock];
  double elapsed = _lastStatsAt > 0 ? now - _lastStatsAt : 0;
  uint64_t sentDelta = _sent - _lastStatsSent;
  double inputFps = elapsed > 0 ? (double)(_framesIn - _lastStatsIn) / elapsed : 0;
  double txFps = elapsed > 0 ? (double)sentDelta / elapsed : 0;
  double sendAvg = sentDelta > 0 ? (_sendMsTotal - _lastStatsSendMs) / (double)sentDelta : 0;
  NSDictionary *stats = @{
    @"capturing" : @(_capturing),
    @"paused" : @(_paused),
    @"transport" : @"pixelbuffer",
    @"sharedContext" : @NO,
    @"framesIn" : @(_framesIn),
    @"sent" : @(_sent),
    @"dropped" : @(_dropped),
    @"paced" : @(_paced),
    @"errors" : @(_errors),
    @"inputFps" : @(inputFps),
    @"txFps" : @(txFps),
    @"convertMsAvg" : @0,
    @"convertMsMax" : @0,
    @"sendMsAvg" : @(sendAvg),
    @"width" : @(_lastWidth),
    @"height" : @(_lastHeight),
    @"targetFps" : @(targetFps),
    @"thermal" : [NosmaiZegoVideoSource thermalName],
    @"lastError" : _lastError ?: @"",
  };
  _lastStatsAt = now;
  _lastStatsIn = _framesIn;
  _lastStatsSent = _sent;
  _lastStatsSendMs = _sendMsTotal;
  _sendMsMax = 0;
  [_lock unlock];
  return stats;
}

@end
