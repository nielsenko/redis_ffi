import 'package:redis_ffi/redis_ffi.dart';

/// Example demonstrating Redis pub/sub functionality.
///
/// This example requires a running Redis server on localhost:6379.
/// Run it with: dart run example/pubsub_example.dart
void main() async {
  print('Redis Pub/Sub Example');
  print('=====================\n');

  // Create a single client - subscribe() opens its own dedicated connection
  final client = await RedisClient.connect('localhost', 6379);

  try {
    // Subscribe to channels and patterns in a single call
    // This opens a dedicated connection for the subscription
    print('Subscribing to channels and patterns...\n');
    final subscription = client
        .subscribe(channels: ['news', 'alerts'], patterns: ['user:*'])
        .listen((message) {
          if (message.type == .message || message.type == .pmessage) {
            print('[${message.channel}]: ${message.message}');
          }
        });

    // Small delay to ensure subscription is active
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Publish some messages (uses the main client connection)
    print('Publishing messages...\n');
    await client.publish('news', 'Breaking: Dart 3.10 released!');
    await client.publish('alerts', 'System maintenance tonight');
    await client.publish('user:123', 'User 123 logged in');
    await client.publish('user:456', 'User 456 updated profile');

    // Small delay to receive messages
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Cancel subscription (closes the dedicated connection)
    print('\nCancelling subscription...');
    await subscription.cancel();

    print('Done!');
  } on RedisException catch (e) {
    print('Redis error: $e');
  } finally {
    await client.close();
  }
}
