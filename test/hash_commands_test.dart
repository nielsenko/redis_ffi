@Tags(['redis'])
library;

import 'package:redis_ffi/redis_ffi.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group('hash commands', () {
    late RedisClient client;

    setUp(() async {
      client = await createTestClient();
    });

    tearDown(() async {
      await client.close();
    });

    test('hset and hget', () async {
      expect(await client.hset('hash1', 'field1', 'value1'), equals(1));
      expect(await client.hget('hash1', 'field1'), equals('value1'));
      expect(await client.hget('hash1', 'nonexistent'), isNull);

      // hset returns 0 when updating existing field
      expect(await client.hset('hash1', 'field1', 'updated'), equals(0));
      expect(await client.hget('hash1', 'field1'), equals('updated'));

      await client.del(['hash1']);
    });

    test('hsetAll and hgetall', () async {
      await client.hsetAll('hash2', {'f1': 'v1', 'f2': 'v2', 'f3': 'v3'});

      final all = await client.hgetall('hash2');
      expect(all, equals({'f1': 'v1', 'f2': 'v2', 'f3': 'v3'}));

      await client.del(['hash2']);
    });

    test('hmget', () async {
      await client.hsetAll('hash3', {'a': '1', 'b': '2', 'c': '3'});

      final values = await client.hmget('hash3', ['a', 'c', 'nonexistent']);
      expect(values, equals(['1', '3', null]));

      await client.del(['hash3']);
    });

    test('hdel', () async {
      await client.hsetAll('hash4', {'a': '1', 'b': '2', 'c': '3'});

      expect(await client.hdel('hash4', ['a', 'nonexistent']), equals(1));
      expect(await client.hexists('hash4', 'a'), isFalse);
      expect(await client.hexists('hash4', 'b'), isTrue);

      await client.del(['hash4']);
    });

    test('hkeys and hvals', () async {
      await client.hsetAll('hash5', {'x': '1', 'y': '2', 'z': '3'});

      final keys = await client.hkeys('hash5');
      expect(keys.toSet(), equals({'x', 'y', 'z'}));

      final vals = await client.hvals('hash5');
      expect(vals.toSet(), equals({'1', '2', '3'}));

      await client.del(['hash5']);
    });

    test('hlen', () async {
      await client.hsetAll('hash6', {'a': '1', 'b': '2'});
      expect(await client.hlen('hash6'), equals(2));
      expect(await client.hlen('nonexistent_hash'), equals(0));

      await client.del(['hash6']);
    });

    test('hincrby and hincrbyfloat', () async {
      await client.hset('hash7', 'counter', '10');

      expect(await client.hincrby('hash7', 'counter', 5), equals(15));
      expect(await client.hincrby('hash7', 'counter', -3), equals(12));

      await client.hset('hash7', 'float', '1.5');
      final result = await client.hincrbyfloat('hash7', 'float', 0.25);
      expect(result, closeTo(1.75, 0.001));

      await client.del(['hash7']);
    });

    test('hsetnx', () async {
      expect(await client.hsetnx('hash8', 'field', 'value'), isTrue);
      expect(await client.hsetnx('hash8', 'field', 'other'), isFalse);
      expect(await client.hget('hash8', 'field'), equals('value'));

      await client.del(['hash8']);
    });

    test('hstrlen', () async {
      await client.hset('hash9', 'field', 'hello');
      expect(await client.hstrlen('hash9', 'field'), equals(5));
      expect(await client.hstrlen('hash9', 'nonexistent'), equals(0));

      await client.del(['hash9']);
    });

    test('hrandfield', () async {
      await client.hsetAll('hash10', {'a': '1', 'b': '2', 'c': '3'});

      final single = await client.hrandfield('hash10');
      expect(single.length, equals(1));
      expect(['a', 'b', 'c'], contains(single.first));

      final multiple = await client.hrandfield('hash10', count: 2);
      expect(multiple.length, equals(2));

      await client.del(['hash10']);
    });

    test('hscan', () async {
      final fields = <String, String>{};
      for (var i = 0; i < 10; i++) {
        fields['field$i'] = 'value$i';
      }
      await client.hsetAll('hash11', fields);

      final allFields = <String, String>{};
      var cursor = '0';
      do {
        final (nextCursor, scanned) = await client.hscan('hash11', cursor);
        cursor = nextCursor;
        allFields.addAll(scanned);
      } while (cursor != '0');

      expect(allFields.length, equals(10));

      await client.del(['hash11']);
    });
  });
}
