@Tags(['redis'])
library;

import 'package:redis_ffi/redis_ffi.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group('sorted set commands', () {
    late RedisClient client;

    setUp(() async {
      client = await createTestClient();
    });

    tearDown(() async {
      await client.close();
    });

    test('zadd and zscore', () async {
      expect(
        await client.zadd('zset1', {'a': 1.0, 'b': 2.0, 'c': 3.0}),
        equals(3),
      );

      expect(await client.zscore('zset1', 'b'), equals(2.0));
      expect(await client.zscore('zset1', 'nonexistent'), isNull);

      // Update score
      expect(await client.zadd('zset1', {'b': 5.0}), equals(0));
      expect(await client.zscore('zset1', 'b'), equals(5.0));

      await client.del(['zset1']);
    });

    test('zadd with options', () async {
      await client.zadd('zset2', {'a': 1.0});

      // NX: only add, don't update
      expect(
        await client.zadd('zset2', {'a': 2.0, 'b': 3.0}, nx: true),
        equals(1),
      );
      expect(await client.zscore('zset2', 'a'), equals(1.0)); // unchanged

      // XX: only update, don't add
      expect(
        await client.zadd('zset2', {'a': 5.0, 'c': 6.0}, xx: true),
        equals(0),
      );
      expect(await client.zscore('zset2', 'a'), equals(5.0));
      expect(await client.zscore('zset2', 'c'), isNull);

      // CH: count changed elements
      expect(await client.zadd('zset2', {'a': 10.0}, ch: true), equals(1));

      await client.del(['zset2']);
    });

    test('zrem', () async {
      await client.zadd('zset3', {'a': 1.0, 'b': 2.0, 'c': 3.0});

      expect(await client.zrem('zset3', ['a', 'nonexistent']), equals(1));
      expect(await client.zscore('zset3', 'a'), isNull);

      await client.del(['zset3']);
    });

    test('zmscore', () async {
      await client.zadd('zset4', {'a': 1.0, 'b': 2.0});

      final scores = await client.zmscore('zset4', ['a', 'nonexistent', 'b']);
      expect(scores, equals([1.0, null, 2.0]));

      await client.del(['zset4']);
    });

    test('zrank and zrevrank', () async {
      await client.zadd('zset5', {'a': 1.0, 'b': 2.0, 'c': 3.0});

      expect(await client.zrank('zset5', 'a'), equals(0));
      expect(await client.zrank('zset5', 'c'), equals(2));
      expect(await client.zrank('zset5', 'nonexistent'), isNull);

      expect(await client.zrevrank('zset5', 'a'), equals(2));
      expect(await client.zrevrank('zset5', 'c'), equals(0));

      await client.del(['zset5']);
    });

    test('zcard and zcount', () async {
      await client.zadd('zset6', {'a': 1.0, 'b': 2.0, 'c': 3.0, 'd': 4.0});

      expect(await client.zcard('zset6'), equals(4));
      expect(await client.zcount('zset6', '2', '3'), equals(2));
      expect(await client.zcount('zset6', '-inf', '+inf'), equals(4));

      await client.del(['zset6']);
    });

    test('zrange', () async {
      await client.zadd('zset7', {'a': 1.0, 'b': 2.0, 'c': 3.0});

      expect(await client.zrange('zset7', 0, -1), equals(['a', 'b', 'c']));
      expect(await client.zrange('zset7', 0, 1), equals(['a', 'b']));

      await client.del(['zset7']);
    });

    test('zrangeWithScores', () async {
      await client.zadd('zset8', {'a': 1.0, 'b': 2.0, 'c': 3.0});

      final result = await client.zrangeWithScores('zset8', 0, -1);
      expect(result, equals([('a', 1.0), ('b', 2.0), ('c', 3.0)]));

      await client.del(['zset8']);
    });

    test('zrangebyscore and zrevrangebyscore', () async {
      await client.zadd('zset9', {'a': 1.0, 'b': 2.0, 'c': 3.0, 'd': 4.0});

      expect(await client.zrangebyscore('zset9', '2', '3'), equals(['b', 'c']));
      expect(
        await client.zrevrangebyscore('zset9', '3', '2'),
        equals(['c', 'b']),
      );

      // With LIMIT
      expect(
        await client.zrangebyscore(
          'zset9',
          '-inf',
          '+inf',
          offset: 1,
          count: 2,
        ),
        equals(['b', 'c']),
      );

      await client.del(['zset9']);
    });

    test('zincrby', () async {
      await client.zadd('zset10', {'a': 1.0});

      expect(await client.zincrby('zset10', 2.5, 'a'), equals(3.5));
      expect(await client.zscore('zset10', 'a'), equals(3.5));

      await client.del(['zset10']);
    });

    test('zremrangebyscore', () async {
      await client.zadd('zset11', {'a': 1.0, 'b': 2.0, 'c': 3.0, 'd': 4.0});

      expect(await client.zremrangebyscore('zset11', '2', '3'), equals(2));
      expect(await client.zrange('zset11', 0, -1), equals(['a', 'd']));

      await client.del(['zset11']);
    });

    test('zremrangebyrank', () async {
      await client.zadd('zset12', {'a': 1.0, 'b': 2.0, 'c': 3.0, 'd': 4.0});

      expect(await client.zremrangebyrank('zset12', 1, 2), equals(2));
      expect(await client.zrange('zset12', 0, -1), equals(['a', 'd']));

      await client.del(['zset12']);
    });

    test('zpopmin and zpopmax', () async {
      await client.zadd('zset13', {'a': 1.0, 'b': 2.0, 'c': 3.0});

      expect(await client.zpopmin('zset13'), equals([('a', 1.0)]));
      expect(await client.zpopmax('zset13'), equals([('c', 3.0)]));

      await client.del(['zset13']);
    });

    test('zunionstore', () async {
      await client.zadd('zset14a', {'a': 1.0, 'b': 2.0});
      await client.zadd('zset14b', {'b': 3.0, 'c': 4.0});

      expect(
        await client.zunionstore('zset14result', ['zset14a', 'zset14b']),
        equals(3),
      );

      // b should have combined score (2 + 3 = 5)
      expect(await client.zscore('zset14result', 'b'), equals(5.0));

      await client.del(['zset14a', 'zset14b', 'zset14result']);
    });

    test('zinterstore', () async {
      await client.zadd('zset15a', {'a': 1.0, 'b': 2.0});
      await client.zadd('zset15b', {'b': 3.0, 'c': 4.0});

      expect(
        await client.zinterstore('zset15result', ['zset15a', 'zset15b']),
        equals(1),
      );

      expect(await client.zscore('zset15result', 'b'), equals(5.0));

      await client.del(['zset15a', 'zset15b', 'zset15result']);
    });

    test('zscan', () async {
      for (var i = 0; i < 10; i++) {
        await client.zadd('zset16', {'member$i': i.toDouble()});
      }

      final allMembers = <(String, double)>[];
      var cursor = '0';
      do {
        final (nextCursor, members) = await client.zscan('zset16', cursor);
        cursor = nextCursor;
        allMembers.addAll(members);
      } while (cursor != '0');

      expect(allMembers.length, equals(10));

      await client.del(['zset16']);
    });
  });
}
