import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

import 'credentials.dart';
import 'native_bridge.dart';
import 'stats.dart';
import 'video_config.dart';
import 'zego_session.dart';

/// Publishes the Nosmai camera, with every applied effect, to a ZEGOCLOUD room.
///
/// Show a `NosmaiCameraPreview` on the same screen; Nosmai owns the camera
/// and whatever the preview shows is what viewers receive.
///
/// ```dart
/// final live = NosmaiLiveBroadcaster(
///   credentials: NosmaiLiveCredentials(appId: appId, appSign: appSign, userId: 'host_1'),
///   session: const NosmaiLiveSession('my-room'),
/// );
/// await live.start();
/// // ... apply effects with NosmaiZegoCloudLive.effects ...
/// await live.stop();
/// ```
class NosmaiLiveBroadcaster extends ChangeNotifier with WidgetsBindingObserver {
  NosmaiLiveBroadcaster({
    required this.credentials,
    required this.session,
    this.video = NosmaiLiveVideoConfig.standard,
    this.publishAudio = true,
    this.endSessionOnStop = true,
    this.handleAppLifecycle = true,
    this.keepScreenOn = true,
    @visibleForTesting NativeBridge bridge = const NativeBridge(),
    @visibleForTesting Duration statsInterval = const Duration(seconds: 1),
    @visibleForTesting Duration joinTimeout = const Duration(seconds: 25),
    @visibleForTesting bool Function()? nosmaiReady,
    @visibleForTesting DateTime Function()? clock,
  })  : _bridge = bridge,
        _statsInterval = statsInterval,
        _joinTimeout = joinTimeout,
        _nosmaiReady = nosmaiReady ?? (() => NosmaiFlutter.instance.isInitialized),
        _clock = clock ?? DateTime.now;

  final NosmaiLiveCredentials credentials;
  final NosmaiLiveSession session;
  final NosmaiLiveVideoConfig video;

  /// Publish the microphone along with the video.
  final bool publishAudio;

  /// Tell viewers the live is over when [stop] is called, so they stop too.
  /// When false, viewers stay in the room and wait for a broadcaster.
  final bool endSessionOnStop;

  /// Pause publishing in the background and resume in the foreground.
  final bool handleAppLifecycle;

  /// Keep the screen awake while live.
  final bool keepScreenOn;

  final NativeBridge _bridge;
  final Duration _statsInterval;
  final Duration _joinTimeout;
  final bool Function() _nosmaiReady;
  final DateTime Function() _clock;

  ZegoLiveSession? _session;
  Future<void>? _stopFuture;
  NosmaiLiveState _state = NosmaiLiveState.idle;
  String? _error;
  bool _micMuted = false;
  bool _videoMuted = false;
  bool _disposed = false;

  NosmaiLiveState get state => _state;
  NosmaiLiveStats get stats => _session?.stats ?? NosmaiLiveStats.empty;

  /// Why the broadcast failed, when [state] is [NosmaiLiveState.failed].
  String? get error => _error;

  /// A non-fatal problem worth showing, such as a slow first frame.
  String? get warning {
    final session = _session;
    if (session == null) return null;
    if (session.warning != null) return session.warning;
    final note = session.stats.pipelineNote;
    return note.isEmpty ? null : note;
  }

  bool get isLive => _state == NosmaiLiveState.live;

  /// The stream this broadcaster publishes; viewers can watch it by ID.
  String get streamId => session.streamIdFor(credentials.userId);
  bool get micMuted => _micMuted || !publishAudio;
  bool get videoMuted => _videoMuted;

  /// Logs in to the room and starts publishing. Completes once the room is
  /// joined; throws [NosmaiLiveException] on failure.
  Future<void> start() async {
    if (_state != NosmaiLiveState.idle) {
      throw StateError('A broadcaster can be started once; create a new one.');
    }
    _setState(NosmaiLiveState.connecting);
    try {
      final configProblem = session.validate();
      if (configProblem != null) throw NosmaiLiveException('invalid_config', configProblem);
      final credentialProblem = credentials.validate(now: _clock());
      if (credentialProblem != null) throw NosmaiLiveException('invalid_credentials', credentialProblem);
      if (!_nosmaiReady()) {
        throw const NosmaiLiveException('not_initialized',
            'Call NosmaiZegoCloudLive.initialize before starting a broadcast.');
      }
      final permissions = await _bridge.requestPermissions(microphone: publishAudio);
      if (!permissions.camera) {
        throw const NosmaiLiveException('permission_denied', 'Camera access is required to broadcast.');
      }
      if (publishAudio && !permissions.microphone) {
        throw const NosmaiLiveException('permission_denied',
            'Microphone access is required to broadcast with audio. '
            'Pass publishAudio: false to broadcast video only.');
      }
      _throwIfStopped();

      final zego = ZegoLiveSession(
        bridge: _bridge,
        isHost: true,
        endSessionOnClose: endSessionOnStop,
        statsInterval: _statsInterval,
        joinTimeout: _joinTimeout,
        joinArguments: {
          'host': true,
          'appId': credentials.appId,
          'appSign': credentials.appSign,
          'token': credentials.token,
          'userId': credentials.userId,
          'userName': credentials.userName,
          'roomId': session.roomId,
          'streamId': streamId,
          'publishAudio': publishAudio,
          'micMuted': micMuted,
          'videoMuted': _videoMuted,
          'keepScreenOn': keepScreenOn,
          'fps': video.fps,
          'width': video.resolution.shortSide,
          'height': video.resolution.longSide,
          'bitrateKbps': video.effectiveBitrateKbps,
          'adaptToThermalState': video.adaptToThermalState,
          'prioritizeFrameRate': video.prioritizeFrameRate,
        },
      );
      _session = zego;
      zego.addListener(_onSessionChanged);
      if (handleAppLifecycle) WidgetsBinding.instance.addObserver(this);
      await zego.start();
      await zego.entered;
      _throwIfStopped();
      _onSessionChanged();
    } catch (e) {
      final failure = _session?.error;
      final code = switch (e) {
        NosmaiLiveException(:final code) => code,
        _ => _session?.failureCode ?? 'start_failed',
      };
      final message = switch (e) {
        NosmaiLiveException(:final message) => message,
        StateError(:final message) => failure ?? message,
        _ => failure ?? '$e',
      };
      await (_stopFuture ??= _shutdown(failure: message));
      throw NosmaiLiveException(code, message);
    }
  }

  /// Leaves the session. Safe to call at any time and more than once.
  Future<void> stop() => _stopFuture ??= _shutdown();

  /// When the room token expires, once ZEGOCLOUD warns about it (about 30 s
  /// ahead). Token authentication only: fetch a new Token04 for the same user
  /// from your server and pass it to [renewToken].
  DateTime? get tokenExpiresAt => _session?.tokenExpiresAt;

  /// Replaces the room token without leaving. Throws [NosmaiLiveException].
  Future<void> renewToken(String token) async {
    final problem = NosmaiZegoToken.problemFor(token, now: _clock());
    if (problem != null) throw NosmaiLiveException('invalid_credentials', problem);
    final session = _session;
    if (session == null || !_state.isActive) {
      throw const NosmaiLiveException('not_active', 'There is no active session to renew.');
    }
    try {
      await session.renewToken(token);
    } on PlatformException catch (e) {
      throw NosmaiLiveException(e.code, e.message ?? e.code);
    }
  }

  void setMicMuted(bool muted) {
    if (!publishAudio) return;
    _micMuted = muted;
    _session?.setMicMuted(muted);
    _notify();
  }

  /// Stops sending video while muted; audio and the session stay.
  void setVideoMuted(bool muted) {
    _videoMuted = muted;
    _session?.setVideoMuted(muted);
    _notify();
  }

  /// Switches between front and back cameras. The stream continues.
  Future<void> switchCamera() => NosmaiFlutter.instance.switchCamera();

  /// Changes the published frame rate (1-30) without restarting.
  Future<void> setMaxFps(int fps) => _bridge.setMaxFps(fps.clamp(1, 30));

  void _throwIfStopped() {
    if (_stopFuture != null || _disposed) {
      throw const NosmaiLiveException('stopped', 'The broadcast was stopped while starting.');
    }
    final failure = _session?.error;
    if (failure != null) {
      throw NosmaiLiveException(_session?.failureCode ?? 'start_failed', failure);
    }
  }

  void _onSessionChanged() {
    final zego = _session;
    if (zego == null || _stopFuture != null) return;
    if (zego.error != null) {
      _error = zego.error;
      unawaited(_stopFuture ??= _shutdown(failure: zego.error));
      return;
    }
    final NosmaiLiveState next;
    if (!zego.joined) {
      next = NosmaiLiveState.connecting;
    } else if (!zego.foreground) {
      next = NosmaiLiveState.paused;
    } else if (zego.reconnecting) {
      next = NosmaiLiveState.reconnecting;
    } else if (zego.sending || _videoMuted) {
      next = NosmaiLiveState.live;
    } else {
      next = NosmaiLiveState.connecting;
    }
    _setState(next);
  }

  Future<void> _shutdown({String? failure}) async {
    if (failure != null) _error = failure;
    if (_state != NosmaiLiveState.idle) _setState(NosmaiLiveState.stopping);
    if (handleAppLifecycle) WidgetsBinding.instance.removeObserver(this);
    final zego = _session;
    if (zego != null) {
      zego.removeListener(_onSessionChanged);
      try {
        await zego.close();
      } catch (_) {/* Best effort. */}
      _error ??= zego.error;
      zego.dispose();
    }
    _setState(_error != null ? NosmaiLiveState.failed : NosmaiLiveState.stopped);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final zego = _session;
    if (zego == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        zego.setForeground(true);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        zego.setForeground(false);
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _setState(NosmaiLiveState next) {
    _state = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    _disposed = true;
    super.dispose();
  }
}
