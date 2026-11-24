import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'credentials.dart';
import 'native_bridge.dart';
import 'stats.dart';
import 'zego_session.dart';

/// Watches a broadcaster in a ZEGOCLOUD room. Viewers do not need Nosmai or a
/// Nosmai license: effects are already part of the received video.
///
/// ```dart
/// final viewer = NosmaiLiveViewer(
///   credentials: NosmaiLiveCredentials(appId: appId, appSign: appSign, userId: 'viewer_7'),
///   session: const NosmaiLiveSession('my-room'),
/// );
/// await viewer.start();
/// // build: NosmaiLiveViewerView(viewer: viewer)
/// ```
class NosmaiLiveViewer extends ChangeNotifier with WidgetsBindingObserver {
  NosmaiLiveViewer({
    required this.credentials,
    required this.session,
    this.hostUserId,
    this.handleAppLifecycle = true,
    this.keepScreenOn = true,
    @visibleForTesting NativeBridge bridge = const NativeBridge(),
    @visibleForTesting Duration statsInterval = const Duration(seconds: 1),
    @visibleForTesting Duration joinTimeout = const Duration(seconds: 25),
    @visibleForTesting DateTime Function()? clock,
  })  : _bridge = bridge,
        _statsInterval = statsInterval,
        _joinTimeout = joinTimeout,
        _clock = clock ?? DateTime.now;

  final NosmaiLiveCredentials credentials;
  final NosmaiLiveSession session;

  /// The broadcaster to watch, by user ID, when [NosmaiLiveSession.streamId]
  /// is not given. When both are null: the first broadcaster in the room.
  final String? hostUserId;

  /// Pause playback in the background and resume in the foreground.
  final bool handleAppLifecycle;

  /// Keep the screen awake while watching.
  final bool keepScreenOn;

  final NativeBridge _bridge;
  final Duration _statsInterval;
  final Duration _joinTimeout;
  final DateTime Function() _clock;

  ZegoLiveSession? _session;
  Future<void>? _stopFuture;
  NosmaiLiveState _state = NosmaiLiveState.idle;
  String? _error;
  bool _speakerMuted = false;
  bool _disposed = false;

  NosmaiLiveState get state => _state;
  NosmaiLiveStats get stats => _session?.stats ?? NosmaiLiveStats.empty;
  String? get error => _error;
  String? get warning => _session?.warning;
  bool get speakerMuted => _speakerMuted;

  /// True while the broadcaster's video is on screen.
  bool get hasVideo => _session?.remoteVideo ?? false;

  /// The broadcaster being watched, once one is found.
  String? get watchingUserName => _session?.remoteUserName;
  String? get watchingUserId => _session?.remoteUserId;
  String? get watchingStreamId => _session?.remoteStreamId;

  /// True when the viewer stopped because the broadcaster ended the live.
  bool get endedByHost => _session?.endedByHost ?? false;

  /// Logs in to the room. Completes once joined; video follows when the
  /// broadcaster is live. Throws [NosmaiLiveException] on failure.
  Future<void> start() async {
    if (_state != NosmaiLiveState.idle) {
      throw StateError('A viewer can be started once; create a new one.');
    }
    _setState(NosmaiLiveState.connecting);
    try {
      final configProblem = session.validate();
      if (configProblem != null) throw NosmaiLiveException('invalid_config', configProblem);
      final credentialProblem = credentials.validate(now: _clock());
      if (credentialProblem != null) throw NosmaiLiveException('invalid_credentials', credentialProblem);
      // Viewers only play: no camera or microphone permission is needed.

      final zego = ZegoLiveSession(
        bridge: _bridge,
        isHost: false,
        statsInterval: _statsInterval,
        joinTimeout: _joinTimeout,
        joinArguments: {
          'host': false,
          'appId': credentials.appId,
          'appSign': credentials.appSign,
          'token': credentials.token,
          'userId': credentials.userId,
          'userName': credentials.userName,
          'roomId': session.roomId,
          'streamId': session.streamId,
          'hostUserId': hostUserId,
          'speakerMuted': _speakerMuted,
          'keepScreenOn': keepScreenOn,
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

  void setSpeakerMuted(bool muted) {
    _speakerMuted = muted;
    _session?.setSpeakerMuted(muted);
    _notify();
  }

  void _throwIfStopped() {
    if (_stopFuture != null || _disposed) {
      throw const NosmaiLiveException('stopped', 'The viewer was stopped while starting.');
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
    if (zego.endedByHost) {
      unawaited(_stopFuture ??= _shutdown());
      return;
    }
    final NosmaiLiveState next;
    if (!zego.joined) {
      next = NosmaiLiveState.connecting;
    } else if (!zego.foreground) {
      next = NosmaiLiveState.paused;
    } else if (zego.reconnecting) {
      next = NosmaiLiveState.reconnecting;
    } else if (zego.remoteVideo) {
      next = NosmaiLiveState.live;
    } else {
      next = NosmaiLiveState.waitingForHost;
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

/// Renders the video a [NosmaiLiveViewer] receives, through ZEGO's own renderer.
///
/// Shows [placeholder] until the broadcaster's video is on screen.
class NosmaiLiveViewerView extends StatelessWidget {
  const NosmaiLiveViewerView({super.key, required this.viewer, this.placeholder});

  final NosmaiLiveViewer viewer;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final supported = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
    return Stack(fit: StackFit.expand, children: [
      if (supported) const _ZegoVideoView(),
      ListenableBuilder(
        listenable: viewer,
        builder: (context, _) =>
            viewer.hasVideo ? const SizedBox.shrink() : (placeholder ?? const SizedBox.shrink()),
      ),
    ]);
  }
}

/// Android: ZEGO renders into a TextureView, which Flutter composes as a texture layer.
/// iOS (not supported yet): a UIView embedded as a UiKitView.
class _ZegoVideoView extends StatelessWidget {
  const _ZegoVideoView();

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return const UiKitView(
        viewType: NativeBridge.remoteVideoViewType,
        creationParamsCodec: StandardMessageCodec(),
      );
    }
    return const AndroidView(
      viewType: NativeBridge.remoteVideoViewType,
      creationParamsCodec: StandardMessageCodec(),
    );
  }
}
