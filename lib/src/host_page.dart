import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nosmai_zegocloud_live/nosmai_zegocloud_live.dart';

import 'config.dart';
import 'stats_overlay.dart';

/// Full-screen Nosmai preview; Start Live publishes exactly that processed
/// video to the ZEGOCLOUD room. Nosmai owns the camera the whole time.
class HostPage extends StatefulWidget {
  const HostPage({
    super.key,
    required this.config,
    required this.roomId,
    required this.userId,
    required this.userName,
  });

  final AppConfig config;
  final String roomId;
  final String userId;
  final String userName;

  @override
  State<HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<HostPage> {
  final _nosmai = NosmaiZegoCloudLive.effects;
  NosmaiLiveBroadcaster? _live;

  bool _nosmaiReady = false;
  bool _cameraReady = false;
  bool _closing = false;
  bool _starting = false;
  String? _fatal;
  String _status = 'Starting…';
  bool _micMuted = false;
  bool _showStats = true;
  List<NosmaiFilter> _filters = const [];
  String? _activeFilter;
  String? _activeName;
  bool _applying = false;

  Timer? _autoLog;
  bool _autoStopScheduled = false;
  NosmaiLiveState? _lastLoggedState;

  @override
  void initState() {
    super.initState();
    _start();
    if (widget.config.autoRole == 'host') {
      _autoLog = Timer.periodic(const Duration(seconds: 3), (_) {
        final live = _live;
        final st = live?.stats;
        debugPrint('[NosmaiZegoAuto] host tick state=${live?.state.name} filter="${_activeName ?? '-'}" '
            'preview=${st?.nosmaiFps.toStringAsFixed(1)} send=${st?.sendFps.toStringAsFixed(1)} '
            'target=${st?.targetFps} enc=${st?.fps.toStringAsFixed(1)} kbps=${st?.bitrateKbps.round()} '
            'rtt=${st?.rttMs} loss=${st?.lossPercent.toStringAsFixed(1)} net=${st?.network} '
            'dropped=${st?.framesDropped} paced=${st?.framesPaced} cpu=${st?.cpuPercent.round()} '
            'mem=${st?.memoryMb.round()} thermal=${st?.thermal} note="${st?.pipelineNote}" warn="${live?.warning}"');
      });
    }
  }

  Future<void> _start() async {
    try {
      final permissions = await NosmaiZegoCloudLive.requestPermissions();
      if (!permissions.camera) throw StateError('Camera permission is required to host.');
      if (!permissions.microphone) _micMuted = true;
      await NosmaiZegoCloudLive.initialize(
        androidLicenseKey: widget.config.nosmaiLicenseKey,
        iosLicenseKey: widget.config.iosLicenseKey,
      );
      if (!mounted) return;
      setState(() {
        _nosmaiReady = true;
        _status = 'Opening camera…';
      });
    } on NosmaiLiveException catch (e) {
      if (mounted) setState(() => _fatal = e.message);
    } catch (e) {
      if (mounted) setState(() => _fatal = '$e');
    }
  }

  Future<void> _onCameraReady() async {
    // Nosmai calls this again after every camera switch; only the first one matters here.
    if (!mounted || _closing || _cameraReady) return;
    setState(() {
      _cameraReady = true;
      _status = 'Preview ready';
    });
    if (widget.config.autoRole == 'host') {
      debugPrint('[NosmaiZegoAuto] host camera ready, starting live');
      unawaited(_toggleLive());
    }
    await _loadFilters();
  }

  Future<void> _loadFilters() async {
    final found = <NosmaiFilter>[];
    try {
      found.addAll(await _nosmai.getLocalFilters());
    } catch (e) {
      debugPrint('[NosmaiZegoExample] local filters: $e');
    }
    try {
      found.addAll(await _nosmai.getCloudFilters(page: 1, limit: 30));
    } catch (e) {
      debugPrint('[NosmaiZegoExample] cloud filters: $e');
    }
    if (mounted) setState(() => _filters = found);
  }

  Future<void> _applyFilter(NosmaiFilter? filter) async {
    if (_applying || !_cameraReady) return;
    setState(() => _applying = true);
    final applyTimer = Stopwatch()..start();
    try {
      if (filter == null) {
        await _nosmai.clearAll();
        _activeFilter = null;
        _activeName = null;
      } else {
        var path = filter.path;
        if (filter.type == 'cloud' && (!filter.isDownloaded || path.isEmpty)) {
          setState(() => _status = 'Downloading ${filter.displayName}…');
          final result = await _nosmai.downloadCloudFilter(filter.cloudIdentifier);
          path = result['path']?.toString() ?? '';
        }
        if (path.isEmpty) throw StateError('No local .nosmai path');
        if (!await _nosmai.applyEffect(path)) throw StateError('Nosmai rejected the package');
        _activeFilter = filter.id;
        _activeName = filter.displayName;
      }
      if (widget.config.autoRole == 'host') {
        debugPrint('[NosmaiZegoAuto] filter applied "${filter?.displayName ?? 'none'}" '
            'type=${filter?.type} in ${applyTimer.elapsedMilliseconds}ms');
      }
      _status = filter == null ? 'Filters cleared' : 'Applied ${filter.displayName}';
    } catch (e) {
      _status = 'Filter failed: $e';
      if (widget.config.autoRole == 'host') {
        debugPrint('[NosmaiZegoAuto] filter FAILED "${filter?.displayName}" after ${applyTimer.elapsedMilliseconds}ms: $e');
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _toggleLive() async {
    final current = _live;
    if (current != null && current.state.isActive) {
      await _stopLive();
      return;
    }
    final live = NosmaiLiveBroadcaster(
      credentials: widget.config.credentials(userId: widget.userId, userName: widget.userName),
      session: NosmaiLiveSession(widget.roomId),
      // 720p30 and no thermal cap: every preview frame is sent, so viewers get the preview's FPS.
      video: const NosmaiLiveVideoConfig(
        resolution: NosmaiLiveResolution.p720,
        fps: 30,
        adaptToThermalState: false,
      ),
    )..addListener(_onLiveChanged);
    live.setMicMuted(_micMuted);
    setState(() {
      _starting = true;
      _live?.dispose();
      _live = live;
      _status = 'Logging in to ${widget.roomId}…';
    });
    try {
      await live.start();
    } on NosmaiLiveException catch (e) {
      if (mounted) setState(() => _status = '${e.code}: ${e.message}');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stopLive() async {
    final live = _live;
    if (live == null) return;
    setState(() => _status = 'Stopping…');
    await live.stop();
  }

  void _onLiveChanged() {
    final live = _live;
    if (!mounted || live == null) return;
    if (widget.config.autoRole == 'host') {
      if (_lastLoggedState != live.state) {
        _lastLoggedState = live.state;
        debugPrint('[NosmaiZegoAuto] host state -> ${live.state.name} ${live.error ?? ''}');
      }
      final stopAfter = widget.config.autoStopSeconds;
      if (live.state == NosmaiLiveState.live && stopAfter > 0 && !_autoStopScheduled) {
        _autoStopScheduled = true;
        Future<void>.delayed(Duration(seconds: stopAfter), () {
          debugPrint('[NosmaiZegoAuto] host stopping live');
          if (mounted) unawaited(_stopLive());
        });
      }
    }
    setState(() {
      _status = switch (live.state) {
        NosmaiLiveState.connecting => 'Logging in to ${widget.roomId}…',
        NosmaiLiveState.live => 'LIVE in ${widget.roomId} · stream ${live.streamId}',
        NosmaiLiveState.reconnecting => 'Reconnecting…',
        NosmaiLiveState.paused => 'Paused in background',
        NosmaiLiveState.stopping => 'Stopping…',
        NosmaiLiveState.stopped => 'Live ended',
        NosmaiLiveState.failed => 'Failed: ${live.error}',
        _ => _status,
      };
    });
  }

  void _toggleMic() {
    setState(() => _micMuted = !_micMuted);
    _live?.setMicMuted(_micMuted);
  }

  Future<void> _exit() async {
    if (_closing) return;
    setState(() => _closing = true);
    await _live?.stop();
    try {
      if (_nosmai.isInitialized) await _nosmai.endCameraSession();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _autoLog?.cancel();
    _live?.removeListener(_onLiveChanged);
    _live?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = _live;
    final isLive = live?.state == NosmaiLiveState.live;
    final active = live?.state.isActive ?? false;
    final busy = _starting || live?.state == NosmaiLiveState.stopping;
    final warning = live?.warning;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          if (_fatal != null)
            Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_fatal!, textAlign: TextAlign.center)))
          // Stays mounted while closing: Nosmai requires endCameraSession before removal.
          else if (_nosmaiReady)
            // Show the whole 9:16 frame, exactly what viewers receive.
            Center(
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: NosmaiCameraPreview(
                  onInitialized: _onCameraReady,
                  onError: (msg) {
                    if (mounted) setState(() => _status = 'Camera error: $msg');
                  },
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(children: [
                  IconButton.filledTonal(onPressed: _exit, icon: const Icon(Icons.arrow_back)),
                  const SizedBox(width: 8),
                  if (isLive) const Chip(label: Text('LIVE'), backgroundColor: Colors.red, visualDensity: VisualDensity.compact),
                  const Spacer(),
                  IconButton.filledTonal(
                    tooltip: 'Stats',
                    onPressed: () => setState(() => _showStats = !_showStats),
                    icon: Icon(_showStats ? Icons.speed : Icons.speed_outlined),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Microphone',
                    onPressed: _toggleMic,
                    icon: Icon(_micMuted ? Icons.mic_off : Icons.mic),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Switch camera',
                    onPressed: _cameraReady ? () => _nosmai.switchCamera() : null,
                    icon: const Icon(Icons.cameraswitch),
                  ),
                ]),
              ),
              if (_showStats && live != null && active)
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(padding: const EdgeInsets.all(8), child: StatsOverlay(stats: live.stats, host: true)),
                ),
              const Spacer(),
              _filterStrip(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(warning != null && active ? '$_status\n$warning' : _status,
                    maxLines: 3, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    style: active ? FilledButton.styleFrom(backgroundColor: Colors.red) : null,
                    onPressed: _cameraReady && !busy && !_closing ? _toggleLive : null,
                    icon: busy
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(active ? Icons.stop_circle : Icons.sensors),
                    label: Text(active ? 'Stop Live' : 'Start Live'),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _filterStrip() {
    Widget chip(String label, bool selected, VoidCallback? onTap) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: ChoiceChip(label: Text(label), selected: selected, onSelected: onTap == null ? null : (_) => onTap()),
        );
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          chip('None', _activeFilter == null, _cameraReady && !_applying ? () => _applyFilter(null) : null),
          for (final filter in _filters)
            chip(filter.displayName.isNotEmpty ? filter.displayName : filter.name, _activeFilter == filter.id,
                _cameraReady && !_applying ? () => _applyFilter(filter) : null),
        ],
      ),
    );
  }
}
