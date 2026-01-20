@Tags(['redis'])
library;

import 'package:redis_ffi/redis_ffi.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group('set commands', () {
    late RedisClient client;

    setUp(() async {
      client = await createTestClient();
    });

    tearDown(() async {
      await client.close();
    });

    test('sadd and smembers', () async {
      expect(await client.sadd('set1', ['a', 'b', 'c']), equals(3));
      expect(
        await client.sadd('set1', ['b', 'd']),
        equals(1),
      ); // b already exists

      final members = await client.smembers('set1');
      expect(members, equals({'a', 'b', 'c', 'd'}));

      await client.del(['set1']);
    });

    test('srem', () async {
      await client.sadd('set2', ['a', 'b', 'c']);

      expect(await client.srem('set2', ['a', 'nonexistent']), equals(1));
      expect(await client.smembers('set2'), equals({'b', 'c'}));

      await client.del(['set2']);
    });

    test('sismember and smismember', () async {
      await client.sadd('set3', ['a', 'b', 'c']);

      expect(await client.sismember('set3', 'a'), isTrue);
      expect(await client.sismember('set3', 'x'), isFalse);

      expect(
        await client.smismember('set3', ['a', 'x', 'b']),
        equals([true, false, true]),
      );

      await client.del(['set3']);
    });

    test('scard', () async {
      await client.sadd('set4', ['a', 'b', 'c']);
      expect(await client.scard('set4'), equals(3));
      expect(await client.scard('nonexistent_set'), equals(0));

      await client.del(['set4']);
    });

    test('spop', () async {
      await client.sadd('set5', ['a', 'b', 'c']);

      final popped = await client.spop('set5');
      expect(['a', 'b', 'c'], contains(popped));
      expect(await client.scard('set5'), equals(2));

      final poppedMultiple = await client.spopCount('set5', 2);
      expect(poppedMultiple.length, equals(2));
      expect(await client.scard('set5'), equals(0));

      await client.del(['set5']);
    });

    test('srandmember', () async {
      await client.sadd('set6', ['a', 'b', 'c']);

      final single = await client.srandmember('set6');
      expect(['a', 'b', 'c'], contains(single));

      final multiple = await client.srandmemberCount('set6', 2);
      expect(multiple.length, equals(2));

      // scard should be unchanged (srandmember doesn't remove)
      expect(await client.scard('set6'), equals(3));

      await client.del(['set6']);
    });

    test('smove', () async {
      await client.sadd('set7a', ['a', 'b']);
      await client.sadd('set7b', ['c']);

      expect(await client.smove('set7a', 'set7b', 'a'), isTrue);
      expect(await client.smembers('set7a'), equals({'b'}));
      expect(await client.smembers('set7b'), equals({'a', 'c'}));

      expect(await client.smove('set7a', 'set7b', 'nonexistent'), isFalse);

      await client.del(['set7a', 'set7b']);
    });

    test('sdiff and sdiffstore', () async {
      await client.sadd('set8a', ['a', 'b', 'c']);
      await client.sadd('set8b', ['b', 'c', 'd']);

      expect(await client.sdiff(['set8a', 'set8b']), equals({'a'}));

      expect(
        await client.sdiffstore('set8result', ['set8a', 'set8b']),
        equals(1),
      );
      expect(await client.smembers('set8result'), equals({'a'}));

      await client.del(['set8a', 'set8b', 'set8result']);
    });

    test('sinter and sinterstore', () async {
      await client.sadd('set9a', ['a', 'b', 'c']);
      await client.sadd('set9b', ['b', 'c', 'd']);

      expect(await client.sinter(['set9a', 'set9b']), equals({'b', 'c'}));

      expect(
        await client.sinterstore('set9result', ['set9a', 'set9b']),
        equals(2),
      );

      await client.del(['set9a', 'set9b', 'set9result']);
    });

    test('sintercard', () async {
      await client.sadd('set10a', ['a', 'b', 'c', 'd']);
      await client.sadd('set10b', ['b', 'c', 'd', 'e']);

      expect(await client.sintercard(['set10a', 'set10b']), equals(3));
      expect(
        await client.sintercard(['set10a', 'set10b'], limit: 2),
        equals(2),
      );

      await client.del(['set10a', 'set10b']);
    });

    test('sunion and sunionstore', () async {
      await client.sadd('set11a', ['a', 'b']);
      await client.sadd('set11b', ['b', 'c']);

      expect(
        await client.sunion(['set11a', 'set11b']),
        equals({'a', 'b', 'c'}),
      );

      expect(
        await client.sunionstore('set11result', ['set11a', 'set11b']),
        equals(3),
      );

      await client.del(['set11a', 'set11b', 'set11result']);
    });

    test('sscan', () async {
      for (var i = 0; i < 10; i++) {
        await client.sadd('set12', ['member$i']);
      }

      final allMembers = <String>{};
      var cursor = '0';
      do {
        final (nextCursor, members) = await client.sscan('set12', cursor);
        cursor = nextCursor;
        allMembers.addAll(members);
      } while (cursor != '0');

      expect(allMembers.length, equals(10));

      await client.del(['set12']);
    });
  });
}
