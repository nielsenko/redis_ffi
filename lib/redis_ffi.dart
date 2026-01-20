/// A Dart FFI wrapper for hiredis, the minimalistic C client for Redis.
///
/// This package provides async Redis client functionality using
/// direct FFI bindings to the hiredis C library, with proper memory
/// management using Dart's NativeFinalizer.
///
/// ## Usage
///
/// ```dart
/// import 'package:redis_ffi/redis_ffi.dart';
///
/// void main() async {
///   final client = await RedisClient.connect('localhost', 6379);
///   try {
///     await client.set('key', 'value');
///     print(await client.get('key')); // prints: value
///   } finally {
///     await client.close();
///   }
/// }
/// ```
library;

export 'src/redis_client.dart'
    show RedisClient, RedisException, RedisPubSubMessage;
export 'src/redis_reply.dart' show RedisReply, RedisReplyType;
