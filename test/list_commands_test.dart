@Tags(['redis'])
library;

import 'package:redis_ffi/redis_ffi.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group('list commands', () {
    late RedisClient client;

    setUp(() async {
      client = await createTestClient();
    });

    tearDown(() async {
      await client.close();
    });

    test('lpush and rpush', () async {
      expect(await client.lpush('list1', ['a', 'b']), equals(2));
      expect(await client.rpush('list1', ['c', 'd']), equals(4));

      // List should be: b, a, c, d
      expect(await client.lrange('list1', 0, -1), equals(['b', 'a', 'c', 'd']));

      await client.del(['list1']);
    });

    test('lpushx and rpushx', () async {
      // Should return 0 for non-existent list
      expect(await client.lpushx('list2', ['a']), equals(0));
      expect(await client.rpushx('list2', ['b']), equals(0));

      // Create the list first
      await client.lpush('list2', ['x']);
      expect(await client.lpushx('list2', ['a']), equals(2));
      expect(await client.rpushx('list2', ['b']), equals(3));

      await client.del(['list2']);
    });

    test('lpop and rpop', () async {
      await client.rpush('list3', ['a', 'b', 'c']);

      expect(await client.lpop('list3'), equals('a'));
      expect(await client.rpop('list3'), equals('c'));
      expect(await client.lpop('list3'), equals('b'));
      expect(await client.lpop('list3'), isNull);

      await client.del(['list3']);
    });

    test('lpopCount and rpopCount', () async {
      await client.del(['list4']);
      await client.rpush('list4', ['a', 'b', 'c', 'd', 'e']);

      expect(await client.lpopCount('list4', 2), equals(['a', 'b']));
      expect(await client.rpopCount('list4', 2), equals(['e', 'd']));

      await client.del(['list4']);
    });

    test('lrange', () async {
      await client.rpush('list5', ['a', 'b', 'c', 'd', 'e']);

      expect(await client.lrange('list5', 0, 2), equals(['a', 'b', 'c']));
      expect(await client.lrange('list5', -2, -1), equals(['d', 'e']));
      expect(
        await client.lrange('list5', 0, -1),
        equals(['a', 'b', 'c', 'd', 'e']),
      );

      await client.del(['list5']);
    });

    test('lindex', () async {
      await client.rpush('list6', ['a', 'b', 'c']);

      expect(await client.lindex('list6', 0), equals('a'));
      expect(await client.lindex('list6', -1), equals('c'));
      expect(await client.lindex('list6', 10), isNull);

      await client.del(['list6']);
    });

    test('lset', () async {
      await client.rpush('list7', ['a', 'b', 'c']);

      await client.lset('list7', 1, 'B');
      expect(await client.lindex('list7', 1), equals('B'));

      await client.del(['list7']);
    });

    test('llen', () async {
      await client.rpush('list8', ['a', 'b', 'c']);
      expect(await client.llen('list8'), equals(3));
      expect(await client.llen('nonexistent_list'), equals(0));

      await client.del(['list8']);
    });

    test('linsert', () async {
      await client.rpush('list9', ['a', 'c']);

      expect(await client.linsert('list9', 'c', 'b', before: true), equals(3));
      expect(await client.linsert('list9', 'c', 'd', before: false), equals(4));

      expect(await client.lrange('list9', 0, -1), equals(['a', 'b', 'c', 'd']));

      // Returns -1 when pivot not found
      expect(
        await client.linsert('list9', 'nonexistent', 'x', before: true),
        equals(-1),
      );

      await client.del(['list9']);
    });

    test('lrem', () async {
      await client.rpush('list10', ['a', 'b', 'a', 'c', 'a']);

      expect(await client.lrem('list10', 2, 'a'), equals(2));
      expect(await client.lrange('list10', 0, -1), equals(['b', 'c', 'a']));

      await client.del(['list10']);
    });

    test('ltrim', () async {
      await client.rpush('list11', ['a', 'b', 'c', 'd', 'e']);

      await client.ltrim('list11', 1, 3);
      expect(await client.lrange('list11', 0, -1), equals(['b', 'c', 'd']));

      await client.del(['list11']);
    });

    test('lmove', () async {
      await client.rpush('src_list', ['a', 'b', 'c']);

      final moved = await client.lmove(
        'src_list',
        'dst_list',
        srcDirection: 'RIGHT',
        dstDirection: 'LEFT',
      );

      expect(moved, equals('c'));
      expect(await client.lrange('src_list', 0, -1), equals(['a', 'b']));
      expect(await client.lrange('dst_list', 0, -1), equals(['c']));

      await client.del(['src_list', 'dst_list']);
    });

    test('lpos', () async {
      await client.rpush('list12', ['a', 'b', 'c', 'b', 'd']);

      expect(await client.lpos('list12', 'b'), equals(1));
      expect(await client.lpos('list12', 'nonexistent'), isNull);

      await client.del(['list12']);
    });
  });
}
