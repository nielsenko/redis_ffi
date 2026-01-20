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

    // String commands
    group('string commands', () {
      test('set with expiry', () async {
        await client.set('expiry_test', 'value', ex: 10);
        expect(await client.get('expiry_test'), equals('value'));

        // Verify TTL was set
        final reply = await client.command(['TTL', 'expiry_test']);
        expect(reply?.integer, greaterThan(0));
        reply?.free();

        await client.del(['expiry_test']);
      });

      test('set with nx option', () async {
        await client.set('nx_test', 'first');

        // Should not overwrite with NX
        await client.set('nx_test', 'second', nx: true);
        expect(await client.get('nx_test'), equals('first'));

        await client.del(['nx_test']);

        // Should set with NX when key doesn't exist
        await client.set('nx_test2', 'value', nx: true);
        expect(await client.get('nx_test2'), equals('value'));

        await client.del(['nx_test2']);
      });

      test('set with get option returns old value', () async {
        await client.set('get_test', 'old');
        final oldValue = await client.set('get_test', 'new', get: true);
        expect(oldValue, equals('old'));
        expect(await client.get('get_test'), equals('new'));

        await client.del(['get_test']);
      });

      test('mget returns multiple values', () async {
        await client.set('mget1', 'value1');
        await client.set('mget2', 'value2');

        final values = await client.mget(['mget1', 'mget2', 'nonexistent']);
        expect(values, equals(['value1', 'value2', null]));

        await client.del(['mget1', 'mget2']);
      });

      test('mset sets multiple values', () async {
        await client.mset({'mset1': 'v1', 'mset2': 'v2', 'mset3': 'v3'});

        expect(await client.get('mset1'), equals('v1'));
        expect(await client.get('mset2'), equals('v2'));
        expect(await client.get('mset3'), equals('v3'));

        await client.del(['mset1', 'mset2', 'mset3']);
      });

      test('msetnx only sets if none exist', () async {
        await client.set('msetnx1', 'existing');

        // Should fail because msetnx1 exists
        final result1 = await client.msetnx({
          'msetnx1': 'new',
          'msetnx2': 'new',
        });
        expect(result1, isFalse);
        expect(await client.get('msetnx1'), equals('existing'));
        expect(await client.get('msetnx2'), isNull);

        // Should succeed when none exist
        final result2 = await client.msetnx({'msetnx3': 'v3', 'msetnx4': 'v4'});
        expect(result2, isTrue);
        expect(await client.get('msetnx3'), equals('v3'));

        await client.del(['msetnx1', 'msetnx3', 'msetnx4']);
      });

      test('incr and decr', () async {
        await client.set('counter', '10');

        expect(await client.incr('counter'), equals(11));
        expect(await client.incrby('counter', 5), equals(16));
        expect(await client.decr('counter'), equals(15));
        expect(await client.decrby('counter', 3), equals(12));

        await client.del(['counter']);
      });

      test('incrbyfloat', () async {
        await client.set('float_counter', '10.5');

        final result = await client.incrbyfloat('float_counter', 0.1);
        expect(result, closeTo(10.6, 0.001));

        await client.del(['float_counter']);
      });

      test('append and strlen', () async {
        await client.set('append_test', 'Hello');
        final len = await client.append('append_test', ' World');
        expect(len, equals(11));
        expect(await client.get('append_test'), equals('Hello World'));
        expect(await client.strlen('append_test'), equals(11));

        await client.del(['append_test']);
      });

      test('getrange and setrange', () async {
        await client.set('range_test', 'Hello World');

        expect(await client.getrange('range_test', 0, 4), equals('Hello'));

        await client.setrange('range_test', 6, 'Redis');
        expect(await client.get('range_test'), equals('Hello Redis'));

        await client.del(['range_test']);
      });

      test('setbit and getbit', () async {
        await client.setbit('bit_test', 7, 1);
        expect(await client.getbit('bit_test', 7), equals(1));
        expect(await client.getbit('bit_test', 0), equals(0));

        await client.del(['bit_test']);
      });

      test('setnx', () async {
        expect(await client.setnx('setnx_test', 'value'), isTrue);
        expect(await client.setnx('setnx_test', 'other'), isFalse);
        expect(await client.get('setnx_test'), equals('value'));

        await client.del(['setnx_test']);
      });

      test('getset', () async {
        await client.set('getset_test', 'old');
        final old = await client.getset('getset_test', 'new');
        expect(old, equals('old'));
        expect(await client.get('getset_test'), equals('new'));

        await client.del(['getset_test']);
      });

      test('getdel', () async {
        await client.set('getdel_test', 'value');
        final value = await client.getdel('getdel_test');
        expect(value, equals('value'));
        expect(await client.exists('getdel_test'), isFalse);
      });

      test('setex and psetex', () async {
        await client.setex('setex_test', 10, 'value');
        expect(await client.get('setex_test'), equals('value'));

        final reply = await client.command(['TTL', 'setex_test']);
        expect(reply?.integer, greaterThan(0));
        reply?.free();

        await client.del(['setex_test']);
      });

      test('getex with expiry', () async {
        await client.set('getex_test', 'value');

        // Get and set expiry
        final value = await client.getex('getex_test', ex: 10);
        expect(value, equals('value'));

        final reply = await client.command(['TTL', 'getex_test']);
        expect(reply?.integer, greaterThan(0));
        reply?.free();

        await client.del(['getex_test']);
      });
    });

    // Key commands
    group('key commands', () {
      test('unlink deletes keys asynchronously', () async {
        await client.set('unlink1', 'value1');
        await client.set('unlink2', 'value2');

        final count = await client.unlink(['unlink1', 'unlink2']);
        expect(count, equals(2));
        expect(await client.exists('unlink1'), isFalse);
      });

      test('existsCount returns count of existing keys', () async {
        await client.set('exists1', 'value1');
        await client.set('exists2', 'value2');

        expect(
          await client.existsCount(['exists1', 'exists2', 'nonexistent']),
          equals(2),
        );

        await client.del(['exists1', 'exists2']);
      });

      test('expire and ttl', () async {
        await client.set('expire_test', 'value');

        expect(await client.expire('expire_test', 100), isTrue);
        final ttl = await client.ttl('expire_test');
        expect(ttl, greaterThan(0));
        expect(ttl, lessThanOrEqualTo(100));

        await client.del(['expire_test']);
      });

      test('pexpire and pttl', () async {
        await client.set('pexpire_test', 'value');

        expect(await client.pexpire('pexpire_test', 100000), isTrue);
        final pttl = await client.pttl('pexpire_test');
        expect(pttl, greaterThan(0));

        await client.del(['pexpire_test']);
      });

      test('persist removes expiry', () async {
        await client.set('persist_test', 'value');
        await client.expire('persist_test', 100);

        expect(await client.persist('persist_test'), isTrue);
        expect(await client.ttl('persist_test'), equals(-1));

        await client.del(['persist_test']);
      });

      test('ttl returns -2 for non-existent key', () async {
        expect(await client.ttl('nonexistent_key_12345'), equals(-2));
      });

      test('ttl returns -1 for key without expiry', () async {
        await client.set('no_expiry', 'value');
        expect(await client.ttl('no_expiry'), equals(-1));
        await client.del(['no_expiry']);
      });

      test('type returns correct type', () async {
        await client.set('type_string', 'value');
        expect(await client.type('type_string'), equals('string'));
        expect(await client.type('nonexistent'), equals('none'));

        await client.del(['type_string']);
      });

      test('rename renames a key', () async {
        await client.set('rename_old', 'value');
        await client.rename('rename_old', 'rename_new');

        expect(await client.exists('rename_old'), isFalse);
        expect(await client.get('rename_new'), equals('value'));

        await client.del(['rename_new']);
      });

      test('renamenx only renames if new key does not exist', () async {
        await client.set('renamenx_old', 'value');
        await client.set('renamenx_existing', 'other');

        expect(
          await client.renamenx('renamenx_old', 'renamenx_existing'),
          isFalse,
        );
        expect(await client.renamenx('renamenx_old', 'renamenx_new'), isTrue);

        await client.del(['renamenx_existing', 'renamenx_new']);
      });

      test('keys returns matching keys', () async {
        await client.set('keys_test_1', 'v1');
        await client.set('keys_test_2', 'v2');
        await client.set('other_key', 'v3');

        final keys = await client.keys('keys_test_*');
        expect(keys, containsAll(['keys_test_1', 'keys_test_2']));
        expect(keys, isNot(contains('other_key')));

        await client.del(['keys_test_1', 'keys_test_2', 'other_key']);
      });

      test('scan iterates over keys', () async {
        // Create some keys
        for (var i = 0; i < 5; i++) {
          await client.set('scan_test_$i', 'value');
        }

        // Scan all keys matching pattern
        final allKeys = <String>[];
        var cursor = '0';
        do {
          final (nextCursor, keys) = await client.scan(
            cursor,
            match: 'scan_test_*',
          );
          cursor = nextCursor;
          allKeys.addAll(keys);
        } while (cursor != '0');

        expect(allKeys.length, equals(5));

        // Cleanup
        await client.del(allKeys);
      });

      test('touch updates last access time', () async {
        await client.set('touch1', 'value1');
        await client.set('touch2', 'value2');

        final count = await client.touch(['touch1', 'touch2', 'nonexistent']);
        expect(count, equals(2));

        await client.del(['touch1', 'touch2']);
      });

      test('copy copies a key', () async {
        await client.set('copy_src', 'value');

        expect(await client.copy('copy_src', 'copy_dst'), isTrue);
        expect(await client.get('copy_dst'), equals('value'));

        // Should fail without replace
        expect(await client.copy('copy_src', 'copy_dst'), isFalse);

        // Should succeed with replace
        await client.set('copy_src', 'new_value');
        expect(
          await client.copy('copy_src', 'copy_dst', replace: true),
          isTrue,
        );
        expect(await client.get('copy_dst'), equals('new_value'));

        await client.del(['copy_src', 'copy_dst']);
      });

      test('objectEncoding returns encoding', () async {
        await client.set('encoding_test', 'value');
        final encoding = await client.objectEncoding('encoding_test');
        expect(encoding, isNotNull);

        await client.del(['encoding_test']);
      });
    });

    group('hash commands', () {
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

        // Scan all fields
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

    group('list commands', () {
      test('lpush and rpush', () async {
        expect(await client.lpush('list1', ['a', 'b']), equals(2));
        expect(await client.rpush('list1', ['c', 'd']), equals(4));

        // List should be: b, a, c, d
        expect(
          await client.lrange('list1', 0, -1),
          equals(['b', 'a', 'c', 'd']),
        );

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

        expect(
          await client.linsert('list9', 'c', 'b', before: true),
          equals(3),
        );
        expect(
          await client.linsert('list9', 'c', 'd', before: false),
          equals(4),
        );

        expect(
          await client.lrange('list9', 0, -1),
          equals(['a', 'b', 'c', 'd']),
        );

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

      expect(() => subscriber.command(['PING']), throwsStateError);
    });
  }, tags: ['redis']);
}
