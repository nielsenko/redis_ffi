import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'hiredis_bindings.g.dart';
import 'redis_reply.dart';

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
///
/// String fields are lazily converted from the native reply to avoid
/// unnecessary UTF-8 decoding if the fields are not accessed.
class RedisPubSubMessage {
  /// The type of message.
  final RedisPubSubMessageType type;

  /// The channel the message was received on.
  final String channel;

  // Lazy message field
  final Pointer<Char>? _messagePtr;
  final int _messageLen;
  String? _message;
  bool _messageConverted = false;

  // Lazy pattern field
  final Pointer<Char>? _patternPtr;
  final int _patternLen;
  String? _pattern;
  bool _patternConverted = false;

  /// The message payload (null for subscribe/unsubscribe confirmations).
  String? get message {
    if (!_messageConverted) {
      _messageConverted = true;
      if (_messagePtr != null) {
        _message = _messagePtr!.cast<Utf8>().toDartString(length: _messageLen);
      }
    }
    return _message;
  }

  /// The pattern that matched (for pmessage type only).
  String? get pattern {
    if (!_patternConverted) {
      _patternConverted = true;
      if (_patternPtr != null) {
        _pattern = _patternPtr.cast<Utf8>().toDartString(length: _patternLen);
      }
    }
    return _pattern;
  }

  RedisPubSubMessage._({
    required this.type,
    required this.channel,
    Pointer<Char>? messagePtr,
    int messageLen = 0,
    Pointer<Char>? patternPtr,
    int patternLen = 0,
  }) : _messagePtr = messagePtr,
       _messageLen = messageLen,
       _patternPtr = patternPtr,
       _patternLen = patternLen;

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
  final HiredisBindings _bindings;
  final Pointer<redisAsyncContext> _ctx;
  final Pointer<Bool> _stopFlag;
  final NativeCallable<
    Void Function(Pointer<redisAsyncContext>, Pointer<Void>, Pointer<Void>)
  >
  _replyCallback;
  Pointer<LoopThreadHandle>? _loopThreadHandle;

  final _pendingCommands = <int, Completer<RedisReply?>>{};
  final _pendingCallbacks = <int, int>{}; // privdata -> commandId
  var _nextCommandId = 0;
  var _nextPrivdata = 1;
  var _closed = false;

  RedisClient._(
    this._host,
    this._port,
    this._bindings,
    this._ctx,
    this._stopFlag,
    this._replyCallback,
    this._loopThreadHandle,
  );

  /// Opens the hiredis dynamic library.
  static DynamicLibrary _openLibrary() {
    final libName = _getLibraryName();

    // Try standard library loading first (works when bundled by build hooks)
    try {
      return DynamicLibrary.open(libName);
    } on ArgumentError {
      // Fall through to search paths
    }

    // Search in known locations (for development/testing)
    final searchPaths = _getSearchPaths(libName);
    for (final path in searchPaths) {
      final file = File(path);
      if (file.existsSync()) {
        return DynamicLibrary.open(path);
      }
    }

    throw UnsupportedError(
      'Could not find $libName. Searched: ${searchPaths.join(", ")}',
    );
  }

  static String _getLibraryName() {
    if (Platform.isMacOS) {
      return 'libhiredis.dylib';
    } else if (Platform.isLinux || Platform.isAndroid) {
      return 'libhiredis.so';
    } else if (Platform.isWindows) {
      return 'hiredis.dll';
    } else {
      throw UnsupportedError(
        'Unsupported platform: ${Platform.operatingSystem}',
      );
    }
  }

  static List<String> _getSearchPaths(String libName) {
    final paths = <String>[];

    // Get the package root by finding pubspec.yaml
    var dir = Directory.current;
    while (dir.path != dir.parent.path) {
      final pubspec = File('${dir.path}/pubspec.yaml');
      if (pubspec.existsSync()) {
        final arch = _getArch();
        final os = _getOS();
        // Prebuilt location
        paths.add('${dir.path}/native/lib/$os-$arch/lib/$libName');
        // Zig build output
        paths.add('${dir.path}/native/zig-out/lib/$libName');
        // Dart tool location (from build hooks)
        paths.add('${dir.path}/.dart_tool/lib/$libName');
        break;
      }
      dir = dir.parent;
    }

    return paths;
  }

  static String _getArch() {
    // Use Dart's sizeOf to detect architecture
    final pointerSize = sizeOf<IntPtr>();
    if (pointerSize == 8) {
      // Check for ARM64 on macOS
      if (Platform.isMacOS) {
        final result = Process.runSync('uname', ['-m']);
        if (result.stdout.toString().trim() == 'arm64') {
          return 'arm64';
        }
      }
      return 'x64';
    }
    return 'x86';
  }

  static String _getOS() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  /// Connects to a Redis server.
  ///
  /// Returns a [Future] that completes with the connected client.
  static Future<RedisClient> connect(String host, int port) async {
    final dylib = _openLibrary();
    final bindings = HiredisBindings(dylib);

    // Set up connection options
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

        // Dart controls memory lifetime
        options.ref.options =
            REDIS_OPT_NOAUTOFREE |
            REDIS_OPT_NOAUTOFREEREPLIES |
            REDIS_OPT_NO_PUSH_AUTOFREE;

        final ctx = bindings.redisAsyncConnectWithOptions(options);
        if (ctx == nullptr) {
          throw RedisException('Failed to allocate async context');
        }

        if (ctx.ref.err != 0) {
          final errStr = _extractErrorString(ctx.ref.errstr);
          bindings.redisAsyncFree(ctx);
          throw RedisException('Connection failed: $errStr');
        }

        // Allocate stop flag for the I/O loop thread
        final stopFlag = calloc<Bool>();
        stopFlag.value = false;

        // Create the client first (needed for callback closure)
        late final RedisClient client;

        // Reply callback - called by hiredis when a command completes
        void onReply(
          Pointer<redisAsyncContext> ac,
          Pointer<Void> replyPtr,
          Pointer<Void> privdata,
        ) {
          if (client._closed) return;

          final privdataValue = privdata.address;
          final commandId = client._pendingCallbacks.remove(privdataValue);

          if (commandId == null) return;

          final completer = client._pendingCommands.remove(commandId);
          if (completer == null) return;

          if (replyPtr == nullptr) {
            completer.completeError(RedisException('Null reply'));
            return;
          }

          completer.complete(RedisReply.fromPointer(bindings, dylib, replyPtr));
        }

        final replyCallback =
            NativeCallable<
              Void Function(
                Pointer<redisAsyncContext>,
                Pointer<Void>,
                Pointer<Void>,
              )
            >.listener(onReply);

        // Start the I/O loop on a background thread
        final loopThreadHandle = bindings.redis_async_start_loop_thread(
          ctx,
          stopFlag,
        );

        if (loopThreadHandle == nullptr) {
          replyCallback.close();
          calloc.free(stopFlag);
          bindings.redisAsyncFree(ctx);
          throw RedisException('Failed to start I/O loop thread');
        }

        client = RedisClient._(
          host,
          port,
          bindings,
          ctx,
          stopFlag,
          replyCallback,
          loopThreadHandle,
        );

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

  /// Sends a raw command and returns the reply.
  Future<RedisReply?> command(List<String> args) async {
    _checkNotClosed();

    final commandId = _nextCommandId++;
    final completer = Completer<RedisReply?>();
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

      final privdata = _nextPrivdata++;
      _pendingCallbacks[privdata] = commandId;

      _bindings.redisAsyncCommandArgv(
        _ctx,
        _replyCallback.nativeFunction.cast(),
        Pointer<Void>.fromAddress(privdata),
        argc,
        argv,
        argvlen,
      );

      // Flush to send the command immediately
      _bindings.redis_async_flush(_ctx);
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

  /// Pings the server.
  Future<String> ping([String? message]) async {
    final reply = await command(message != null ? ['PING', message] : ['PING']);
    try {
      return reply?.string ?? 'PONG';
    } finally {
      reply?.free();
    }
  }

  // ============ String Commands ============

  /// Gets the value of a key.
  ///
  /// Returns `null` if the key does not exist.
  Future<String?> get(String key) async {
    final reply = await command(['GET', key]);
    try {
      return reply?.string;
    } finally {
      reply?.free();
    }
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

    final reply = await command(args);
    try {
      return reply?.string;
    } finally {
      reply?.free();
    }
  }

  /// Gets the values of multiple keys.
  ///
  /// Returns a list of values in the same order as the keys.
  /// Non-existent keys return `null`.
  Future<List<String?>> mget(List<String> keys) async {
    final reply = await command(['MGET', ...keys]);
    try {
      if (reply == null) return List.filled(keys.length, null);
      final results = <String?>[];
      for (var i = 0; i < reply.length; i++) {
        results.add(reply[i]?.string);
      }
      return results;
    } finally {
      reply?.free();
    }
  }

  /// Sets multiple keys to their respective values.
  Future<void> mset(Map<String, String> keyValues) async {
    final args = ['MSET'];
    keyValues.forEach((key, value) {
      args.addAll([key, value]);
    });
    final reply = await command(args);
    reply?.free();
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
    final reply = await command(args);
    try {
      return (reply?.integer ?? 0) == 1;
    } finally {
      reply?.free();
    }
  }

  /// Increments the integer value of a key by one.
  ///
  /// Returns the new value after incrementing.
  Future<int> incr(String key) async {
    final reply = await command(['INCR', key]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Increments the integer value of a key by the given amount.
  ///
  /// Returns the new value after incrementing.
  Future<int> incrby(String key, int increment) async {
    final reply = await command(['INCRBY', key, increment.toString()]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Increments the floating point value of a key by the given amount.
  ///
  /// Returns the new value after incrementing.
  Future<double> incrbyfloat(String key, double increment) async {
    final reply = await command(['INCRBYFLOAT', key, increment.toString()]);
    try {
      final str = reply?.string;
      return str != null ? double.parse(str) : 0.0;
    } finally {
      reply?.free();
    }
  }

  /// Decrements the integer value of a key by one.
  ///
  /// Returns the new value after decrementing.
  Future<int> decr(String key) async {
    final reply = await command(['DECR', key]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Decrements the integer value of a key by the given amount.
  ///
  /// Returns the new value after decrementing.
  Future<int> decrby(String key, int decrement) async {
    final reply = await command(['DECRBY', key, decrement.toString()]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Appends a value to a key.
  ///
  /// Returns the length of the string after the append.
  Future<int> append(String key, String value) async {
    final reply = await command(['APPEND', key, value]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Returns the length of the string stored at key.
  Future<int> strlen(String key) async {
    final reply = await command(['STRLEN', key]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Sets or clears the bit at offset in the string value stored at key.
  ///
  /// Returns the original bit value at the offset.
  Future<int> setbit(String key, int offset, int value) async {
    final reply = await command([
      'SETBIT',
      key,
      offset.toString(),
      value.toString(),
    ]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Returns the bit value at offset in the string value stored at key.
  Future<int> getbit(String key, int offset) async {
    final reply = await command(['GETBIT', key, offset.toString()]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Overwrites part of the string stored at key starting at the specified offset.
  ///
  /// Returns the length of the string after it was modified.
  Future<int> setrange(String key, int offset, String value) async {
    final reply = await command(['SETRANGE', key, offset.toString(), value]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Returns a substring of the string stored at key.
  Future<String?> getrange(String key, int start, int end) async {
    final reply = await command([
      'GETRANGE',
      key,
      start.toString(),
      end.toString(),
    ]);
    try {
      return reply?.string;
    } finally {
      reply?.free();
    }
  }

  /// Sets the value and expiration of a key in seconds.
  Future<void> setex(String key, int seconds, String value) async {
    final reply = await command(['SETEX', key, seconds.toString(), value]);
    reply?.free();
  }

  /// Sets the value and expiration of a key in milliseconds.
  Future<void> psetex(String key, int milliseconds, String value) async {
    final reply = await command([
      'PSETEX',
      key,
      milliseconds.toString(),
      value,
    ]);
    reply?.free();
  }

  /// Sets the value of a key only if the key does not exist.
  ///
  /// Returns `true` if the key was set, `false` if it already existed.
  Future<bool> setnx(String key, String value) async {
    final reply = await command(['SETNX', key, value]);
    try {
      return (reply?.integer ?? 0) == 1;
    } finally {
      reply?.free();
    }
  }

  /// Atomically sets a key to a value and returns the old value.
  Future<String?> getset(String key, String value) async {
    final reply = await command(['GETSET', key, value]);
    try {
      return reply?.string;
    } finally {
      reply?.free();
    }
  }

  /// Gets the value of a key and deletes it.
  Future<String?> getdel(String key) async {
    final reply = await command(['GETDEL', key]);
    try {
      return reply?.string;
    } finally {
      reply?.free();
    }
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

    final reply = await command(args);
    try {
      return reply?.string;
    } finally {
      reply?.free();
    }
  }

  // ============ Key Commands ============

  /// Deletes one or more keys.
  ///
  /// Returns the number of keys that were deleted.
  Future<int> del(List<String> keys) async {
    final reply = await command(['DEL', ...keys]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Deletes one or more keys asynchronously (non-blocking).
  ///
  /// Returns the number of keys that were scheduled for deletion.
  Future<int> unlink(List<String> keys) async {
    final reply = await command(['UNLINK', ...keys]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Checks if one or more keys exist.
  ///
  /// Returns the number of keys that exist.
  Future<int> existsCount(List<String> keys) async {
    final reply = await command(['EXISTS', ...keys]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Checks if a key exists.
  Future<bool> exists(String key) async {
    return (await existsCount([key])) > 0;
  }

  /// Sets a timeout on a key in seconds.
  ///
  /// Returns `true` if the timeout was set, `false` if the key doesn't exist.
  Future<bool> expire(String key, int seconds) async {
    final reply = await command(['EXPIRE', key, seconds.toString()]);
    try {
      return (reply?.integer ?? 0) == 1;
    } finally {
      reply?.free();
    }
  }

  /// Sets a timeout on a key in milliseconds.
  ///
  /// Returns `true` if the timeout was set, `false` if the key doesn't exist.
  Future<bool> pexpire(String key, int milliseconds) async {
    final reply = await command(['PEXPIRE', key, milliseconds.toString()]);
    try {
      return (reply?.integer ?? 0) == 1;
    } finally {
      reply?.free();
    }
  }

  /// Sets an absolute Unix timestamp expiry on a key (in seconds).
  ///
  /// Returns `true` if the timeout was set, `false` if the key doesn't exist.
  Future<bool> expireat(String key, int timestamp) async {
    final reply = await command(['EXPIREAT', key, timestamp.toString()]);
    try {
      return (reply?.integer ?? 0) == 1;
    } finally {
      reply?.free();
    }
  }

  /// Sets an absolute Unix timestamp expiry on a key (in milliseconds).
  ///
  /// Returns `true` if the timeout was set, `false` if the key doesn't exist.
  Future<bool> pexpireat(String key, int timestamp) async {
    final reply = await command(['PEXPIREAT', key, timestamp.toString()]);
    try {
      return (reply?.integer ?? 0) == 1;
    } finally {
      reply?.free();
    }
  }

  /// Gets the remaining time to live of a key in seconds.
  ///
  /// Returns -2 if the key doesn't exist, -1 if the key has no expiry.
  Future<int> ttl(String key) async {
    final reply = await command(['TTL', key]);
    try {
      return reply?.integer ?? -2;
    } finally {
      reply?.free();
    }
  }

  /// Gets the remaining time to live of a key in milliseconds.
  ///
  /// Returns -2 if the key doesn't exist, -1 if the key has no expiry.
  Future<int> pttl(String key) async {
    final reply = await command(['PTTL', key]);
    try {
      return reply?.integer ?? -2;
    } finally {
      reply?.free();
    }
  }

  /// Removes the expiry from a key.
  ///
  /// Returns `true` if the timeout was removed, `false` if the key doesn't
  /// exist or has no associated timeout.
  Future<bool> persist(String key) async {
    final reply = await command(['PERSIST', key]);
    try {
      return (reply?.integer ?? 0) == 1;
    } finally {
      reply?.free();
    }
  }

  /// Returns the absolute Unix timestamp (in seconds) at which the key will expire.
  ///
  /// Returns -2 if the key doesn't exist, -1 if the key has no expiry.
  Future<int> expiretime(String key) async {
    final reply = await command(['EXPIRETIME', key]);
    try {
      return reply?.integer ?? -2;
    } finally {
      reply?.free();
    }
  }

  /// Returns the absolute Unix timestamp (in milliseconds) at which the key will expire.
  ///
  /// Returns -2 if the key doesn't exist, -1 if the key has no expiry.
  Future<int> pexpiretime(String key) async {
    final reply = await command(['PEXPIRETIME', key]);
    try {
      return reply?.integer ?? -2;
    } finally {
      reply?.free();
    }
  }

  /// Returns the type of the value stored at key.
  ///
  /// Returns "none" if the key doesn't exist.
  Future<String> type(String key) async {
    final reply = await command(['TYPE', key]);
    try {
      return reply?.string ?? 'none';
    } finally {
      reply?.free();
    }
  }

  /// Renames a key.
  ///
  /// Throws if the key doesn't exist.
  Future<void> rename(String key, String newKey) async {
    final reply = await command(['RENAME', key, newKey]);
    reply?.free();
  }

  /// Renames a key only if the new key doesn't already exist.
  ///
  /// Returns `true` if the key was renamed, `false` if the new key already exists.
  Future<bool> renamenx(String key, String newKey) async {
    final reply = await command(['RENAMENX', key, newKey]);
    try {
      return (reply?.integer ?? 0) == 1;
    } finally {
      reply?.free();
    }
  }

  /// Returns all keys matching the given pattern.
  ///
  /// Warning: KEYS should not be used in production as it may block the server.
  /// Use [scan] instead for production workloads.
  Future<List<String>> keys(String pattern) async {
    final reply = await command(['KEYS', pattern]);
    try {
      if (reply == null) return [];
      final results = <String>[];
      for (var i = 0; i < reply.length; i++) {
        final key = reply[i]?.string;
        if (key != null) results.add(key);
      }
      return results;
    } finally {
      reply?.free();
    }
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

    final reply = await command(args);
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
    } finally {
      reply?.free();
    }
  }

  /// Returns a random key from the database.
  Future<String?> randomkey() async {
    final reply = await command(['RANDOMKEY']);
    try {
      return reply?.string;
    } finally {
      reply?.free();
    }
  }

  /// Touches one or more keys (updates last access time).
  ///
  /// Returns the number of keys that were touched.
  Future<int> touch(List<String> keys) async {
    final reply = await command(['TOUCH', ...keys]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Returns the number of bytes that a key and its value require in RAM.
  Future<int?> memoryUsage(String key, {int? samples}) async {
    final args = ['MEMORY', 'USAGE', key];
    if (samples != null) args.addAll(['SAMPLES', samples.toString()]);

    final reply = await command(args);
    try {
      return reply?.integer;
    } finally {
      reply?.free();
    }
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

    final reply = await command(args);
    try {
      return (reply?.integer ?? 0) == 1;
    } finally {
      reply?.free();
    }
  }

  /// Returns the time since the object stored at key is idle.
  Future<int?> objectIdletime(String key) async {
    final reply = await command(['OBJECT', 'IDLETIME', key]);
    try {
      return reply?.integer;
    } finally {
      reply?.free();
    }
  }

  /// Returns the access frequency of the object stored at key.
  Future<int?> objectFreq(String key) async {
    final reply = await command(['OBJECT', 'FREQ', key]);
    try {
      return reply?.integer;
    } finally {
      reply?.free();
    }
  }

  /// Returns the encoding of the object stored at key.
  Future<String?> objectEncoding(String key) async {
    final reply = await command(['OBJECT', 'ENCODING', key]);
    try {
      return reply?.string;
    } finally {
      reply?.free();
    }
  }

  /// Executes multiple commands in a pipeline.
  ///
  /// All commands are sent at once, and results are returned in order.
  Future<List<RedisReply?>> pipeline(List<List<String>> commands) async {
    _checkNotClosed();

    final futures = <Future<RedisReply?>>[];
    for (final cmd in commands) {
      futures.add(command(cmd));
    }

    return Future.wait(futures);
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
    final reply = await command(['PUBLISH', channel, message]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
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
    _pendingCallbacks.clear();

    // Signal the I/O loop to stop
    _stopFlag.value = true;

    // Stop the background thread and wait for it to exit
    if (_loopThreadHandle != null) {
      _bindings.redis_async_stop_loop_thread(_loopThreadHandle!);
      _loopThreadHandle = null;
    }

    // Free resources
    _bindings.redisAsyncFree(_ctx);
    _replyCallback.close();
    calloc.free(_stopFlag);
  }
}

// ============ Redis Subscription ============

/// A subscription that manages its own Redis connection.
class _RedisSubscription {
  final HiredisBindings _bindings;
  final Pointer<redisAsyncContext> _ctx;
  final Pointer<Bool> _stopFlag;
  final NativeCallable<
    Void Function(Pointer<redisAsyncContext>, Pointer<Void>, Pointer<Void>)
  >
  _replyCallback;
  Pointer<LoopThreadHandle>? _loopThreadHandle;
  var _closed = false;

  _RedisSubscription._(
    this._bindings,
    this._ctx,
    this._stopFlag,
    this._replyCallback,
    this._loopThreadHandle,
  );

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
          final dylib = RedisClient._openLibrary();
          final bindings = HiredisBindings(dylib);

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
              options.ref.options =
                  REDIS_OPT_NOAUTOFREE |
                  REDIS_OPT_NOAUTOFREEREPLIES |
                  REDIS_OPT_NO_PUSH_AUTOFREE;

              final ctx = bindings.redisAsyncConnectWithOptions(options);
              if (ctx == nullptr) {
                controller.addError(
                  RedisException('Failed to allocate async context'),
                );
                return;
              }

              if (ctx.ref.err != 0) {
                final errStr = ctx.ref.errstr.cast<Utf8>().toDartString();
                bindings.redisAsyncFree(ctx);
                controller.addError(
                  RedisException('Connection failed: $errStr'),
                );
                return;
              }

              final stopFlag = calloc<Bool>();
              stopFlag.value = false;

              // Reply callback
              void onReply(
                Pointer<redisAsyncContext> ac,
                Pointer<Void> replyPtr,
                Pointer<Void> privdata,
              ) {
                if (subscription?._closed ?? true) return;
                if (controller.isClosed) return;
                if (replyPtr == nullptr) return;

                final reply = replyPtr.cast<redisReply>();

                if (reply.ref.type != REDIS_REPLY_ARRAY ||
                    reply.ref.elements < 3) {
                  return;
                }
                final firstElem = reply.ref.element[0];
                if (firstElem.ref.type != REDIS_REPLY_STRING) {
                  return;
                }
                final type = _parseMessageType(
                  firstElem.ref.str,
                  firstElem.ref.len,
                );
                final msg = _createPubSubMessage(reply, type);
                controller.add(msg);
              }

              final replyCallback =
                  NativeCallable<
                    Void Function(
                      Pointer<redisAsyncContext>,
                      Pointer<Void>,
                      Pointer<Void>,
                    )
                  >.listener(onReply);

              final loopThreadHandle = bindings.redis_async_start_loop_thread(
                ctx,
                stopFlag,
              );

              if (loopThreadHandle == nullptr) {
                replyCallback.close();
                calloc.free(stopFlag);
                bindings.redisAsyncFree(ctx);
                controller.addError(
                  RedisException('Failed to start I/O loop thread'),
                );
                return;
              }

              subscription = _RedisSubscription._(
                bindings,
                ctx,
                stopFlag,
                replyCallback,
                loopThreadHandle,
              );

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

  void _sendSubscribeCommand(String cmd, List<String> targets) {
    if (targets.isEmpty) return;

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

      _bindings.redisAsyncCommandArgv(
        _ctx,
        _replyCallback.nativeFunction.cast(),
        nullptr,
        argc,
        argv,
        argvlen,
      );

      _bindings.redis_async_flush(_ctx);
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

    _stopFlag.value = true;

    if (_loopThreadHandle != null) {
      _bindings.redis_async_stop_loop_thread(_loopThreadHandle!);
      _loopThreadHandle = null;
    }

    _bindings.redisAsyncFree(_ctx);
    _replyCallback.close();
    calloc.free(_stopFlag);
  }
}

// ============ Helper functions ============

/// Compares a C string pointer against an ASCII string without allocation.
bool _cStrEquals(Pointer<Char> cstr, int len, String ascii) {
  if (len != ascii.length) return false;
  for (var i = 0; i < len; i++) {
    if (cstr[i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

/// Parses a pub/sub message type from a C string.
/// Since all message type lengths are unique, we only verify content in debug mode.
RedisPubSubMessageType _parseMessageType(Pointer<Char> str, int len) {
  RedisPubSubMessageType type = switch (len) {
    7 => .message,
    8 => .pmessage,
    9 => .subscribe,
    10 => .psubscribe,
    11 => .unsubscribe,
    12 => .punsubscribe,
    _ => throw StateError('Unknown pub/sub message type with length $len'),
  };
  assert(_cStrEquals(str, len, type.name));
  return type;
}

/// Creates a RedisPubSubMessage from a redisReply with lazy string conversion.
RedisPubSubMessage _createPubSubMessage(
  Pointer<redisReply> reply,
  RedisPubSubMessageType type,
) {
  // Channel is always eagerly converted since it's typically accessed
  String channel = '';
  Pointer<Char>? messagePtr;
  int messageLen = 0;
  Pointer<Char>? patternPtr;
  int patternLen = 0;

  if (type == .pmessage && reply.ref.elements >= 4) {
    final patternElem = reply.ref.element[1];
    patternPtr = patternElem.ref.str;
    patternLen = patternElem.ref.len;
    channel = reply.ref.element[2].ref.str.cast<Utf8>().toDartString();
    final msgElem = reply.ref.element[3];
    messagePtr = msgElem.ref.str;
    messageLen = msgElem.ref.len;
  } else if (type == .message && reply.ref.elements >= 3) {
    channel = reply.ref.element[1].ref.str.cast<Utf8>().toDartString();
    final msgElem = reply.ref.element[2];
    messagePtr = msgElem.ref.str;
    messageLen = msgElem.ref.len;
  } else if (reply.ref.elements >= 2) {
    channel = reply.ref.element[1].ref.str.cast<Utf8>().toDartString();
  }

  return RedisPubSubMessage._(
    type: type,
    channel: channel,
    messagePtr: messagePtr,
    messageLen: messageLen,
    patternPtr: patternPtr,
    patternLen: patternLen,
  );
}
