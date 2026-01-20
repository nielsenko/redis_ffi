@Tags(['redis'])
library;

import 'package:redis_ffi/redis_ffi.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  group('key commands', () {
    late RedisClient client;

    setUp(() async {
      client = await createTestClient();
    });

    tearDown(() async {
      await client.close();
    });

    test('exists returns correct value', () async {
      await client.set('exists_test', 'value');
      expect(await client.exists('exists_test'), isTrue);
      expect(await client.exists('non_existent_key_12345'), isFalse);

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
      for (var i = 0; i < 5; i++) {
        await client.set('scan_test_$i', 'value');
      }

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
      expect(await client.copy('copy_src', 'copy_dst', replace: true), isTrue);
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
}
