import 'dart:async';

import 'package:redis_ffi/redis_ffi.dart';

/// Example demonstrating Redis pub/sub functionality.
///
/// This example requires a running Redis server on localhost:6379.
/// Run it with: dart run example/pubsub_example.dart
void main() async {
  print('Redis Pub/Sub Example');
  print('=====================\n');

  // Create a pub/sub connection for subscribing
  final subscriber = RedisPubSub.connect('localhost', 6379);

  // Create a regular client for publishing
  final publisher = RedisClient.connect('localhost', 6379);

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
    subscriber.subscribe('news');
    subscriber.subscribe('alerts');

    // Subscribe to a pattern
    print('Subscribing to pattern "user:*"...\n');
    subscriber.psubscribe('user:*');

    // Give some time for subscriptions to be processed
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Poll to process subscription confirmations
    subscriber.poll();

    // Publish some messages
    print('Publishing messages...\n');

    publisher.commandArgv(['PUBLISH', 'news', 'Breaking: Dart 3.10 released!']);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    subscriber.poll();

    publisher.commandArgv(['PUBLISH', 'alerts', 'System maintenance tonight']);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    subscriber.poll();

    publisher.commandArgv(['PUBLISH', 'user:123', 'User 123 logged in']);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    subscriber.poll();

    publisher.commandArgv(['PUBLISH', 'user:456', 'User 456 updated profile']);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    subscriber.poll();

    // Wait a bit for any remaining messages
    await Future<void>.delayed(const Duration(milliseconds: 100));
    subscriber.poll();

    // Unsubscribe
    print('Unsubscribing from "news"...');
    subscriber.unsubscribe('news');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    subscriber.poll();

    // Cancel the stream subscription
    await subscription.cancel();

    print('Done!');
  } on RedisException catch (e) {
    print('Redis error: $e');
  } finally {
    subscriber.close();
    publisher.close();
  }
}
