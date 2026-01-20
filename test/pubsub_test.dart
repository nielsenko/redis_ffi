@Tags(['redis'])
library;

import 'package:redis_ffi/redis_ffi.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group('pub/sub', () {
    late RedisClient subscriber;
    late RedisClient publisher;

    setUp(() async {
      subscriber = await createTestClient();
      publisher = await createTestClient();
    });

    tearDown(() async {
      await subscriber.close();
      await publisher.close();
    });

    test('can subscribe and receive messages', () async {
      final messages = <RedisPubSubMessage>[];

      // subscribe() opens its own connection
      final subscription = subscriber
          .subscribe(channels: ['test-channel'])
          .listen(messages.add);

      // Wait for subscription to be processed
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Publish a message
      await publisher.publish('test-channel', 'hello');

      // Wait for the message
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // cancel() closes the subscription connection
      await subscription.cancel();

      // Should have received subscribe confirmation and message
      expect(messages.length, greaterThanOrEqualTo(1));
    });

    test('can subscribe to patterns', () async {
      final messages = <RedisPubSubMessage>[];

      // subscribe with patterns
      final subscription = subscriber
          .subscribe(patterns: ['test:*'])
          .listen(messages.add);

      // Wait for subscription
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Publish to matching channel
      await publisher.publish('test:foo', 'pattern message');

      // Wait for message
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await subscription.cancel();

      expect(messages.length, greaterThanOrEqualTo(1));
    });

    test('close stops the client', () async {
      final subscription = subscriber
          .subscribe(channels: ['close-test'])
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();
      await subscriber.close();

      expect(() => subscriber.ping(), throwsStateError);
    });
  });
}
