import 'package:redis_ffi/redis_ffi.dart';

void main() async {
  // Connect to Redis server
  final client = await RedisClient.connect('localhost', 6379);

  try {
    // Test connection
    print('PING: ${await client.ping()}');

    // Set a key
    await client.set('greeting', 'Hello, Redis!');
    print('SET greeting: OK');

    // Get the key
    final value = await client.get('greeting');
    print('GET greeting: $value');

    // Check if key exists
    print('EXISTS greeting: ${await client.exists('greeting')}');

    // Delete the key
    final deleted = await client.del(['greeting']);
    print('DEL greeting: $deleted key(s) deleted');

    // Check again
    print('EXISTS greeting: ${await client.exists('greeting')}');
  } on RedisException catch (e) {
    print('Redis error: $e');
  } finally {
    await client.close();
  }
}
