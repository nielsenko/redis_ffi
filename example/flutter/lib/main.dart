import 'dart:async';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:redis_ffi/redis_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MainApp());
}

const _prefKeyHost = 'redis_host';
const _prefKeyPort = 'redis_port';

/// Returns the default Redis host for the current platform.
///
/// - Android emulator: 10.0.2.2 (special alias for host loopback)
/// - iOS simulator: localhost (shares network with host)
/// - Real devices / Desktop: empty (user must enter their Redis server IP)
Future<String> getDefaultRedisHost() async {
  final deviceInfo = DeviceInfoPlugin();

  if (Platform.isAndroid) {
    final info = await deviceInfo.androidInfo;
    if (!info.isPhysicalDevice) {
      // Android emulator uses 10.0.2.2 to reach host machine
      return '10.0.2.2';
    }
    // Real Android device - user needs to enter their server IP
    return '';
  }

  if (Platform.isIOS) {
    final info = await deviceInfo.iosInfo;
    if (!info.isPhysicalDevice) {
      // iOS simulator shares network with host
      return 'localhost';
    }
    // Real iOS device - user needs to enter their server IP
    return '';
  }

  // Desktop platforms (macOS, Windows, Linux) - localhost works
  return 'localhost';
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
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '6379');
  final _channelController = TextEditingController(text: 'flutter-test');
  final _messageController = TextEditingController();
  final _logController = ScrollController();

  final List<String> _logs = [];
  RedisClient? _client;
  bool _isConnecting = false;
  StreamSubscription<RedisPubSubMessage>? _subscription;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedHost = prefs.getString(_prefKeyHost);
    final savedPort = prefs.getInt(_prefKeyPort);

    if (savedHost != null) {
      // Use previously saved host
      _hostController.text = savedHost;
    } else {
      // First run - use platform default
      _hostController.text = await getDefaultRedisHost();
    }

    if (savedPort != null) {
      _portController.text = savedPort.toString();
    }

    if (mounted) setState(() {});
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyHost, _hostController.text.trim());
    final port = int.tryParse(_portController.text.trim());
    if (port != null) {
      await prefs.setInt(_prefKeyPort, port);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _client?.close();
    _hostController.dispose();
    _portController.dispose();
    _channelController.dispose();
    _messageController.dispose();
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
      // Save settings on successful connection
      await _saveSettings();
    } catch (e) {
      _log('Connection failed: $e');
    } finally {
      setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnect() async {
    if (_client == null) return;

    // Cancel subscription first
    if (_subscription != null) {
      await _unsubscribe();
    }

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

  Future<void> _keys() async {
    if (_client == null) {
      _log('Not connected.');
      return;
    }

    try {
      final allKeys = await _client!.keys('*');
      _log('KEYS * -> ${allKeys.length} keys found');
    } catch (e) {
      _log('KEYS failed: $e');
    }
  }

  Future<void> _subscribe() async {
    if (_client == null) {
      _log('Not connected.');
      return;
    }

    final channel = _channelController.text.trim();
    if (channel.isEmpty) {
      _log('Please enter a channel name.');
      return;
    }

    _log('Subscribing to "$channel"...');

    try {
      _subscription = _client!
          .subscribe(channels: [channel])
          .listen(
            (msg) {
              if (msg.type == RedisPubSubMessageType.message) {
                _log('RECV [${msg.channel}]: ${msg.message}');
              } else if (msg.type == RedisPubSubMessageType.subscribe) {
                _log('Subscribed to "${msg.channel}"');
              }
            },
            onError: (e) {
              _log('Subscription error: $e');
              _subscription = null;
              setState(() {});
            },
            onDone: () {
              _log('Subscription closed.');
              _subscription = null;
              setState(() {});
            },
          );
      setState(() {});
    } catch (e) {
      _log('Subscribe failed: $e');
    }
  }

  Future<void> _unsubscribe() async {
    if (_subscription == null) return;

    _log('Unsubscribing...');
    await _subscription!.cancel();
    _subscription = null;
    _log('Unsubscribed.');
    setState(() {});
  }

  Future<void> _publish() async {
    if (_client == null) {
      _log('Not connected.');
      return;
    }

    final channel = _channelController.text.trim();
    final message = _messageController.text.trim();

    if (channel.isEmpty) {
      _log('Please enter a channel name.');
      return;
    }
    if (message.isEmpty) {
      _log('Please enter a message.');
      return;
    }

    try {
      final receivers = await _client!.publish(channel, message);
      _log('PUBLISH "$channel" -> $receivers receiver(s)');
      _messageController.clear();
    } catch (e) {
      _log('Publish failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _client != null;
    final isSubscribed = _subscription != null;

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
                  onPressed: isConnected ? _keys : null,
                  child: const Text('KEYS *'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Pub/Sub section
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Pub/Sub',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _channelController,
                          decoration: const InputDecoration(
                            labelText: 'Channel',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          enabled: isConnected && !isSubscribed,
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: isConnected
                            ? (isSubscribed ? _unsubscribe : _subscribe)
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isSubscribed
                              ? Colors.orange.shade100
                              : Colors.blue.shade100,
                        ),
                        child: Text(isSubscribed ? 'Unsubscribe' : 'Subscribe'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          decoration: const InputDecoration(
                            labelText: 'Message',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          enabled: isConnected,
                          onSubmitted: (_) => _publish(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: isConnected ? _publish : null,
                        child: const Text('Publish'),
                      ),
                    ],
                  ),
                ],
              ),
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
