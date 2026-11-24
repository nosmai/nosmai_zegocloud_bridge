import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/config.dart';
import 'src/host_page.dart';
import 'src/viewer_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const NosmaiZegoApp());
}

class NosmaiZegoApp extends StatelessWidget {
  const NosmaiZegoApp({super.key, this.config = const AppConfig.fromEnvironment()});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nosmai × ZEGOCLOUD Live',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0055FF), brightness: Brightness.dark),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      ),
      home: HomePage(config: config),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.config});

  final AppConfig config;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final _room = TextEditingController(text: widget.config.roomId);
  final _name = TextEditingController(text: 'user${DateTime.now().millisecondsSinceEpoch % 10000}');

  // ZEGOCLOUD signs out the older of two logins with the same user ID, so two
  // phones with the same name must still get different IDs.
  final _suffix = Random().nextInt(0x10000).toRadixString(16).padLeft(4, '0');

  String get _userId => '${userIdFor(_name.text)}_$_suffix';

  @override
  void initState() {
    super.initState();
    final role = widget.config.autoRole;
    if (role == 'host' || role == 'viewer') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(role == 'host'));
    }
  }

  @override
  void dispose() {
    _room.dispose();
    _name.dispose();
    super.dispose();
  }

  void _open(bool host) {
    final room = _room.text.trim();
    final name = _name.text.trim();
    if (room.isEmpty || name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a room ID and a name.')));
      return;
    }
    final userId = _userId;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => host
          ? HostPage(config: widget.config, roomId: room, userId: userId, userName: name)
          : ViewerPage(config: widget.config, roomId: room, userId: userId, userName: name),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final problem = widget.config.problem();
    return Scaffold(
      appBar: AppBar(title: const Text('Nosmai × ZEGOCLOUD Live')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _room, decoration: const InputDecoration(labelText: 'Room ID')),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Display name'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text('AppID ${widget.config.zegoAppId.isEmpty ? '-' : widget.config.zegoAppId} · '
            'user ID $_userId',
            style: Theme.of(context).textTheme.bodySmall),
        if (problem != null) Text(problem, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => _open(true),
          icon: const Icon(Icons.videocam),
          label: const Text('Host (Nosmai filters → ZEGOCLOUD)'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => _open(false),
          icon: const Icon(Icons.live_tv),
          label: const Text('Viewer'),
        ),
      ]),
    );
  }
}
