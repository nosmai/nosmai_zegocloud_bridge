/// Where a broadcaster or viewer is in its lifecycle.
enum NosmaiLiveState {
  /// Created, `start` not called yet.
  idle,

  /// Logging in to the ZEGOCLOUD room.
  connecting,

  /// Viewer only: in the room, no broadcaster video yet.
  waitingForHost,

  /// Broadcaster: video is being sent. Viewer: the broadcaster's video is playing.
  live,

  /// The network dropped; ZEGOCLOUD is reconnecting automatically.
  reconnecting,

  /// Paused because the app is in the background.
  paused,

  /// Leaving the room.
  stopping,

  /// Left the room normally (or, for a viewer, the broadcaster ended the live).
  stopped,

  /// Stopped because of an error; see `error`.
  failed;

  bool get isActive =>
      this == connecting ||
      this == waitingForHost ||
      this == live ||
      this == reconnecting ||
      this == paused;
}

/// Live quality numbers, refreshed about once per second while active.
/// Every value is measured, either by ZEGOCLOUD or by the plugin's frame pipeline.
class NosmaiLiveStats {
  const NosmaiLiveStats({
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.encodeFps = 0,
    this.bitrateKbps = 0,
    this.latencyMs = 0,
    this.rttMs = 0,
    this.lossPercent = 0,
    this.network = '',
    this.participants = 0,
    this.hardwareCodec = false,
    this.framesFromNosmai = 0,
    this.framesSent = 0,
    this.framesDropped = 0,
    this.nosmaiFps = 0,
    this.sendFps = 0,
    this.targetFps = 0,
    this.framesPaced = 0,
    this.thermal = '',
    this.convertMs = 0,
    this.transport = '',
    this.pipelineNote = '',
    this.cpuPercent = 0,
    this.memoryMb = 0,
  });

  static const empty = NosmaiLiveStats();

  /// Parses the plugin's native stats sample.
  factory NosmaiLiveStats.fromNative(Map<Object?, Object?>? raw) {
    Map<Object?, Object?> part(String key) {
      final value = raw?[key];
      return value is Map ? value : const {};
    }

    final zego = part('engine');
    final source = part('source');
    final process = part('process');
    int i(Map<Object?, Object?> m, String k) => (m[k] as num?)?.round() ?? 0;
    double d(Map<Object?, Object?> m, String k) => (m[k] as num?)?.toDouble() ?? 0;
    return NosmaiLiveStats(
      width: i(zego, 'width'),
      height: i(zego, 'height'),
      fps: d(zego, 'fps'),
      encodeFps: d(zego, 'encodeFps'),
      bitrateKbps: d(zego, 'bitrateKbps'),
      latencyMs: i(zego, 'latencyMs'),
      rttMs: i(zego, 'rttMs'),
      lossPercent: d(zego, 'lossPercent'),
      network: zego['network']?.toString() ?? '',
      participants: i(zego, 'participants'),
      hardwareCodec: zego['hardwareCodec'] == true,
      framesFromNosmai: i(source, 'framesIn'),
      framesSent: i(source, 'sent'),
      framesDropped: i(source, 'dropped'),
      nosmaiFps: d(source, 'inputFps'),
      sendFps: d(source, 'txFps'),
      targetFps: i(source, 'targetFps'),
      framesPaced: i(source, 'paced'),
      thermal: source['thermal']?.toString() ?? '',
      convertMs: d(source, 'convertMsAvg'),
      transport: source['transport']?.toString() ?? '',
      pipelineNote: source['lastError']?.toString() ?? '',
      cpuPercent: d(process, 'cpuPercent'),
      memoryMb: d(process, 'rssMb'),
    );
  }

  /// Broadcaster: the configured encode size. Viewer: the received video size.
  final int width;
  final int height;

  /// ZEGOCLOUD's sent (broadcaster) or rendered (viewer) frame rate.
  final double fps;

  /// Broadcaster only: frames per second the encoder produced.
  final double encodeFps;

  /// Sent (broadcaster) or received (viewer) video bitrate.
  final double bitrateKbps;

  /// Viewer only: broadcaster-to-viewer delay reported by ZEGOCLOUD.
  final int latencyMs;

  /// Round trip to the ZEGOCLOUD server.
  final int rttMs;

  /// Average packet loss in the sending (broadcaster) or receiving (viewer) direction.
  final double lossPercent;

  /// ZEGOCLOUD's stream quality: `Excellent`, `Good`, `Medium`, `Bad`, `Down` or `Unknown`.
  final String network;

  /// Other people in the room.
  final int participants;

  /// Whether the video is hardware encoded (broadcaster) or decoded (viewer).
  final bool hardwareCodec;

  /// Broadcaster only: processed frames Nosmai delivered.
  final int framesFromNosmai;

  /// Broadcaster only: frames handed to ZEGOCLOUD.
  final int framesSent;

  /// Broadcaster only: frames skipped because the pipeline was busy.
  final int framesDropped;

  /// Broadcaster only: frames per second Nosmai rendered, which is the preview's
  /// frame rate. Measured while live.
  final double nosmaiFps;

  /// Broadcaster only: frames per second handed to ZEGOCLOUD, measured by the plugin.
  /// Lower than [nosmaiFps] when pacing to the configured rate or the thermal cap.
  final double sendFps;

  /// Broadcaster only: the frame rate the plugin is aiming for, after the thermal cap.
  final int targetFps;

  /// Broadcaster only: frames skipped to hold [targetFps].
  final int framesPaced;

  /// Broadcaster only, iOS: the phone's thermal state; empty where not reported.
  final String thermal;

  /// Broadcaster only: average time to turn a Nosmai frame into an I420 buffer.
  final double convertMs;

  /// Broadcaster only: `texture` (GPU conversion) or `i420` (Nosmai CPU frames).
  final String transport;

  /// Broadcaster only: why the pipeline fell back or dropped frames, if it did.
  final String pipelineNote;

  /// This app's CPU use, as a percent of one core.
  final double cpuPercent;

  /// This app's resident memory.
  final double memoryMb;

  @override
  String toString() => '${width}x$height@${fps.toStringAsFixed(1)}fps ${bitrateKbps.round()}kbps rtt=${rttMs}ms '
      'loss=${lossPercent.toStringAsFixed(1)}% nosmai=$framesFromNosmai sent=$framesSent '
      'dropped=$framesDropped $transport';
}

/// Thrown for configuration and setup problems the app can fix.
class NosmaiLiveException implements Exception {
  const NosmaiLiveException(this.code, this.message);

  /// Stable identifier, e.g. `invalid_token` or `permission_denied`.
  final String code;
  final String message;

  @override
  String toString() => 'NosmaiLiveException($code): $message';
}
