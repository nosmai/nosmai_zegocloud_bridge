/// Livestream Nosmai effects through ZEGOCLOUD (ZEGO Express) without native code.
///
/// 1. `NosmaiZegoCloudLive.initialize(...)` with your Nosmai license key.
/// 2. Show `NosmaiCameraPreview` and apply effects with
///    `NosmaiZegoCloudLive.effects` (all of Nosmai's API is re-exported here).
/// 3. Attach to your existing engine with [NosmaiZegoCloudLive.attachCamera].
///    For a bridge-managed room, use [NosmaiLiveBroadcaster] and [NosmaiLiveViewer].
library;

export 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

export 'src/broadcaster.dart' show NosmaiLiveBroadcaster;
export 'src/credentials.dart';
export 'src/nosmai_zegocloud_live.dart';
export 'src/stats.dart';
export 'src/video_config.dart';
export 'src/viewer.dart';
