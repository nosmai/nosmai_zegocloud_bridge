import 'package:flutter/material.dart';
import 'package:nosmai_zegocloud_live/nosmai_zegocloud_live.dart';

/// Compact, monospace diagnostics panel. Every value is measured: ZEGOCLOUD
/// quality callbacks, the plugin's frame counters, and the process's CPU time
/// and RSS.
///
/// The headline row comes first: preview and send FPS on the host, rendered
/// FPS on the viewer.
class StatsOverlay extends StatelessWidget {
  const StatsOverlay({super.key, required this.stats, required this.host});

  final NosmaiLiveStats stats;
  final bool host;

  @override
  Widget build(BuildContext context) {
    String f(num v, [int digits = 1]) => v.toStringAsFixed(digits);
    final headline = host
        ? 'preview ${f(stats.nosmaiFps)} fps   send ${f(stats.sendFps)} fps'
        : 'fps ${f(stats.fps)}';
    final codec = stats.hardwareCodec ? 'hw' : 'sw';
    final lines = <String>[
      if (host) ...[
        'zego out ${f(stats.fps)} fps (enc ${f(stats.encodeFps)})  ${stats.width}x${stats.height}  '
            '${f(stats.bitrateKbps, 0)} kbps $codec',
        'path ${stats.transport.isEmpty ? '-' : stats.transport}  conv ${f(stats.convertMs, 2)} ms  '
            'sent ${stats.framesSent}  drop ${stats.framesDropped}',
        'target ${stats.targetFps} fps  paced ${stats.framesPaced}',
        if (stats.pipelineNote.isNotEmpty) 'note ${stats.pipelineNote}',
      ] else ...[
        '${stats.width}x${stats.height}  ${f(stats.bitrateKbps, 0)} kbps $codec',
        'delay ${stats.latencyMs} ms',
      ],
      'rtt ${stats.rttMs} ms  loss ${f(stats.lossPercent)}%',
      'CPU ${f(stats.cpuPercent, 0)}% of 1 core  RSS ${f(stats.memoryMb, 0)} MB',
      'quality ${stats.network.isEmpty ? '-' : stats.network}  others ${stats.participants}',
    ];
    const mono = TextStyle(fontFamily: 'monospace', color: Colors.white);
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(headline, style: mono.copyWith(fontSize: 15, fontWeight: FontWeight.bold, height: 1.3)),
          Text(lines.join('\n'), style: mono.copyWith(fontSize: 11, height: 1.35)),
        ]),
      ),
    );
  }
}
