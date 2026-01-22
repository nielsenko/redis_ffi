import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'event_loop_bindings.dart';
import 'hiredis_bindings.g.dart';

bool _dartApiInitialized = false;

void _ensureDartApiInitialized() {
  if (!_dartApiInitialized) {
    if (!initializeDartApi()) {
      throw StateError('Failed to initialize Dart API');
    }
    _dartApiInitialized = true;
  }
}

const _redisReplyString = 1;
const _redisReplyArray = 2;
const _redisReplyInteger = 3;
const _redisReplyNil = 4;
const _redisReplyStatus = 5;
const _redisReplyError = 6;
const _redisReplyDouble = 7;
const _redisReplyBool = 8;
const _redisReplyMap = 9;
const _redisReplySet = 10;
const _redisReplyPush = 12;

/// A parsed Redis reply (data copied from native, no manual free needed).
class _ParsedReply {
  final int type;
  final String? string;
  final int? integer;
  final List<_ParsedReply?>? elements;

  _ParsedReply._({
    required this.type,
    this.string,
    this.integer,
    this.elements,
  });

  bool get isNil => type == _redisReplyNil;
  bool get isError => type == _redisReplyError;
  int get length => elements?.length ?? 0;
  _ParsedReply? operator [](int index) => elements?[index];

  static _ParsedReply? fromNative(dynamic data) {
    if (data == null) return _ParsedReply._(type: _redisReplyNil);
    if (data is! List || data.isEmpty) {
      return _ParsedReply._(type: _redisReplyNil);
    }

    final type = data[0] as int;
    switch (type) {
      case _redisReplyNil:
        return _ParsedReply._(type: type);
      case _redisReplyString:
      case _redisReplyStatus:
      case _redisReplyError:
      case _redisReplyDouble:
        if (data.length < 2) return _ParsedReply._(type: _redisReplyNil);
        final bytes = data[1] as Uint8List;
        final str = utf8.decode(bytes, allowMalformed: true);
        return _ParsedReply._(type: type, string: str);
      case _redisReplyInteger:
        if (data.length < 2) return _ParsedReply._(type: _redisReplyNil);
        return _ParsedReply._(type: type, integer: data[1] as int);
      case _redisReplyBool:
        if (data.length < 2) return _ParsedReply._(type: _redisReplyNil);
        return _ParsedReply._(type: type, integer: data[1] as int);
      case _redisReplyArray:
      case _redisReplyMap:
      case _redisReplySet:
      case _redisReplyPush:
        final elements = <_ParsedReply?>[];
        for (var i = 1; i < data.length; i++) {
          elements.add(fromNative(data[i]));
        }
        return _ParsedReply._(type: type, elements: elements);
      default:
        return _ParsedReply._(type: _redisReplyNil);
    }
  }
}

/// Exception thrown when a Redis operation fails.
class RedisException implements Exception {
  final String message;

  RedisException(this.message);

  @override
  String toString() => 'RedisException: $message';
}

/// The type of a Redis pub/sub message.
enum RedisPubSubMessageType {
  /// A message published to a channel.
  message,

  /// A message matching a pattern subscription.
  pmessage,

  /// Confirmation of a channel subscription.
  subscribe,

  /// Confirmation of a channel unsubscription.
  unsubscribe,

  /// Confirmation of a pattern subscription.
  psubscribe,

  /// Confirmation of a pattern unsubscription.
  punsubscribe,
}

/// A message received from a Redis pub/sub subscription.
class RedisPubSubMessage {
  /// The type of message.
  final RedisPubSubMessageType type;

  /// The channel the message was received on.
  final String channel;

  /// The message payload (null for subscribe/unsubscribe confirmations).
  final String? message;

  /// The pattern that matched (for pmessage type only).
  final String? pattern;

  RedisPubSubMessage._({
    required this.type,
    required this.channel,
    this.message,
    this.pattern,
  });

  @override
  String toString() {
    if (pattern != null) {
      return 'RedisPubSubMessage($type, pattern: $pattern, channel: $channel, message: $message)';
    }
    return 'RedisPubSubMessage($type, channel: $channel, message: $message)';
  }
}

/// Async Redis client with Future-based API.
///
/// This client uses hiredis's async API with a background polling isolate,
/// providing non-blocking operations and automatic pipelining support.
///
/// Example:
/// ```dart
/// final client = await RedisClient.connect('localhost', 6379);
/// try {
///   await client.set('key', 'value');
///   final value = await client.get('key');
///   print(value); // 'value'
/// } finally {
///   await client.close();
/// }
/// ```
class RedisClient {
  final String _host;
  final int _port;
  final Pointer<EventLoopState> _eventLoop;
  final ReceivePort _receivePort;

  final _pendingCommands = <int, Completer<_ParsedReply?>>{};
  var _nextCommandId = 0;
  var _closed = false;
  var _flushScheduled = false;

  RedisClient._(this._host, this._port, this._eventLoop, this._receivePort);

  /// Connects to a Redis server.
  ///
  /// Returns a [Future] that completes with the connected client.
  static Future<RedisClient> connect(String host, int port) async {
    _ensureDartApiInitialized();

    final options = calloc<redisOptions>();
    try {
      for (var i = 0; i < sizeOf<redisOptions>(); i++) {
        options.cast<Uint8>()[i] = 0;
      }

      final hostPtr = host.toNativeUtf8();
      try {
        options.ref.type = redisConnectionType.REDIS_CONN_TCP.value;
        options.ref.endpoint.tcp.ip = hostPtr.cast();
        options.ref.endpoint.tcp.port = port;
        options.ref.options = REDIS_OPT_NOAUTOFREE;

        final ctx = redisAsyncConnectWithOptions(options);
        if (ctx == nullptr) {
          throw RedisException('Failed to allocate async context');
        }

        if (ctx.ref.err != 0) {
          final errStr = _extractErrorString(ctx.ref.errstr);
          redisAsyncFree(ctx);
          throw RedisException('Connection failed: $errStr');
        }

        final receivePort = ReceivePort();
        final eventLoop = redis_event_loop_create(
          ctx,
          receivePort.sendPort.nativePort,
        );

        if (eventLoop == nullptr) {
          receivePort.close();
          redisAsyncFree(ctx);
          throw RedisException('Failed to create event loop');
        }

        final client = RedisClient._(host, port, eventLoop, receivePort);

        receivePort.listen((message) {
          if (client._closed) return;
          if (message is int && message == -1) {
            client._handleDisconnect();
            return;
          }
          if (message is List && message.length == 2) {
            final commandId = message[0] as int;
            final replyData = message[1];
            client._onReplyReceived(commandId, replyData);
          }
        });

        if (!redis_event_loop_start(eventLoop)) {
          receivePort.close();
          redis_event_loop_destroy(eventLoop);
          redisAsyncFree(ctx);
          throw RedisException('Failed to start event loop');
        }

        return client;
      } finally {
        calloc.free(hostPtr);
      }
    } finally {
      calloc.free(options);
    }
  }

  static String _extractErrorString(Pointer<Char> errstr) {
    if (errstr == nullptr) return 'Unknown error';
    return errstr.cast<Utf8>().toDartString();
  }

  void _checkNotClosed() {
    if (_closed) {
      throw StateError('RedisClient has been closed');
    }
  }

  void _handleDisconnect() {
    if (_closed) return;
    for (final completer in _pendingCommands.values) {
      if (!completer.isCompleted) {
        completer.completeError(RedisException('Connection lost'));
      }
    }
    _pendingCommands.clear();
  }

  void _onReplyReceived(int commandId, dynamic replyData) {
    if (_closed) return;
    final completer = _pendingCommands.remove(commandId);
    if (completer == null) return;

    final reply = _ParsedReply.fromNative(replyData);
    if (reply != null && reply.isError) {
      completer.completeError(RedisException(reply.string ?? 'Unknown error'));
    } else {
      completer.complete(reply);
    }
  }

  /// Sends a raw command and returns the reply.
  /// Commands are automatically batched and flushed via microtask.
  Future<_ParsedReply?> _command(List<String> args) async {
    _checkNotClosed();

    final commandId = _nextCommandId++;
    final completer = Completer<_ParsedReply?>();
    _pendingCommands[commandId] = completer;

    final argc = args.length;
    final argv = calloc<Pointer<Char>>(argc);
    final argvlen = calloc<Size>(argc);

    try {
      for (var i = 0; i < argc; i++) {
        final arg = args[i].toNativeUtf8();
        argv[i] = arg.cast();
        argvlen[i] = args[i].length;
      }

      final result = redis_async_command_enqueue(
        _eventLoop,
        _receivePort.sendPort.nativePort,
        commandId,
        argc,
        argv,
        argvlen,
      );

      if (result != 0) {
        _pendingCommands.remove(commandId);
        throw RedisException('Failed to send command');
      }

      _scheduleFlush();
    } finally {
      for (var i = 0; i < argc; i++) {
        if (argv[i] != nullptr) {
          calloc.free(argv[i].cast<Utf8>());
        }
      }
      calloc.free(argv);
      calloc.free(argvlen);
    }

    return completer.future;
  }

  /// Schedules a flush via microtask if not already scheduled.
  /// This batches all commands issued in the current event loop turn.
  void _scheduleFlush() {
    if (!_flushScheduled) {
      _flushScheduled = true;
      scheduleMicrotask(() {
        _flushScheduled = false;
        if (!_closed) {
          redis_event_loop_wakeup(_eventLoop);
        }
      });
    }
  }

  /// Pings the server.
  Future<String> ping([String? message]) async {
    final reply = await _command(
      message != null ? ['PING', message] : ['PING'],
    );
    return reply?.string ?? 'PONG';
  }

  // ============ String Commands ============

  /// Gets the value of a key.
  ///
  /// Returns `null` if the key does not exist.
  Future<String?> get(String key) async {
    final reply = await _command(['GET', key]);
    return reply?.string;
  }

  /// Sets a key to a value.
  ///
  /// Options:
  /// - [ex]: Set expiry in seconds
  /// - [px]: Set expiry in milliseconds
  /// - [exat]: Set expiry at Unix timestamp in seconds
  /// - [pxat]: Set expiry at Unix timestamp in milliseconds
  /// - [nx]: Only set if key does not exist
  /// - [xx]: Only set if key already exists
  /// - [keepTtl]: Retain the existing TTL
  /// - [get]: Return the old value stored at key
  ///
  /// Returns the old value if [get] is true, otherwise returns `null`.
  Future<String?> set(
    String key,
    String value, {
    int? ex,
    int? px,
    int? exat,
    int? pxat,
    bool nx = false,
    bool xx = false,
    bool keepTtl = false,
    bool get = false,
  }) async {
    final args = ['SET', key, value];
    if (ex != null) args.addAll(['EX', ex.toString()]);
    if (px != null) args.addAll(['PX', px.toString()]);
    if (exat != null) args.addAll(['EXAT', exat.toString()]);
    if (pxat != null) args.addAll(['PXAT', pxat.toString()]);
    if (nx) args.add('NX');
    if (xx) args.add('XX');
    if (keepTtl) args.add('KEEPTTL');
    if (get) args.add('GET');

    final reply = await _command(args);
    return reply?.string;
  }

  /// Gets the values of multiple keys.
  ///
  /// Returns a list of values in the same order as the keys.
  /// Non-existent keys return `null`.
  Future<List<String?>> mget(List<String> keys) async {
    final reply = await _command(['MGET', ...keys]);
    try {
      if (reply == null) return List.filled(keys.length, null);
      final results = <String?>[];
      for (var i = 0; i < reply.length; i++) {
        results.add(reply[i]?.string);
      }
      return results;
    } finally {}
  }

  /// Sets multiple keys to their respective values.
  Future<void> mset(Map<String, String> keyValues) async {
    final args = ['MSET'];
    keyValues.forEach((key, value) {
      args.addAll([key, value]);
    });
    await _command(args);
  }

  /// Sets multiple keys only if none of them exist.
  ///
  /// Returns `true` if all keys were set, `false` if no keys were set
  /// (because at least one key already existed).
  Future<bool> msetnx(Map<String, String> keyValues) async {
    final args = ['MSETNX'];
    keyValues.forEach((key, value) {
      args.addAll([key, value]);
    });
    final reply = await _command(args);
    return (reply?.integer ?? 0) == 1;
  }

  /// Increments the integer value of a key by one.
  ///
  /// Returns the new value after incrementing.
  Future<int> incr(String key) async {
    final reply = await _command(['INCR', key]);
    return reply?.integer ?? 0;
  }

  /// Increments the integer value of a key by the given amount.
  ///
  /// Returns the new value after incrementing.
  Future<int> incrby(String key, int increment) async {
    final reply = await _command(['INCRBY', key, increment.toString()]);
    return reply?.integer ?? 0;
  }

  /// Increments the floating point value of a key by the given amount.
  ///
  /// Returns the new value after incrementing.
  Future<double> incrbyfloat(String key, double increment) async {
    final reply = await _command(['INCRBYFLOAT', key, increment.toString()]);
    try {
      final str = reply?.string;
      return str != null ? double.parse(str) : 0.0;
    } finally {}
  }

  /// Decrements the integer value of a key by one.
  ///
  /// Returns the new value after decrementing.
  Future<int> decr(String key) async {
    final reply = await _command(['DECR', key]);
    return reply?.integer ?? 0;
  }

  /// Decrements the integer value of a key by the given amount.
  ///
  /// Returns the new value after decrementing.
  Future<int> decrby(String key, int decrement) async {
    final reply = await _command(['DECRBY', key, decrement.toString()]);
    return reply?.integer ?? 0;
  }

  /// Appends a value to a key.
  ///
  /// Returns the length of the string after the append.
  Future<int> append(String key, String value) async {
    final reply = await _command(['APPEND', key, value]);
    return reply?.integer ?? 0;
  }

  /// Returns the length of the string stored at key.
  Future<int> strlen(String key) async {
    final reply = await _command(['STRLEN', key]);
    return reply?.integer ?? 0;
  }

  /// Sets or clears the bit at offset in the string value stored at key.
  ///
  /// Returns the original bit value at the offset.
  Future<int> setbit(String key, int offset, int value) async {
    final reply = await _command([
      'SETBIT',
      key,
      offset.toString(),
      value.toString(),
    ]);
    return reply?.integer ?? 0;
  }

  /// Returns the bit value at offset in the string value stored at key.
  Future<int> getbit(String key, int offset) async {
    final reply = await _command(['GETBIT', key, offset.toString()]);
    return reply?.integer ?? 0;
  }

  /// Overwrites part of the string stored at key starting at the specified offset.
  ///
  /// Returns the length of the string after it was modified.
  Future<int> setrange(String key, int offset, String value) async {
    final reply = await _command(['SETRANGE', key, offset.toString(), value]);
    return reply?.integer ?? 0;
  }

  /// Returns a substring of the string stored at key.
  Future<String?> getrange(String key, int start, int end) async {
    final reply = await _command([
      'GETRANGE',
      key,
      start.toString(),
      end.toString(),
    ]);
    return reply?.string;
  }

  /// Sets the value and expiration of a key in seconds.
  Future<void> setex(String key, int seconds, String value) async {
    await _command(['SETEX', key, seconds.toString(), value]);
  }

  /// Sets the value and expiration of a key in milliseconds.
  Future<void> psetex(String key, int milliseconds, String value) async {
    await _command(['PSETEX', key, milliseconds.toString(), value]);
  }

  /// Sets the value of a key only if the key does not exist.
  ///
  /// Returns `true` if the key was set, `false` if it already existed.
  Future<bool> setnx(String key, String value) async {
    final reply = await _command(['SETNX', key, value]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Atomically sets a key to a value and returns the old value.
  Future<String?> getset(String key, String value) async {
    final reply = await _command(['GETSET', key, value]);
    return reply?.string;
  }

  /// Gets the value of a key and deletes it.
  Future<String?> getdel(String key) async {
    final reply = await _command(['GETDEL', key]);
    return reply?.string;
  }

  /// Gets the value of a key and optionally sets its expiration.
  Future<String?> getex(
    String key, {
    int? ex,
    int? px,
    int? exat,
    int? pxat,
    bool persist = false,
  }) async {
    final args = ['GETEX', key];
    if (ex != null) args.addAll(['EX', ex.toString()]);
    if (px != null) args.addAll(['PX', px.toString()]);
    if (exat != null) args.addAll(['EXAT', exat.toString()]);
    if (pxat != null) args.addAll(['PXAT', pxat.toString()]);
    if (persist) args.add('PERSIST');

    final reply = await _command(args);
    return reply?.string;
  }

  // ============ Key Commands ============

  /// Deletes one or more keys.
  ///
  /// Returns the number of keys that were deleted.
  Future<int> del(List<String> keys) async {
    final reply = await _command(['DEL', ...keys]);
    return reply?.integer ?? 0;
  }

  /// Deletes one or more keys asynchronously (non-blocking).
  ///
  /// Returns the number of keys that were scheduled for deletion.
  Future<int> unlink(List<String> keys) async {
    final reply = await _command(['UNLINK', ...keys]);
    return reply?.integer ?? 0;
  }

  /// Checks if one or more keys exist.
  ///
  /// Returns the number of keys that exist.
  Future<int> existsCount(List<String> keys) async {
    final reply = await _command(['EXISTS', ...keys]);
    return reply?.integer ?? 0;
  }

  /// Checks if a key exists.
  Future<bool> exists(String key) async {
    return (await existsCount([key])) > 0;
  }

  /// Sets a timeout on a key in seconds.
  ///
  /// Returns `true` if the timeout was set, `false` if the key doesn't exist.
  Future<bool> expire(String key, int seconds) async {
    final reply = await _command(['EXPIRE', key, seconds.toString()]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Sets a timeout on a key in milliseconds.
  ///
  /// Returns `true` if the timeout was set, `false` if the key doesn't exist.
  Future<bool> pexpire(String key, int milliseconds) async {
    final reply = await _command(['PEXPIRE', key, milliseconds.toString()]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Sets an absolute Unix timestamp expiry on a key (in seconds).
  ///
  /// Returns `true` if the timeout was set, `false` if the key doesn't exist.
  Future<bool> expireat(String key, int timestamp) async {
    final reply = await _command(['EXPIREAT', key, timestamp.toString()]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Sets an absolute Unix timestamp expiry on a key (in milliseconds).
  ///
  /// Returns `true` if the timeout was set, `false` if the key doesn't exist.
  Future<bool> pexpireat(String key, int timestamp) async {
    final reply = await _command(['PEXPIREAT', key, timestamp.toString()]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Gets the remaining time to live of a key in seconds.
  ///
  /// Returns -2 if the key doesn't exist, -1 if the key has no expiry.
  Future<int> ttl(String key) async {
    final reply = await _command(['TTL', key]);
    return reply?.integer ?? -2;
  }

  /// Gets the remaining time to live of a key in milliseconds.
  ///
  /// Returns -2 if the key doesn't exist, -1 if the key has no expiry.
  Future<int> pttl(String key) async {
    final reply = await _command(['PTTL', key]);
    return reply?.integer ?? -2;
  }

  /// Removes the expiry from a key.
  ///
  /// Returns `true` if the timeout was removed, `false` if the key doesn't
  /// exist or has no associated timeout.
  Future<bool> persist(String key) async {
    final reply = await _command(['PERSIST', key]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Returns the absolute Unix timestamp (in seconds) at which the key will expire.
  ///
  /// Returns -2 if the key doesn't exist, -1 if the key has no expiry.
  Future<int> expiretime(String key) async {
    final reply = await _command(['EXPIRETIME', key]);
    return reply?.integer ?? -2;
  }

  /// Returns the absolute Unix timestamp (in milliseconds) at which the key will expire.
  ///
  /// Returns -2 if the key doesn't exist, -1 if the key has no expiry.
  Future<int> pexpiretime(String key) async {
    final reply = await _command(['PEXPIRETIME', key]);
    return reply?.integer ?? -2;
  }

  /// Returns the type of the value stored at key.
  ///
  /// Returns "none" if the key doesn't exist.
  Future<String> type(String key) async {
    final reply = await _command(['TYPE', key]);
    return reply?.string ?? 'none';
  }

  /// Renames a key.
  ///
  /// Throws if the key doesn't exist.
  Future<void> rename(String key, String newKey) async {
    await _command(['RENAME', key, newKey]);
  }

  /// Renames a key only if the new key doesn't already exist.
  ///
  /// Returns `true` if the key was renamed, `false` if the new key already exists.
  Future<bool> renamenx(String key, String newKey) async {
    final reply = await _command(['RENAMENX', key, newKey]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Returns all keys matching the given pattern.
  ///
  /// Warning: KEYS should not be used in production as it may block the server.
  /// Use [scan] instead for production workloads.
  Future<List<String>> keys(String pattern) async {
    final reply = await _command(['KEYS', pattern]);
    try {
      if (reply == null) return [];
      final results = <String>[];
      for (var i = 0; i < reply.length; i++) {
        final key = reply[i]?.string;
        if (key != null) results.add(key);
      }
      return results;
    } finally {}
  }

  /// Incrementally iterates over keys matching a pattern.
  ///
  /// Returns a tuple of (nextCursor, keys). When nextCursor is "0", iteration is complete.
  Future<(String, List<String>)> scan(
    String cursor, {
    String? match,
    int? count,
    String? type,
  }) async {
    final args = ['SCAN', cursor];
    if (match != null) args.addAll(['MATCH', match]);
    if (count != null) args.addAll(['COUNT', count.toString()]);
    if (type != null) args.addAll(['TYPE', type]);

    final reply = await _command(args);
    try {
      if (reply == null || reply.length < 2) return ('0', <String>[]);

      final nextCursor = reply[0]?.string ?? '0';
      final keysReply = reply[1];
      final keys = <String>[];
      if (keysReply != null) {
        for (var i = 0; i < keysReply.length; i++) {
          final key = keysReply[i]?.string;
          if (key != null) keys.add(key);
        }
      }
      return (nextCursor, keys);
    } finally {}
  }

  /// Returns a random key from the database.
  Future<String?> randomkey() async {
    final reply = await _command(['RANDOMKEY']);
    return reply?.string;
  }

  /// Touches one or more keys (updates last access time).
  ///
  /// Returns the number of keys that were touched.
  Future<int> touch(List<String> keys) async {
    final reply = await _command(['TOUCH', ...keys]);
    return reply?.integer ?? 0;
  }

  /// Returns the number of bytes that a key and its value require in RAM.
  Future<int?> memoryUsage(String key, {int? samples}) async {
    final args = ['MEMORY', 'USAGE', key];
    if (samples != null) args.addAll(['SAMPLES', samples.toString()]);

    final reply = await _command(args);
    return reply?.integer;
  }

  /// Copies a key to another key.
  ///
  /// Returns `true` if the key was copied, `false` otherwise.
  Future<bool> copy(
    String source,
    String destination, {
    int? db,
    bool replace = false,
  }) async {
    final args = ['COPY', source, destination];
    if (db != null) args.addAll(['DB', db.toString()]);
    if (replace) args.add('REPLACE');

    final reply = await _command(args);
    return (reply?.integer ?? 0) == 1;
  }

  /// Returns the time since the object stored at key is idle.
  Future<int?> objectIdletime(String key) async {
    final reply = await _command(['OBJECT', 'IDLETIME', key]);
    return reply?.integer;
  }

  /// Returns the access frequency of the object stored at key.
  Future<int?> objectFreq(String key) async {
    final reply = await _command(['OBJECT', 'FREQ', key]);
    return reply?.integer;
  }

  /// Returns the encoding of the object stored at key.
  Future<String?> objectEncoding(String key) async {
    final reply = await _command(['OBJECT', 'ENCODING', key]);
    return reply?.string;
  }

  // ============ Hash Commands ============

  /// Sets a field in a hash.
  ///
  /// Returns the number of fields that were added (0 if the field already
  /// existed and was updated).
  Future<int> hset(String key, String field, String value) async {
    final reply = await _command(['HSET', key, field, value]);
    return reply?.integer ?? 0;
  }

  /// Sets multiple fields in a hash.
  ///
  /// Returns the number of fields that were added.
  Future<int> hsetAll(String key, Map<String, String> fieldValues) async {
    final args = ['HSET', key];
    for (final entry in fieldValues.entries) {
      args.addAll([entry.key, entry.value]);
    }

    final reply = await _command(args);
    return reply?.integer ?? 0;
  }

  /// Gets the value of a field in a hash.
  Future<String?> hget(String key, String field) async {
    final reply = await _command(['HGET', key, field]);
    return reply?.string;
  }

  /// Gets all fields and values in a hash.
  Future<Map<String, String>> hgetall(String key) async {
    final reply = await _command(['HGETALL', key]);
    try {
      final result = <String, String>{};
      if (reply == null) return result;

      for (var i = 0; i < reply.length - 1; i += 2) {
        final field = reply[i]?.string;
        final value = reply[i + 1]?.string;
        if (field != null && value != null) {
          result[field] = value;
        }
      }
      return result;
    } finally {}
  }

  /// Gets the values of multiple fields in a hash.
  Future<List<String?>> hmget(String key, List<String> fields) async {
    final reply = await _command(['HMGET', key, ...fields]);
    try {
      final result = <String?>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        result.add(reply[i]?.string);
      }
      return result;
    } finally {}
  }

  /// Deletes one or more fields from a hash.
  ///
  /// Returns the number of fields that were removed.
  Future<int> hdel(String key, List<String> fields) async {
    final reply = await _command(['HDEL', key, ...fields]);
    return reply?.integer ?? 0;
  }

  /// Checks if a field exists in a hash.
  Future<bool> hexists(String key, String field) async {
    final reply = await _command(['HEXISTS', key, field]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Gets all field names in a hash.
  Future<List<String>> hkeys(String key) async {
    final reply = await _command(['HKEYS', key]);
    try {
      final result = <String>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final field = reply[i]?.string;
        if (field != null) result.add(field);
      }
      return result;
    } finally {}
  }

  /// Gets all values in a hash.
  Future<List<String>> hvals(String key) async {
    final reply = await _command(['HVALS', key]);
    try {
      final result = <String>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final value = reply[i]?.string;
        if (value != null) result.add(value);
      }
      return result;
    } finally {}
  }

  /// Gets the number of fields in a hash.
  Future<int> hlen(String key) async {
    final reply = await _command(['HLEN', key]);
    return reply?.integer ?? 0;
  }

  /// Increments the integer value of a field in a hash.
  ///
  /// Returns the value after the increment.
  Future<int> hincrby(String key, String field, int increment) async {
    final reply = await _command(['HINCRBY', key, field, increment.toString()]);
    return reply?.integer ?? 0;
  }

  /// Increments the float value of a field in a hash.
  ///
  /// Returns the value after the increment.
  Future<double> hincrbyfloat(
    String key,
    String field,
    double increment,
  ) async {
    final reply = await _command([
      'HINCRBYFLOAT',
      key,
      field,
      increment.toString(),
    ]);
    try {
      final str = reply?.string;
      return str != null ? double.parse(str) : 0.0;
    } finally {}
  }

  /// Sets a field in a hash only if it does not exist.
  ///
  /// Returns `true` if the field was set, `false` if it already existed.
  Future<bool> hsetnx(String key, String field, String value) async {
    final reply = await _command(['HSETNX', key, field, value]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Gets the string length of a field value in a hash.
  Future<int> hstrlen(String key, String field) async {
    final reply = await _command(['HSTRLEN', key, field]);
    return reply?.integer ?? 0;
  }

  /// Returns a random field from a hash.
  ///
  /// If [count] is provided, returns that many fields (or fewer if the hash
  /// is smaller). If [withValues] is true, returns field-value pairs.
  Future<List<String>> hrandfield(
    String key, {
    int? count,
    bool withValues = false,
  }) async {
    final args = ['HRANDFIELD', key];
    if (count != null) {
      args.add(count.toString());
      if (withValues) args.add('WITHVALUES');
    }

    final reply = await _command(args);
    try {
      final result = <String>[];
      if (reply == null) return result;

      // Single field returned as string, multiple as array
      if (reply.string != null) {
        result.add(reply.string!);
      } else {
        for (var i = 0; i < reply.length; i++) {
          final item = reply[i]?.string;
          if (item != null) result.add(item);
        }
      }
      return result;
    } finally {}
  }

  /// Incrementally iterates over fields in a hash.
  ///
  /// Returns a tuple of (nextCursor, fieldValuePairs).
  /// When nextCursor is '0', iteration is complete.
  Future<(String, Map<String, String>)> hscan(
    String key,
    String cursor, {
    String? match,
    int? count,
  }) async {
    final args = ['HSCAN', key, cursor];
    if (match != null) args.addAll(['MATCH', match]);
    if (count != null) args.addAll(['COUNT', count.toString()]);

    final reply = await _command(args);
    try {
      if (reply == null || reply.length < 2) {
        return ('0', <String, String>{});
      }

      final nextCursor = reply[0]?.string ?? '0';
      final itemsReply = reply[1];
      final result = <String, String>{};
      if (itemsReply != null) {
        for (var i = 0; i < itemsReply.length - 1; i += 2) {
          final field = itemsReply[i]?.string;
          final value = itemsReply[i + 1]?.string;
          if (field != null && value != null) {
            result[field] = value;
          }
        }
      }
      return (nextCursor, result);
    } finally {}
  }

  // ============ List Commands ============

  /// Pushes values to the left (head) of a list.
  ///
  /// Returns the length of the list after the push.
  Future<int> lpush(String key, List<String> values) async {
    final reply = await _command(['LPUSH', key, ...values]);
    return reply?.integer ?? 0;
  }

  /// Pushes values to the right (tail) of a list.
  ///
  /// Returns the length of the list after the push.
  Future<int> rpush(String key, List<String> values) async {
    final reply = await _command(['RPUSH', key, ...values]);
    return reply?.integer ?? 0;
  }

  /// Pushes a value to the left of a list only if the list exists.
  ///
  /// Returns the length of the list after the push, or 0 if the list doesn't
  /// exist.
  Future<int> lpushx(String key, List<String> values) async {
    final reply = await _command(['LPUSHX', key, ...values]);
    return reply?.integer ?? 0;
  }

  /// Pushes a value to the right of a list only if the list exists.
  ///
  /// Returns the length of the list after the push, or 0 if the list doesn't
  /// exist.
  Future<int> rpushx(String key, List<String> values) async {
    final reply = await _command(['RPUSHX', key, ...values]);
    return reply?.integer ?? 0;
  }

  /// Removes and returns the first element of a list.
  Future<String?> lpop(String key) async {
    final reply = await _command(['LPOP', key]);
    return reply?.string;
  }

  /// Removes and returns the last element of a list.
  Future<String?> rpop(String key) async {
    final reply = await _command(['RPOP', key]);
    return reply?.string;
  }

  /// Removes and returns multiple elements from the left of a list.
  Future<List<String>> lpopCount(String key, int count) async {
    final reply = await _command(['LPOP', key, count.toString()]);
    try {
      final result = <String>[];
      if (reply == null) return result;

      // Single element returned as string, multiple as array
      if (reply.string != null) {
        result.add(reply.string!);
      } else {
        for (var i = 0; i < reply.length; i++) {
          final item = reply[i]?.string;
          if (item != null) result.add(item);
        }
      }
      return result;
    } finally {}
  }

  /// Removes and returns multiple elements from the right of a list.
  Future<List<String>> rpopCount(String key, int count) async {
    final reply = await _command(['RPOP', key, count.toString()]);
    try {
      final result = <String>[];
      if (reply == null) return result;

      if (reply.string != null) {
        result.add(reply.string!);
      } else {
        for (var i = 0; i < reply.length; i++) {
          final item = reply[i]?.string;
          if (item != null) result.add(item);
        }
      }
      return result;
    } finally {}
  }

  /// Returns a range of elements from a list.
  ///
  /// [start] and [stop] are zero-based indices. Negative indices count from
  /// the end (-1 is the last element).
  Future<List<String>> lrange(String key, int start, int stop) async {
    final reply = await _command([
      'LRANGE',
      key,
      start.toString(),
      stop.toString(),
    ]);
    try {
      final result = <String>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final item = reply[i]?.string;
        if (item != null) result.add(item);
      }
      return result;
    } finally {}
  }

  /// Returns the element at [index] in the list.
  ///
  /// Negative indices count from the end (-1 is the last element).
  Future<String?> lindex(String key, int index) async {
    final reply = await _command(['LINDEX', key, index.toString()]);
    return reply?.string;
  }

  /// Sets the element at [index] in the list.
  Future<void> lset(String key, int index, String value) async {
    await _command(['LSET', key, index.toString(), value]);
  }

  /// Returns the length of a list.
  Future<int> llen(String key) async {
    final reply = await _command(['LLEN', key]);
    return reply?.integer ?? 0;
  }

  /// Inserts an element before or after a pivot element.
  ///
  /// Returns the length of the list after the insert, or -1 if the pivot
  /// was not found, or 0 if the key doesn't exist.
  Future<int> linsert(
    String key,
    String pivot,
    String value, {
    required bool before,
  }) async {
    final position = before ? 'BEFORE' : 'AFTER';
    final reply = await _command(['LINSERT', key, position, pivot, value]);
    return reply?.integer ?? 0;
  }

  /// Removes [count] occurrences of [value] from the list.
  ///
  /// - count > 0: Remove from head to tail
  /// - count < 0: Remove from tail to head
  /// - count = 0: Remove all occurrences
  ///
  /// Returns the number of removed elements.
  Future<int> lrem(String key, int count, String value) async {
    final reply = await _command(['LREM', key, count.toString(), value]);
    return reply?.integer ?? 0;
  }

  /// Trims a list to the specified range.
  Future<void> ltrim(String key, int start, int stop) async {
    await _command(['LTRIM', key, start.toString(), stop.toString()]);
  }

  /// Atomically moves an element from one list to another.
  ///
  /// [srcDirection] and [dstDirection] can be 'LEFT' or 'RIGHT'.
  Future<String?> lmove(
    String source,
    String destination, {
    required String srcDirection,
    required String dstDirection,
  }) async {
    final reply = await _command([
      'LMOVE',
      source,
      destination,
      srcDirection,
      dstDirection,
    ]);
    return reply?.string;
  }

  /// Returns the index of the first matching element in a list.
  ///
  /// Returns null if the element is not found.
  Future<int?> lpos(String key, String element) async {
    final reply = await _command(['LPOS', key, element]);
    try {
      if (reply == null || reply.isNil) return null;
      return reply.integer;
    } finally {}
  }

  // ============ Set Commands ============

  /// Adds one or more members to a set.
  ///
  /// Returns the number of members that were added (not already present).
  Future<int> sadd(String key, List<String> members) async {
    final reply = await _command(['SADD', key, ...members]);
    return reply?.integer ?? 0;
  }

  /// Removes one or more members from a set.
  ///
  /// Returns the number of members that were removed.
  Future<int> srem(String key, List<String> members) async {
    final reply = await _command(['SREM', key, ...members]);
    return reply?.integer ?? 0;
  }

  /// Returns all members of a set.
  Future<Set<String>> smembers(String key) async {
    final reply = await _command(['SMEMBERS', key]);
    try {
      final result = <String>{};
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final member = reply[i]?.string;
        if (member != null) result.add(member);
      }
      return result;
    } finally {}
  }

  /// Checks if a member is in a set.
  Future<bool> sismember(String key, String member) async {
    final reply = await _command(['SISMEMBER', key, member]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Checks if multiple members are in a set.
  ///
  /// Returns a list of booleans indicating membership for each member.
  Future<List<bool>> smismember(String key, List<String> members) async {
    final reply = await _command(['SMISMEMBER', key, ...members]);
    try {
      final result = <bool>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        result.add((reply[i]?.integer ?? 0) == 1);
      }
      return result;
    } finally {}
  }

  /// Returns the number of members in a set.
  Future<int> scard(String key) async {
    final reply = await _command(['SCARD', key]);
    return reply?.integer ?? 0;
  }

  /// Removes and returns a random member from a set.
  Future<String?> spop(String key) async {
    final reply = await _command(['SPOP', key]);
    return reply?.string;
  }

  /// Removes and returns multiple random members from a set.
  Future<Set<String>> spopCount(String key, int count) async {
    final reply = await _command(['SPOP', key, count.toString()]);
    try {
      final result = <String>{};
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final member = reply[i]?.string;
        if (member != null) result.add(member);
      }
      return result;
    } finally {}
  }

  /// Returns a random member from a set without removing it.
  Future<String?> srandmember(String key) async {
    final reply = await _command(['SRANDMEMBER', key]);
    return reply?.string;
  }

  /// Returns multiple random members from a set without removing them.
  Future<List<String>> srandmemberCount(String key, int count) async {
    final reply = await _command(['SRANDMEMBER', key, count.toString()]);
    try {
      final result = <String>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final member = reply[i]?.string;
        if (member != null) result.add(member);
      }
      return result;
    } finally {}
  }

  /// Moves a member from one set to another.
  ///
  /// Returns `true` if the member was moved, `false` if it wasn't in the source
  /// set.
  Future<bool> smove(String source, String destination, String member) async {
    final reply = await _command(['SMOVE', source, destination, member]);
    return (reply?.integer ?? 0) == 1;
  }

  /// Returns the difference between the first set and all subsequent sets.
  Future<Set<String>> sdiff(List<String> keys) async {
    final reply = await _command(['SDIFF', ...keys]);
    try {
      final result = <String>{};
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final member = reply[i]?.string;
        if (member != null) result.add(member);
      }
      return result;
    } finally {}
  }

  /// Stores the difference between sets in a destination set.
  ///
  /// Returns the number of members in the resulting set.
  Future<int> sdiffstore(String destination, List<String> keys) async {
    final reply = await _command(['SDIFFSTORE', destination, ...keys]);
    return reply?.integer ?? 0;
  }

  /// Returns the intersection of all given sets.
  Future<Set<String>> sinter(List<String> keys) async {
    final reply = await _command(['SINTER', ...keys]);
    try {
      final result = <String>{};
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final member = reply[i]?.string;
        if (member != null) result.add(member);
      }
      return result;
    } finally {}
  }

  /// Stores the intersection of sets in a destination set.
  ///
  /// Returns the number of members in the resulting set.
  Future<int> sinterstore(String destination, List<String> keys) async {
    final reply = await _command(['SINTERSTORE', destination, ...keys]);
    return reply?.integer ?? 0;
  }

  /// Returns the cardinality of the intersection of all given sets.
  Future<int> sintercard(List<String> keys, {int? limit}) async {
    final args = ['SINTERCARD', keys.length.toString(), ...keys];
    if (limit != null) args.addAll(['LIMIT', limit.toString()]);

    final reply = await _command(args);
    return reply?.integer ?? 0;
  }

  /// Returns the union of all given sets.
  Future<Set<String>> sunion(List<String> keys) async {
    final reply = await _command(['SUNION', ...keys]);
    try {
      final result = <String>{};
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final member = reply[i]?.string;
        if (member != null) result.add(member);
      }
      return result;
    } finally {}
  }

  /// Stores the union of sets in a destination set.
  ///
  /// Returns the number of members in the resulting set.
  Future<int> sunionstore(String destination, List<String> keys) async {
    final reply = await _command(['SUNIONSTORE', destination, ...keys]);
    return reply?.integer ?? 0;
  }

  /// Incrementally iterates over members of a set.
  ///
  /// Returns a tuple of (nextCursor, members).
  /// When nextCursor is '0', iteration is complete.
  Future<(String, Set<String>)> sscan(
    String key,
    String cursor, {
    String? match,
    int? count,
  }) async {
    final args = ['SSCAN', key, cursor];
    if (match != null) args.addAll(['MATCH', match]);
    if (count != null) args.addAll(['COUNT', count.toString()]);

    final reply = await _command(args);
    try {
      if (reply == null || reply.length < 2) {
        return ('0', <String>{});
      }

      final nextCursor = reply[0]?.string ?? '0';
      final itemsReply = reply[1];
      final result = <String>{};
      if (itemsReply != null) {
        for (var i = 0; i < itemsReply.length; i++) {
          final member = itemsReply[i]?.string;
          if (member != null) result.add(member);
        }
      }
      return (nextCursor, result);
    } finally {}
  }

  // ============ Sorted Set Commands ============

  /// Adds one or more members to a sorted set, or updates the score if the
  /// member already exists.
  ///
  /// [members] is a map of member -> score pairs.
  ///
  /// Options:
  /// - [nx]: Only add new members, don't update existing ones.
  /// - [xx]: Only update existing members, don't add new ones.
  /// - [gt]: Only update when the new score is greater than the current score.
  /// - [lt]: Only update when the new score is less than the current score.
  /// - [ch]: Return the number of changed elements (added + updated) instead
  ///   of just added.
  ///
  /// Returns the number of elements added (or changed if [ch] is true).
  Future<int> zadd(
    String key,
    Map<String, double> members, {
    bool nx = false,
    bool xx = false,
    bool gt = false,
    bool lt = false,
    bool ch = false,
  }) async {
    final args = ['ZADD', key];
    if (nx) args.add('NX');
    if (xx) args.add('XX');
    if (gt) args.add('GT');
    if (lt) args.add('LT');
    if (ch) args.add('CH');

    for (final entry in members.entries) {
      args.addAll([entry.value.toString(), entry.key]);
    }

    final reply = await _command(args);
    return reply?.integer ?? 0;
  }

  /// Removes one or more members from a sorted set.
  ///
  /// Returns the number of members removed.
  Future<int> zrem(String key, List<String> members) async {
    final reply = await _command(['ZREM', key, ...members]);
    return reply?.integer ?? 0;
  }

  /// Returns the score of a member in a sorted set.
  Future<double?> zscore(String key, String member) async {
    final reply = await _command(['ZSCORE', key, member]);
    try {
      if (reply == null || reply.isNil) return null;
      final str = reply.string;
      return str != null ? double.parse(str) : null;
    } finally {}
  }

  /// Returns the scores of multiple members in a sorted set.
  Future<List<double?>> zmscore(String key, List<String> members) async {
    final reply = await _command(['ZMSCORE', key, ...members]);
    try {
      final result = <double?>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final element = reply[i];
        if (element == null || element.isNil) {
          result.add(null);
        } else {
          final str = element.string;
          result.add(str != null ? double.parse(str) : null);
        }
      }
      return result;
    } finally {}
  }

  /// Returns the rank (index) of a member in a sorted set (0-based).
  ///
  /// Members are ordered from lowest to highest score.
  Future<int?> zrank(String key, String member) async {
    final reply = await _command(['ZRANK', key, member]);
    try {
      if (reply == null || reply.isNil) return null;
      return reply.integer;
    } finally {}
  }

  /// Returns the reverse rank (index) of a member in a sorted set (0-based).
  ///
  /// Members are ordered from highest to lowest score.
  Future<int?> zrevrank(String key, String member) async {
    final reply = await _command(['ZREVRANK', key, member]);
    try {
      if (reply == null || reply.isNil) return null;
      return reply.integer;
    } finally {}
  }

  /// Returns the number of members in a sorted set.
  Future<int> zcard(String key) async {
    final reply = await _command(['ZCARD', key]);
    return reply?.integer ?? 0;
  }

  /// Returns the number of members in a sorted set with scores within the
  /// given range.
  Future<int> zcount(String key, String min, String max) async {
    final reply = await _command(['ZCOUNT', key, min, max]);
    return reply?.integer ?? 0;
  }

  /// Returns a range of members from a sorted set by index.
  ///
  /// If [withScores] is true, returns alternating member, score pairs.
  Future<List<String>> zrange(
    String key,
    int start,
    int stop, {
    bool withScores = false,
  }) async {
    final args = ['ZRANGE', key, start.toString(), stop.toString()];
    if (withScores) args.add('WITHSCORES');

    final reply = await _command(args);
    try {
      final result = <String>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final item = reply[i]?.string;
        if (item != null) result.add(item);
      }
      return result;
    } finally {}
  }

  /// Returns a range of members from a sorted set by index, with scores.
  ///
  /// Returns a list of (member, score) pairs.
  Future<List<(String, double)>> zrangeWithScores(
    String key,
    int start,
    int stop,
  ) async {
    final reply = await _command([
      'ZRANGE',
      key,
      start.toString(),
      stop.toString(),
      'WITHSCORES',
    ]);
    try {
      final result = <(String, double)>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length - 1; i += 2) {
        final member = reply[i]?.string;
        final scoreStr = reply[i + 1]?.string;
        if (member != null && scoreStr != null) {
          result.add((member, double.parse(scoreStr)));
        }
      }
      return result;
    } finally {}
  }

  /// Returns a range of members from a sorted set by score.
  Future<List<String>> zrangebyscore(
    String key,
    String min,
    String max, {
    int? offset,
    int? count,
  }) async {
    final args = ['ZRANGEBYSCORE', key, min, max];
    if (offset != null && count != null) {
      args.addAll(['LIMIT', offset.toString(), count.toString()]);
    }

    final reply = await _command(args);
    try {
      final result = <String>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final item = reply[i]?.string;
        if (item != null) result.add(item);
      }
      return result;
    } finally {}
  }

  /// Returns a range of members from a sorted set by score (highest to lowest).
  Future<List<String>> zrevrangebyscore(
    String key,
    String max,
    String min, {
    int? offset,
    int? count,
  }) async {
    final args = ['ZREVRANGEBYSCORE', key, max, min];
    if (offset != null && count != null) {
      args.addAll(['LIMIT', offset.toString(), count.toString()]);
    }

    final reply = await _command(args);
    try {
      final result = <String>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length; i++) {
        final item = reply[i]?.string;
        if (item != null) result.add(item);
      }
      return result;
    } finally {}
  }

  /// Increments the score of a member in a sorted set.
  ///
  /// Returns the new score.
  Future<double> zincrby(String key, double increment, String member) async {
    final reply = await _command([
      'ZINCRBY',
      key,
      increment.toString(),
      member,
    ]);
    try {
      final str = reply?.string;
      return str != null ? double.parse(str) : 0.0;
    } finally {}
  }

  /// Removes all members in a sorted set within the given score range.
  ///
  /// Returns the number of members removed.
  Future<int> zremrangebyscore(String key, String min, String max) async {
    final reply = await _command(['ZREMRANGEBYSCORE', key, min, max]);
    return reply?.integer ?? 0;
  }

  /// Removes all members in a sorted set within the given rank range.
  ///
  /// Returns the number of members removed.
  Future<int> zremrangebyrank(String key, int start, int stop) async {
    final reply = await _command([
      'ZREMRANGEBYRANK',
      key,
      start.toString(),
      stop.toString(),
    ]);
    return reply?.integer ?? 0;
  }

  /// Removes and returns members with the lowest scores from a sorted set.
  Future<List<(String, double)>> zpopmin(String key, {int count = 1}) async {
    final reply = await _command(['ZPOPMIN', key, count.toString()]);
    try {
      final result = <(String, double)>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length - 1; i += 2) {
        final member = reply[i]?.string;
        final scoreStr = reply[i + 1]?.string;
        if (member != null && scoreStr != null) {
          result.add((member, double.parse(scoreStr)));
        }
      }
      return result;
    } finally {}
  }

  /// Removes and returns members with the highest scores from a sorted set.
  Future<List<(String, double)>> zpopmax(String key, {int count = 1}) async {
    final reply = await _command(['ZPOPMAX', key, count.toString()]);
    try {
      final result = <(String, double)>[];
      if (reply == null) return result;

      for (var i = 0; i < reply.length - 1; i += 2) {
        final member = reply[i]?.string;
        final scoreStr = reply[i + 1]?.string;
        if (member != null && scoreStr != null) {
          result.add((member, double.parse(scoreStr)));
        }
      }
      return result;
    } finally {}
  }

  /// Computes the union of multiple sorted sets and stores the result.
  ///
  /// Returns the number of members in the resulting set.
  Future<int> zunionstore(
    String destination,
    List<String> keys, {
    List<double>? weights,
    String? aggregate,
  }) async {
    final args = ['ZUNIONSTORE', destination, keys.length.toString(), ...keys];
    if (weights != null) {
      args.add('WEIGHTS');
      args.addAll(weights.map((w) => w.toString()));
    }
    if (aggregate != null) {
      args.addAll(['AGGREGATE', aggregate]);
    }

    final reply = await _command(args);
    return reply?.integer ?? 0;
  }

  /// Computes the intersection of multiple sorted sets and stores the result.
  ///
  /// Returns the number of members in the resulting set.
  Future<int> zinterstore(
    String destination,
    List<String> keys, {
    List<double>? weights,
    String? aggregate,
  }) async {
    final args = ['ZINTERSTORE', destination, keys.length.toString(), ...keys];
    if (weights != null) {
      args.add('WEIGHTS');
      args.addAll(weights.map((w) => w.toString()));
    }
    if (aggregate != null) {
      args.addAll(['AGGREGATE', aggregate]);
    }

    final reply = await _command(args);
    return reply?.integer ?? 0;
  }

  /// Incrementally iterates over members and scores in a sorted set.
  ///
  /// Returns a tuple of (nextCursor, memberScorePairs).
  /// When nextCursor is '0', iteration is complete.
  Future<(String, List<(String, double)>)> zscan(
    String key,
    String cursor, {
    String? match,
    int? count,
  }) async {
    final args = ['ZSCAN', key, cursor];
    if (match != null) args.addAll(['MATCH', match]);
    if (count != null) args.addAll(['COUNT', count.toString()]);

    final reply = await _command(args);
    try {
      if (reply == null || reply.length < 2) {
        return ('0', <(String, double)>[]);
      }

      final nextCursor = reply[0]?.string ?? '0';
      final itemsReply = reply[1];
      final result = <(String, double)>[];
      if (itemsReply != null) {
        for (var i = 0; i < itemsReply.length - 1; i += 2) {
          final member = itemsReply[i]?.string;
          final scoreStr = itemsReply[i + 1]?.string;
          if (member != null && scoreStr != null) {
            result.add((member, double.parse(scoreStr)));
          }
        }
      }
      return (nextCursor, result);
    } finally {}
  }

  // ============ Pub/Sub API ============

  /// Subscribes to channels and/or patterns and returns a stream of messages.
  ///
  /// Each call to [subscribe] opens a dedicated Redis connection for the
  /// subscription. The connection is opened when you call `listen()` on the
  /// returned stream, and closed when you cancel the subscription.
  ///
  /// **Performance considerations:**
  /// - Each [subscribe] call creates a new TCP connection to Redis.
  /// - Prefer a single [subscribe] call with multiple channels over multiple
  ///   calls, as this uses fewer connections.
  /// - Pattern matching ([patterns]) has a server-side cost: Redis checks
  ///   every published message against all active patterns. Use exact channel
  ///   names when possible for high-throughput scenarios.
  ///
  /// At least one of [channels] or [patterns] must be non-empty.
  ///
  /// Example:
  /// ```dart
  /// final subscription = client.subscribe(
  ///   channels: ['news', 'alerts'],
  ///   patterns: ['user:*'],
  /// ).listen((msg) {
  ///   print('${msg.channel}: ${msg.message}');
  /// });
  /// // Later:
  /// await subscription.cancel();
  /// ```
  Stream<RedisPubSubMessage> subscribe({
    Iterable<String> channels = const [],
    Iterable<String> patterns = const [],
  }) {
    _checkNotClosed();
    final channelList = channels.toList();
    final patternList = patterns.toList();
    if (channelList.isEmpty && patternList.isEmpty) {
      throw ArgumentError('At least one channel or pattern must be specified');
    }
    return _RedisSubscription.create(_host, _port, channelList, patternList);
  }

  /// Publishes a message to a channel.
  Future<int> publish(String channel, String message) async {
    final reply = await _command(['PUBLISH', channel, message]);
    return reply?.integer ?? 0;
  }

  /// Closes the connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    // Complete any pending commands with errors
    for (final completer in _pendingCommands.values) {
      completer.completeError(RedisException('Client closed'));
    }
    _pendingCommands.clear();

    // Stop and destroy the event loop (this also frees the async context)
    redis_event_loop_destroy(_eventLoop);

    // Close the receive port
    _receivePort.close();
  }
}

// ============ Redis Subscription ============

/// A subscription that manages its own Redis connection.
class _RedisSubscription {
  final Pointer<EventLoopState> _eventLoop;
  final ReceivePort _receivePort;
  var _closed = false;
  var _nextCommandId = 0;

  _RedisSubscription._(this._eventLoop, this._receivePort);

  /// Creates a subscription stream that opens a dedicated connection.
  static Stream<RedisPubSubMessage> create(
    String host,
    int port,
    List<String> channels,
    List<String> patterns,
  ) {
    late StreamController<RedisPubSubMessage> controller;
    _RedisSubscription? subscription;

    controller = StreamController<RedisPubSubMessage>(
      onListen: () {
        try {
          final options = calloc<redisOptions>();
          try {
            // Zero-initialize
            for (var i = 0; i < sizeOf<redisOptions>(); i++) {
              options.cast<Uint8>()[i] = 0;
            }

            final hostPtr = host.toNativeUtf8();
            try {
              options.ref.type = redisConnectionType.REDIS_CONN_TCP.value;
              options.ref.endpoint.tcp.ip = hostPtr.cast();
              options.ref.endpoint.tcp.port = port;
              options.ref.options = REDIS_OPT_NOAUTOFREE;

              final ctx = redisAsyncConnectWithOptions(options);
              if (ctx == nullptr) {
                controller.addError(
                  RedisException('Failed to allocate async context'),
                );
                return;
              }

              if (ctx.ref.err != 0) {
                final errStr = ctx.ref.errstr.cast<Utf8>().toDartString();
                redisAsyncFree(ctx);
                controller.addError(
                  RedisException('Connection failed: $errStr'),
                );
                return;
              }

              final receivePort = ReceivePort();
              final eventLoop = redis_event_loop_create(
                ctx,
                receivePort.sendPort.nativePort,
              );

              if (eventLoop == nullptr) {
                receivePort.close();
                redisAsyncFree(ctx);
                controller.addError(
                  RedisException('Failed to create event loop'),
                );
                return;
              }

              subscription = _RedisSubscription._(eventLoop, receivePort);

              // Listen for pub/sub messages
              receivePort.listen((message) {
                if (subscription?._closed ?? true) return;
                if (controller.isClosed) return;
                if (message is int && message == -1) {
                  // Disconnect
                  controller.addError(RedisException('Connection lost'));
                  return;
                }
                if (message is List && message.length == 2) {
                  final replyData = message[1];
                  final pubsubMsg = _parsePubSubMessage(replyData);
                  if (pubsubMsg != null) {
                    controller.add(pubsubMsg);
                  }
                }
              });

              if (!redis_event_loop_start(eventLoop)) {
                receivePort.close();
                redis_event_loop_destroy(eventLoop);
                redisAsyncFree(ctx);
                controller.addError(
                  RedisException('Failed to start event loop'),
                );
                return;
              }

              // Send SUBSCRIBE and PSUBSCRIBE commands
              subscription!._sendSubscribeCommand('SUBSCRIBE', channels);
              subscription!._sendSubscribeCommand('PSUBSCRIBE', patterns);
            } finally {
              calloc.free(hostPtr);
            }
          } finally {
            calloc.free(options);
          }
        } catch (e) {
          controller.addError(e);
        }
      },
      onCancel: () async {
        subscription?._close();
        await controller.close();
      },
    );

    return controller.stream;
  }

  /// Parses a pub/sub message from the serialized reply data.
  static RedisPubSubMessage? _parsePubSubMessage(dynamic data) {
    final reply = _ParsedReply.fromNative(data);
    if (reply == null || reply.elements == null || reply.elements!.length < 3) {
      return null;
    }

    final typeElem = reply[0];
    if (typeElem == null ||
        typeElem.type != _redisReplyString ||
        typeElem.string == null) {
      return null;
    }

    final typeStr = typeElem.string!;
    final type = switch (typeStr) {
      'message' => RedisPubSubMessageType.message,
      'pmessage' => RedisPubSubMessageType.pmessage,
      'subscribe' => RedisPubSubMessageType.subscribe,
      'unsubscribe' => RedisPubSubMessageType.unsubscribe,
      'psubscribe' => RedisPubSubMessageType.psubscribe,
      'punsubscribe' => RedisPubSubMessageType.punsubscribe,
      _ => null,
    };

    if (type == null) return null;

    String channel = '';
    String? message;
    String? pattern;

    if (type == RedisPubSubMessageType.pmessage &&
        reply.elements!.length >= 4) {
      pattern = reply[1]?.string;
      channel = reply[2]?.string ?? '';
      message = reply[3]?.string;
    } else if (type == RedisPubSubMessageType.message &&
        reply.elements!.length >= 3) {
      channel = reply[1]?.string ?? '';
      message = reply[2]?.string;
    } else if (reply.elements!.length >= 2) {
      channel = reply[1]?.string ?? '';
    }

    return RedisPubSubMessage._(
      type: type,
      channel: channel,
      message: message,
      pattern: pattern,
    );
  }

  void _sendSubscribeCommand(String cmd, List<String> targets) {
    if (targets.isEmpty) return;

    final commandId = _nextCommandId++;
    final argc = targets.length + 1;
    final argv = calloc<Pointer<Char>>(argc);
    final argvlen = calloc<Size>(argc);

    try {
      final cmdPtr = cmd.toNativeUtf8();
      argv[0] = cmdPtr.cast();
      argvlen[0] = cmd.length;

      for (var i = 0; i < targets.length; i++) {
        final arg = targets[i].toNativeUtf8();
        argv[i + 1] = arg.cast();
        argvlen[i + 1] = targets[i].length;
      }

      // Use pubsub command for persistent callbacks
      redis_async_pubsub_command(
        _eventLoop,
        _receivePort.sendPort.nativePort,
        commandId,
        argc,
        argv,
        argvlen,
      );
    } finally {
      for (var i = 0; i < argc; i++) {
        if (argv[i] != nullptr) {
          calloc.free(argv[i].cast<Utf8>());
        }
      }
      calloc.free(argv);
      calloc.free(argvlen);
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;

    // Destroy the event loop (this also frees the async context)
    redis_event_loop_destroy(_eventLoop);
    _receivePort.close();
  }
}
