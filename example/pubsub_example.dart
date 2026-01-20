import 'dart:async';

import 'package:redis_ffi/redis_ffi.dart';

/// Example demonstrating Redis pub/sub functionality.
///
/// This example requires a running Redis server on localhost:6379.
/// Run it with: dart run example/pubsub_example.dart
void main() async {
  print('Redis Pub/Sub Example');
  print('=====================\n');

  // Create a client for subscribing
  final subscriber = await RedisClient.connect('localhost', 6379);

  // Create a separate client for publishing (can't publish on a subscribed connection)
  final publisher = await RedisClient.connect('localhost', 6379);

  try {
    // Listen to messages
    final subscription = subscriber.messages.listen((message) {
      print('Received message:');
      print('  Type: ${message.type}');
      print('  Channel: ${message.channel}');
      print('  Pattern: ${message.pattern ?? "(none)"}');
      print('  Message: ${message.message ?? "(none)"}');
      print('');
    });

    // Subscribe to channels
    print('Subscribing to "news" and "alerts" channels...');
    await subscriber.subscribe(['news', 'alerts']);

    // Subscribe to a pattern
    print('Subscribing to pattern "user:*"...\n');
    await subscriber.psubscribe(['user:*']);

    // Give some time for subscriptions to be processed
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Publish some messages
    print('Publishing messages...\n');

    await publisher.publish('news', 'Breaking: Dart 3.10 released!');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await publisher.publish('alerts', 'System maintenance tonight');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await publisher.publish('user:123', 'User 123 logged in');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await publisher.publish('user:456', 'User 456 updated profile');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Wait a bit for messages to be received
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Unsubscribe
    print('Unsubscribing from "news"...');
    await subscriber.unsubscribe(['news']);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Cancel the stream subscription
    await subscription.cancel();

    print('Done!');
  } on RedisException catch (e) {
    print('Redis error: $e');
  } finally {
    await subscriber.close();
    await publisher.close();
  }
}
