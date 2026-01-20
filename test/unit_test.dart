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
}
