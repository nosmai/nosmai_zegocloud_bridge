import 'package:flutter/services.dart';
// ZEGO 3.21 exposes creation state only on its Dart implementation. The
// native singleton getter can return an unusable object before engine creation.
// ignore: implementation_imports
import 'package:zego_express_engine/src/impl/zego_express_impl.dart';

/// Thin wrapper over the plugin's channels; replaceable in tests.
class NativeBridge {
  const NativeBridge();

  static const _methods = MethodChannel('nosmai_zegocloud_live');
  static const _eventChannel = EventChannel('nosmai_zegocloud_live/events');

  /// Platform view type of the viewer's video.
  static const remoteVideoViewType = 'nosmai_zegocloud_live/remote_video';

  // One shared subscription: every listener sees the same native event stream,
  // and the platform side is only told to stop when nobody listens.
  static final Stream<Map<String, Object?>> _events = _eventChannel
      .receiveBroadcastStream()
      .map((raw) => raw is Map ? Map<String, Object?>.from(raw) : const <String, Object?>{});

  /// Room events: `joined`, `reconnecting`, `reconnected`, `left {reason}`,
  /// `error {code, message, fatal}`, `warning {message}`,
  /// `remoteVideo {streamId, userId, userName, on}`, `sending {on}` and
  /// `tokenWillExpire {seconds}`. Each
  /// carries `session`: the `sessionId` passed to [join].
  Stream<Map<String, Object?>> get events => _events;

  /// Android: registers the shared GL context Nosmai must join. Call before
  /// Nosmai initializes. Returns whether a share context exists.
  Future<bool> prepare() async {
    final result = await _methods.invokeMapMethod<Object?, Object?>('prepare');
    return result?['sharedContext'] == true;
  }

  Future<({bool camera, bool microphone})> requestPermissions({bool camera = true, bool microphone = true}) async {
    final result = await _methods.invokeMapMethod<Object?, Object?>(
        'requestPermissions', {'camera': camera, 'microphone': microphone});
    return (camera: result?['camera'] == true, microphone: result?['microphone'] == true);
  }

  Future<void> attachCamera() async {
    if (!ZegoExpressImpl.isEngineCreated) {
      throw PlatformException(code: 'engine_missing', message: 'Create the ZEGO engine before attaching the camera.');
    }
    await _methods.invokeMethod<void>('attachCamera');
  }

  Future<void> detachCamera() => _methods.invokeMethod<void>('detachCamera');

  /// Starts logging in. Completes when ZEGOCLOUD accepted the request; `joined` follows.
  Future<void> join(Map<String, Object?> arguments) async {
    if (ZegoExpressImpl.isEngineCreated) {
      throw PlatformException(code: 'engine_in_use', message: 'Use attachCamera with your existing ZEGO engine.');
    }
    await _methods.invokeMapMethod<Object?, Object?>('join', arguments);
  }

  /// Leaves the room if [sessionId] is still the active session; `left`
  /// (tagged with [sessionId]) follows either way.
  Future<void> leave({required int sessionId, required bool endSession}) =>
      _methods.invokeMethod<void>('leave', {'sessionId': sessionId, 'endSession': endSession});

  /// Replaces the room token of session [sessionId] before it expires.
  Future<void> renewToken({required int sessionId, required String token}) =>
      _methods.invokeMethod<void>('renewToken', {'sessionId': sessionId, 'token': token});

  Future<void> setMicMuted(bool muted) => _methods.invokeMethod<void>('setMicMuted', {'muted': muted});

  Future<void> setVideoMuted(bool muted) => _methods.invokeMethod<void>('setVideoMuted', {'muted': muted});

  Future<void> setSpeakerMuted(bool muted) =>
      _methods.invokeMethod<void>('setSpeakerMuted', {'muted': muted});

  Future<void> setForeground(bool foreground) =>
      _methods.invokeMethod<void>('setForeground', {'foreground': foreground});

  Future<void> setMaxFps(int fps) => _methods.invokeMethod<void>('setMaxFps', {'fps': fps});

  Future<Map<Object?, Object?>?> stats() => _methods.invokeMapMethod<Object?, Object?>('stats');

  Future<String> zegoVersion() async {
    final result = await _methods.invokeMapMethod<Object?, Object?>('version');
    return result?['zego']?.toString() ?? '';
  }
}
