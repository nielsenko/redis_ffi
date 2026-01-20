import 'package:redis_ffi/redis_ffi.dart';

void main() {
  // Connect to Redis server
  final client = RedisClient.connect('localhost', 6379);

  try {
    // Test connection
    print('PING: ${client.ping()}');

    // Set a key
    client.set('greeting', 'Hello, Redis!');
    print('SET greeting: OK');

    // Get the key
    final value = client.get('greeting');
    print('GET greeting: $value');

    // Check if key exists
    print('EXISTS greeting: ${client.exists('greeting')}');

    // Delete the key
    final deleted = client.del(['greeting']);
    print('DEL greeting: $deleted key(s) deleted');

    // Check again
    print('EXISTS greeting: ${client.exists('greeting')}');

    // Execute raw command
    final reply = client.commandArgv(['INFO', 'server']);
    print(
      'INFO server (first 100 chars): ${reply.string?.substring(0, 100)}...',
    );
    reply.free();
  } on RedisException catch (e) {
    print('Redis error: $e');
  } finally {
    client.close();
  }
}
