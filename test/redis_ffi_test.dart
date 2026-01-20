library;

import 'package:redis_ffi/redis_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('RedisPubSubMessage', () {
    test('class is exported', () {
      expect(RedisPubSubMessage, isNotNull);
    });
  });

  group('RedisReplyType', () {
    test('fromValue returns correct type', () {
      expect(RedisReplyType.fromValue(1), equals(RedisReplyType.string));
      expect(RedisReplyType.fromValue(2), equals(RedisReplyType.array));
      expect(RedisReplyType.fromValue(3), equals(RedisReplyType.integer));
      expect(RedisReplyType.fromValue(4), equals(RedisReplyType.nil));
      expect(RedisReplyType.fromValue(5), equals(RedisReplyType.status));
      expect(RedisReplyType.fromValue(6), equals(RedisReplyType.error));
    });

    test('fromValue throws for unknown value', () {
      expect(() => RedisReplyType.fromValue(999), throwsArgumentError);
    });
  });

  group('RedisException', () {
    test('toString includes message', () {
      final exception = RedisException('test error');
      expect(exception.toString(), contains('test error'));
    });
  });

  // Integration tests require a running Redis server
  group('RedisClient integration', () {
    late RedisClient client;

    setUp(() async {
      client = await RedisClient.connect('localhost', 6379);
    });

    tearDown(() async {
      await client.close();
    });

    test('ping returns PONG', () async {
      expect(await client.ping(), equals('PONG'));
    });

    test('ping with message returns message', () async {
      expect(await client.ping('hello'), equals('hello'));
    });

    test('set and get work correctly', () async {
      await client.set('test_key', 'test_value');
      expect(await client.get('test_key'), equals('test_value'));

      // Cleanup
      await client.del(['test_key']);
    });

    test('get returns null for non-existent key', () async {
      expect(await client.get('non_existent_key_12345'), isNull);
    });

    test('exists returns correct value', () async {
      await client.set('exists_test', 'value');
      expect(await client.exists('exists_test'), isTrue);
      expect(await client.exists('non_existent_key_12345'), isFalse);

      // Cleanup
      await client.del(['exists_test']);
    });

    test('del deletes keys', () async {
      await client.set('del_test1', 'value1');
      await client.set('del_test2', 'value2');

      final deleted = await client.del(['del_test1', 'del_test2']);
      expect(deleted, equals(2));
      expect(await client.exists('del_test1'), isFalse);
      expect(await client.exists('del_test2'), isFalse);
    });

    test('command works with array reply', () async {
      await client.set('array_test1', 'value1');
      await client.set('array_test2', 'value2');

      final reply = await client.command([
        'MGET',
        'array_test1',
        'array_test2',
      ]);
      expect(reply?.type, equals(RedisReplyType.array));
      expect(reply?.length, equals(2));
      expect(reply?[0]?.string, equals('value1'));
      expect(reply?[1]?.string, equals('value2'));
      reply?.free();

      // Cleanup
      await client.del(['array_test1', 'array_test2']);
    });

    test('pipeline executes multiple commands', () async {
      final results = await client.pipeline([
        ['SET', 'pipe1', 'value1'],
        ['SET', 'pipe2', 'value2'],
        ['GET', 'pipe1'],
        ['GET', 'pipe2'],
      ]);

      expect(results.length, equals(4));
      expect(results[2]?.string, equals('value1'));
      expect(results[3]?.string, equals('value2'));

      for (final reply in results) {
        reply?.free();
      }

      // Cleanup
      await client.del(['pipe1', 'pipe2']);
    });
  }, tags: ['redis']);

  group('RedisClient pub/sub integration', () {
    late RedisClient subscriber;
    late RedisClient publisher;

    setUp(() async {
      subscriber = await RedisClient.connect('localhost', 6379);
      publisher = await RedisClient.connect('localhost', 6379);
    });

    tearDown(() async {
      await subscriber.close();
      await publisher.close();
    });

    test('can subscribe and receive messages', () async {
      final messages = <RedisPubSubMessage>[];
      final subscription = subscriber.messages.listen(messages.add);

      await subscriber.subscribe(['test-channel']);

      // Wait for subscription to be processed
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Publish a message
      await publisher.publish('test-channel', 'hello');

      // Wait for the message
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await subscription.cancel();

      // Should have received subscribe confirmation and message
      expect(messages.length, greaterThanOrEqualTo(1));
    });

    test('can subscribe to patterns', () async {
      final messages = <RedisPubSubMessage>[];
      final subscription = subscriber.messages.listen(messages.add);

      await subscriber.psubscribe(['test:*']);

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
      await subscriber.subscribe(['close-test']);
      await subscriber.close();

      expect(() => subscriber.command(['PING']), throwsStateError);
    });
  }, tags: ['redis']);
}
