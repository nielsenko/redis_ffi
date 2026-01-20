import 'package:redis_ffi/redis_ffi.dart';
import 'package:test/test.dart';

void main() {
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

    setUp(() {
      try {
        client = RedisClient.connect('localhost', 6379);
      } on RedisException {
        // Skip tests if Redis is not available
        markTestSkipped('Redis server not available');
      }
    });

    tearDown(() {
      try {
        client.close();
      } catch (_) {
        // Ignore errors during cleanup
      }
    });

    test('ping returns PONG', () {
      expect(client.ping(), equals('PONG'));
    });

    test('ping with message returns message', () {
      expect(client.ping('hello'), equals('hello'));
    });

    test('set and get work correctly', () {
      client.set('test_key', 'test_value');
      expect(client.get('test_key'), equals('test_value'));

      // Cleanup
      client.del(['test_key']);
    });

    test('get returns null for non-existent key', () {
      expect(client.get('non_existent_key_12345'), isNull);
    });

    test('exists returns correct value', () {
      client.set('exists_test', 'value');
      expect(client.exists('exists_test'), isTrue);
      expect(client.exists('non_existent_key_12345'), isFalse);

      // Cleanup
      client.del(['exists_test']);
    });

    test('del deletes keys', () {
      client.set('del_test1', 'value1');
      client.set('del_test2', 'value2');

      final deleted = client.del(['del_test1', 'del_test2']);
      expect(deleted, equals(2));
      expect(client.exists('del_test1'), isFalse);
      expect(client.exists('del_test2'), isFalse);
    });

    test('commandArgv works with array reply', () {
      client.set('array_test1', 'value1');
      client.set('array_test2', 'value2');

      final reply = client.commandArgv(['MGET', 'array_test1', 'array_test2']);
      expect(reply.type, equals(RedisReplyType.array));
      expect(reply.length, equals(2));
      expect(reply[0]?.string, equals('value1'));
      expect(reply[1]?.string, equals('value2'));
      reply.free();

      // Cleanup
      client.del(['array_test1', 'array_test2']);
    });
  }, skip: 'Requires running Redis server');
}
