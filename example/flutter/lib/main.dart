import 'package:flutter/material.dart';
import 'package:redis_ffi/redis_ffi.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Redis FFI Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      home: const RedisTestPage(),
    );
  }
}

class RedisTestPage extends StatefulWidget {
  const RedisTestPage({super.key});

  @override
  State<RedisTestPage> createState() => _RedisTestPageState();
}

class _RedisTestPageState extends State<RedisTestPage> {
  final _hostController = TextEditingController(text: '10.0.2.2');
  final _portController = TextEditingController(text: '6379');
  final _logController = ScrollController();

  final List<String> _logs = [];
  RedisClient? _client;
  bool _isConnecting = false;

  @override
  void dispose() {
    _client?.close();
    _hostController.dispose();
    _portController.dispose();
    _logController.dispose();
    super.dispose();
  }

  void _log(String message) {
    setState(() {
      _logs.add('[${DateTime.now().toString().substring(11, 19)}] $message');
    });
    Future.delayed(const Duration(milliseconds: 50), () {
      if (_logController.hasClients) {
        _logController.animateTo(
          _logController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _connect() async {
    if (_isConnecting) return;

    setState(() => _isConnecting = true);

    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 6379;

    _log('Connecting to $host:$port...');

    try {
      _client = await RedisClient.connect(host, port);
      _log('Connected!');
    } catch (e) {
      _log('Connection failed: $e');
    } finally {
      setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnect() async {
    if (_client == null) return;

    _log('Disconnecting...');
    try {
      await _client!.close();
      _client = null;
      _log('Disconnected.');
    } catch (e) {
      _log('Disconnect error: $e');
    }
    setState(() {});
  }

  Future<void> _ping() async {
    if (_client == null) {
      _log('Not connected.');
      return;
    }

    try {
      final result = await _client!.ping();
      _log('PING -> $result');
    } catch (e) {
      _log('PING failed: $e');
    }
  }

  Future<void> _setGet() async {
    if (_client == null) {
      _log('Not connected.');
      return;
    }

    try {
      final key = 'flutter_test_${DateTime.now().millisecondsSinceEpoch}';
      final value = 'Hello from Flutter!';

      await _client!.set(key, value);
      _log('SET $key -> OK');

      final result = await _client!.get(key);
      _log('GET $key -> $result');

      await _client!.del([key]);
      _log('DEL $key -> OK');
    } catch (e) {
      _log('SET/GET failed: $e');
    }
  }

  Future<void> _info() async {
    if (_client == null) {
      _log('Not connected.');
      return;
    }

    try {
      // Use keys command with a limited pattern
      final allKeys = await _client!.keys('*');
      _log('KEYS * -> ${allKeys.length} keys found');
    } catch (e) {
      _log('KEYS failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _client != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Redis FFI Example'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Connection settings
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostController,
                    decoration: const InputDecoration(
                      labelText: 'Host',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    enabled: !isConnected,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.number,
                    enabled: !isConnected,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Connect/Disconnect button
            ElevatedButton.icon(
              onPressed: _isConnecting
                  ? null
                  : (isConnected ? _disconnect : _connect),
              icon: Icon(isConnected ? Icons.link_off : Icons.link),
              label: Text(
                _isConnecting
                    ? 'Connecting...'
                    : (isConnected ? 'Disconnect' : 'Connect'),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isConnected
                    ? Colors.red.shade100
                    : Colors.green.shade100,
              ),
            ),
            const SizedBox(height: 12),

            // Command buttons
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: isConnected ? _ping : null,
                  child: const Text('PING'),
                ),
                ElevatedButton(
                  onPressed: isConnected ? _setGet : null,
                  child: const Text('SET/GET/DEL'),
                ),
                ElevatedButton(
                  onPressed: isConnected ? _info : null,
                  child: const Text('KEYS *'),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Log output
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.grey.shade900,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  controller: _logController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _logs.length,
                  itemBuilder: (context, index) {
                    return Text(
                      _logs[index],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.greenAccent,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
