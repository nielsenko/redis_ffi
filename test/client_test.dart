@Tags(['redis'])
library;

import 'package:redis_ffi/redis_ffi.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group('RedisClient', () {
    late RedisClient client;

    setUp(() async {
      client = await createTestClient();
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

      await client.del(['pipe1', 'pipe2']);
    });
  });
}
