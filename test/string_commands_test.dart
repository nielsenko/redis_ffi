@Tags(['redis'])
library;

import 'package:redis_ffi/redis_ffi.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group('string commands', () {
    late RedisClient client;

    setUp(() async {
      client = await createTestClient();
    });

    tearDown(() async {
      await client.close();
    });

    test('set and get work correctly', () async {
      await client.set('test_key', 'test_value');
      expect(await client.get('test_key'), equals('test_value'));
      await client.del(['test_key']);
    });

    test('get returns null for non-existent key', () async {
      expect(await client.get('non_existent_key_12345'), isNull);
    });

    test('set with expiry', () async {
      await client.set('expiry_test', 'value', ex: 10);
      expect(await client.get('expiry_test'), equals('value'));

      final ttl = await client.ttl('expiry_test');
      expect(ttl, greaterThan(0));

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
      final result1 = await client.msetnx({'msetnx1': 'new', 'msetnx2': 'new'});
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

      final ttl = await client.ttl('setex_test');
      expect(ttl, greaterThan(0));

      await client.del(['setex_test']);
    });

    test('getex with expiry', () async {
      await client.set('getex_test', 'value');

      // Get and set expiry
      final value = await client.getex('getex_test', ex: 10);
      expect(value, equals('value'));

      final ttl = await client.ttl('getex_test');
      expect(ttl, greaterThan(0));

      await client.del(['getex_test']);
    });
  });
}
