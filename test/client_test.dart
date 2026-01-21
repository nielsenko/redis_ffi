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

    test('concurrent commands are automatically pipelined', () async {
      // Clean up first
      await client.del(['pipe1', 'pipe2']);

      // Commands issued concurrently are batched together via microtask flush
      await Future.wait([
        client.set('pipe1', 'value1'),
        client.set('pipe2', 'value2'),
      ]);

      // Verify values were set
      final results = await Future.wait([
        client.get('pipe1'),
        client.get('pipe2'),
      ]);

      expect(results[0], equals('value1'));
      expect(results[1], equals('value2'));

      await client.del(['pipe1', 'pipe2']);
    });

    test('sequential commands work correctly', () async {
      await client.set('seq_key', 'value1');
      expect(await client.get('seq_key'), equals('value1'));

      await client.set('seq_key', 'value2');
      expect(await client.get('seq_key'), equals('value2'));

      await client.del(['seq_key']);
    });
  });
}
