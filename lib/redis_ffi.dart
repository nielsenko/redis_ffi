/// A Dart FFI wrapper for hiredis, the minimalistic C client for Redis.
///
/// This package provides synchronous Redis client functionality using
/// direct FFI bindings to the hiredis C library, with proper memory
/// management using Dart's NativeFinalizer.
///
/// ## Usage
///
/// ```dart
/// import 'package:redis_ffi/redis_ffi.dart';
///
/// void main() {
///   final client = RedisClient.connect('localhost', 6379);
///   try {
///     client.set('key', 'value');
///     print(client.get('key')); // prints: value
///   } finally {
///     client.close();
///   }
/// }
/// ```
library;

export 'src/redis_client.dart' show RedisClient, RedisException;
export 'src/redis_pubsub.dart' show RedisPubSub, RedisPubSubMessage;
export 'src/redis_reply.dart' show RedisReply, RedisReplyType;
