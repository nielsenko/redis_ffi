import 'package:redis_ffi/redis_ffi.dart';

/// Creates a RedisClient connected to localhost:6379 for testing.
Future<RedisClient> createTestClient() async {
  return RedisClient.connect('localhost', 6379);
}
