/// Portrait sizes for the broadcast (9:16), by their long side.
enum NosmaiLiveResolution {
  p360(640, 600),
  p540(960, 1200),
  p720(1280, 1800),
  p1080(1920, 3000);

  const NosmaiLiveResolution(this.longSide, this.defaultBitrateKbps);

  /// Height of a portrait frame, in pixels.
  final int longSide;

  /// Width of a portrait frame, in pixels.
  int get shortSide => longSide * 9 ~/ 16;

  /// Target bitrate used when [NosmaiLiveVideoConfig.bitrateKbps] is not set.
  final int defaultBitrateKbps;
}

/// How the broadcaster sends Nosmai's processed video to ZEGOCLOUD.
///
/// Nosmai renders at 720x1280; frames are scaled to [resolution] on the GPU
/// before ZEGOCLOUD encodes them (1080p is upscaled from Nosmai's 720p).
class NosmaiLiveVideoConfig {
  const NosmaiLiveVideoConfig({
    this.resolution = NosmaiLiveResolution.p540,
    this.fps = 24,
    this.bitrateKbps,
    this.adaptToThermalState = true,
    this.prioritizeFrameRate = true,
  }) : assert(fps >= 1 && fps <= 30, 'fps must be between 1 and 30');

  /// 360p at 15 FPS: weak networks and older phones.
  static const low = NosmaiLiveVideoConfig(resolution: NosmaiLiveResolution.p360, fps: 15);

  /// 540p at 24 FPS: the default balance of quality, heat and bandwidth.
  static const standard = NosmaiLiveVideoConfig();

  /// 720p at 30 FPS.
  static const hd = NosmaiLiveVideoConfig(resolution: NosmaiLiveResolution.p720, fps: 30);

  final NosmaiLiveResolution resolution;
  final int fps;

  /// Target video bitrate in kbps; ZEGOCLOUD lowers it on a weak network.
  /// Null: [NosmaiLiveResolution.defaultBitrateKbps].
  final int? bitrateKbps;

  int get effectiveBitrateKbps => bitrateKbps ?? resolution.defaultBitrateKbps;

  /// Lowers the frame rate while the phone reports severe (15 FPS) or
  /// critical (10 FPS) heat, so a long broadcast does not overheat it.
  final bool adaptToThermalState;

  /// On a weak network, ZEGOCLOUD keeps [fps] and lowers the resolution. When
  /// false it may lower both.
  final bool prioritizeFrameRate;
}
