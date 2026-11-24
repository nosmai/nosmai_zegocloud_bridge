import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nosmai_zegocloud_live/nosmai_zegocloud_live.dart';

import 'config.dart';
import 'stats_overlay.dart';

/// Logs in to the ZEGOCLOUD room and shows the broadcaster's filtered video.
/// Viewers need no Nosmai license: the effects are already in the video.
class ViewerPage extends StatefulWidget {
  const ViewerPage({
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
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  NosmaiLiveViewer? _viewer;
  String _status = 'Starting…';
  bool _leaving = false;

  Timer? _autoLog;

  @override
  void initState() {
    super.initState();
    _join();
    if (widget.config.autoRole == 'viewer') {
      _autoLog = Timer.periodic(const Duration(seconds: 3), (_) {
        final viewer = _viewer;
        final st = viewer?.stats;
        debugPrint('[NosmaiZegoAuto] viewer tick state=${viewer?.state.name} hasVideo=${viewer?.hasVideo} '
            'watching=${viewer?.watchingUserName} size=${st?.width}x${st?.height} fps=${st?.fps.toStringAsFixed(1)} '
            'kbps=${st?.bitrateKbps.round()} latency=${st?.latencyMs} rtt=${st?.rttMs} '
            'loss=${st?.lossPercent.toStringAsFixed(1)} net=${st?.network} cpu=${st?.cpuPercent.round()} '
            'mem=${st?.memoryMb.round()} status="$_status"');
      });
    }
  }

  Future<void> _join() async {
    final viewer = NosmaiLiveViewer(
      credentials: widget.config.credentials(userId: widget.userId, userName: widget.userName),
      session: NosmaiLiveSession(widget.roomId),
    )..addListener(_onViewerChanged);
    setState(() {
      _viewer = viewer;
      _status = 'Logging in to ${widget.roomId}…';
    });
    try {
      await viewer.start();
    } on NosmaiLiveException catch (e) {
      if (mounted) setState(() => _status = '${e.code}: ${e.message}');
    }
  }

  void _onViewerChanged() {
    final viewer = _viewer;
    if (!mounted || viewer == null) return;
    setState(() {
      _status = switch (viewer.state) {
        NosmaiLiveState.connecting => 'Logging in to ${widget.roomId}…',
        NosmaiLiveState.waitingForHost => 'Connected — waiting for the broadcaster',
        NosmaiLiveState.live => 'Watching ${viewer.watchingUserName ?? 'broadcaster'}',
        NosmaiLiveState.reconnecting => 'Reconnecting…',
        NosmaiLiveState.paused => 'Paused in background',
        NosmaiLiveState.stopping => 'Leaving…',
        NosmaiLiveState.stopped => viewer.endedByHost ? 'The broadcaster ended the live' : 'Left',
        NosmaiLiveState.failed => 'Failed: ${viewer.error}',
        NosmaiLiveState.idle => _status,
      };
    });
  }

  Future<void> _leave() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    await _viewer?.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _autoLog?.cancel();
    _viewer?.removeListener(_onViewerChanged);
    _viewer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewer = _viewer;
    final active = viewer?.state.isActive ?? false;
    final warning = viewer?.warning;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          if (viewer != null && active && !_leaving)
            NosmaiLiveViewerView(
              viewer: viewer,
              placeholder: const Center(child: Icon(Icons.live_tv, size: 64, color: Colors.white24)),
            ),
          SafeArea(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  IconButton.filledTonal(onPressed: _leave, icon: const Icon(Icons.arrow_back)),
                  const SizedBox(width: 8),
                  Chip(label: Text(viewer?.state.name ?? 'idle'), visualDensity: VisualDensity.compact),
                  const Spacer(),
                  if (viewer != null)
                    IconButton.filledTonal(
                      tooltip: 'Speaker',
                      onPressed: () => viewer.setSpeakerMuted(!viewer.speakerMuted),
                      icon: Icon(viewer.speakerMuted ? Icons.volume_off : Icons.volume_up),
                    ),
                ]),
              ),
              if (viewer != null && active)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: StatsOverlay(stats: viewer.stats, host: false),
                ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(warning != null && active ? '$_status\n$warning' : _status,
                    style: const TextStyle(fontSize: 12)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: _leaving ? null : _leave,
                    icon: const Icon(Icons.call_end),
                    label: const Text('Leave'),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
