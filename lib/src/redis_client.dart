import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

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

/// A message received from a Redis pub/sub subscription.
class RedisPubSubMessage {
  /// The type of message ('message', 'pmessage', 'subscribe', etc.)
  final String type;

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
  final HiredisBindings _bindings;
  final DynamicLibrary _dylib;
  final SendPort _commandPort;
  final Isolate _pollIsolate;
  final ReceivePort _replyPort;
  late final StreamSubscription<dynamic> _replySubscription;

  final _pendingCommands = <int, Completer<RedisReply?>>{};
  final _pubsubController = StreamController<RedisPubSubMessage>.broadcast();
  var _nextCommandId = 0;
  var _closed = false;

  RedisClient._(
    this._bindings,
    this._dylib,
    this._commandPort,
    this._pollIsolate,
    this._replyPort,
  ) {
    _replySubscription = _replyPort.listen(_handleReply);
  }

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
    final options = calloc<redictOptions>();
    try {
      // Zero-initialize
      for (var i = 0; i < sizeOf<redictOptions>(); i++) {
        options.cast<Uint8>()[i] = 0;
      }

      final hostPtr = host.toNativeUtf8();
      try {
        options.ref.type = redictConnectionType.REDICT_CONN_TCP.value;
        options.ref.endpoint.tcp.ip = hostPtr.cast();
        options.ref.endpoint.tcp.port = port;

        // Dart controls memory lifetime
        options.ref.options =
            REDICT_OPT_NOAUTOFREE |
            REDICT_OPT_NOAUTOFREEREPLIES |
            REDICT_OPT_NO_PUSH_AUTOFREE;

        final ctx = bindings.redictAsyncConnectWithOptions(options);
        if (ctx == nullptr) {
          throw RedisException('Failed to allocate async context');
        }

        if (ctx.ref.err != 0) {
          final errStr = _extractErrorString(ctx.ref.errstr);
          bindings.redictAsyncFree(ctx);
          throw RedisException('Connection failed: $errStr');
        }

        // Create ports for isolate communication
        final replyPort = ReceivePort();
        final initPort = ReceivePort();

        // Start the polling isolate
        final isolate = await Isolate.spawn(
          _pollIsolateEntry,
          _PollIsolateArgs(
            ctxAddress: ctx.address,
            replyPort: replyPort.sendPort,
            initPort: initPort.sendPort,
          ),
        );

        // Wait for the isolate to send us its command port
        final commandPort = await initPort.first as SendPort;
        initPort.close();

        // Set up reply handling
        final client = RedisClient._(
          bindings,
          dylib,
          commandPort,
          isolate,
          replyPort,
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

  void _handleReply(dynamic message) {
    if (message is _ReplyMessage) {
      final completer = _pendingCommands.remove(message.commandId);
      if (completer != null) {
        if (message.replyAddress != 0) {
          final replyPtr = Pointer<redictReply>.fromAddress(
            message.replyAddress,
          );
          final reply = RedisReply.fromPointer(
            _bindings,
            _dylib,
            replyPtr.cast(),
          );
          completer.complete(reply);
        } else if (message.error != null) {
          completer.completeError(RedisException(message.error!));
        } else {
          completer.complete(null);
        }
      }
    } else if (message is _PubSubMessage) {
      _handlePubSubMessage(message);
    }
  }

  void _handlePubSubMessage(_PubSubMessage message) {
    final pubsubMsg = RedisPubSubMessage._(
      type: message.type,
      channel: message.channel,
      message: message.payload,
      pattern: message.pattern,
    );
    _pubsubController.add(pubsubMsg);
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

    _commandPort.send(_CommandMessage(commandId, args));

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

  /// Gets the value of a key.
  Future<String?> get(String key) async {
    final reply = await command(['GET', key]);
    try {
      return reply?.string;
    } finally {
      reply?.free();
    }
  }

  /// Sets a key to a value.
  Future<void> set(String key, String value) async {
    final reply = await command(['SET', key, value]);
    reply?.free();
  }

  /// Deletes keys.
  Future<int> del(List<String> keys) async {
    final reply = await command(['DEL', ...keys]);
    try {
      return reply?.integer ?? 0;
    } finally {
      reply?.free();
    }
  }

  /// Checks if a key exists.
  Future<bool> exists(String key) async {
    final reply = await command(['EXISTS', key]);
    try {
      return (reply?.integer ?? 0) > 0;
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

  /// Stream of pub/sub messages.
  Stream<RedisPubSubMessage> get messages => _pubsubController.stream;

  /// Subscribes to channels.
  Future<void> subscribe(List<String> channels) async {
    final reply = await command(['SUBSCRIBE', ...channels]);
    reply?.free();
  }

  /// Subscribes to patterns.
  Future<void> psubscribe(List<String> patterns) async {
    final reply = await command(['PSUBSCRIBE', ...patterns]);
    reply?.free();
  }

  /// Unsubscribes from channels.
  Future<void> unsubscribe(List<String> channels) async {
    final reply = await command(['UNSUBSCRIBE', ...channels]);
    reply?.free();
  }

  /// Unsubscribes from patterns.
  Future<void> punsubscribe(List<String> patterns) async {
    final reply = await command(['PUNSUBSCRIBE', ...patterns]);
    reply?.free();
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

    // Tell the isolate to stop and clean up (it will free the context)
    _commandPort.send(null);

    // Give the isolate time to clean up
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Clean up on our side
    await _replySubscription.cancel();
    _replyPort.close();
    _pollIsolate.kill();
    await _pubsubController.close();

    // Complete any pending commands with errors
    for (final completer in _pendingCommands.values) {
      completer.completeError(RedisException('Client closed'));
    }
    _pendingCommands.clear();

    // Note: The isolate is responsible for calling redictAsyncFree
    // after closing the NativeCallable
  }
}

// ============ Isolate communication messages ============

class _PollIsolateArgs {
  final int ctxAddress;
  final SendPort replyPort;
  final SendPort initPort;

  _PollIsolateArgs({
    required this.ctxAddress,
    required this.replyPort,
    required this.initPort,
  });
}

class _CommandMessage {
  final int commandId;
  final List<String> args;

  _CommandMessage(this.commandId, this.args);
}

class _ReplyMessage {
  final int commandId;
  final int replyAddress;
  final String? error;

  _ReplyMessage(this.commandId, this.replyAddress, this.error);
}

class _PubSubMessage {
  final String type;
  final String channel;
  final String? payload;
  final String? pattern;

  _PubSubMessage(this.type, this.channel, this.payload, this.pattern);
}

// ============ Poll isolate ============

void _pollIsolateEntry(_PollIsolateArgs args) {
  final dylib = RedisClient._openLibrary();
  final bindings = HiredisBindings(dylib);
  final ctx = Pointer<redictAsyncContext>.fromAddress(args.ctxAddress);

  final commandPort = ReceivePort();
  args.initPort.send(commandPort.sendPort);

  // Map from privdata to command id
  final pendingCallbacks = <int, int>{};
  var nextPrivdata = 1;

  // Create the callback
  void onReply(
    Pointer<redictAsyncContext> ac,
    Pointer<Void> replyPtr,
    Pointer<Void> privdata,
  ) {
    final privdataValue = privdata.address;
    final commandId = pendingCallbacks.remove(privdataValue);

    if (replyPtr == nullptr) {
      if (commandId != null) {
        args.replyPort.send(_ReplyMessage(commandId, 0, 'Null reply'));
      }
      return;
    }

    final reply = replyPtr.cast<redictReply>();

    // Check if this is a pub/sub message
    if (reply.ref.type == REDICT_REPLY_ARRAY && reply.ref.elements >= 3) {
      final firstElem = reply.ref.element[0];
      if (firstElem.ref.type == REDICT_REPLY_STRING) {
        final typeStr = firstElem.ref.str
            .cast<Utf8>()
            .toDartString()
            .toLowerCase();
        if (typeStr == 'message' ||
            typeStr == 'pmessage' ||
            typeStr == 'subscribe' ||
            typeStr == 'unsubscribe' ||
            typeStr == 'psubscribe' ||
            typeStr == 'punsubscribe') {
          _handlePubSubReply(args.replyPort, reply, typeStr, bindings);
          // Also complete the command if there was one
          if (commandId != null) {
            args.replyPort.send(
              _ReplyMessage(commandId, replyPtr.address, null),
            );
          }
          return;
        }
      }
    }

    if (commandId != null) {
      // Send the reply address back - the main isolate will wrap it
      args.replyPort.send(_ReplyMessage(commandId, replyPtr.address, null));
    }
  }

  final callback =
      NativeCallable<
        Void Function(Pointer<redictAsyncContext>, Pointer<Void>, Pointer<Void>)
      >.listener(onReply);

  var running = true;
  Timer? pollTimer;

  void cleanup() {
    running = false;
    pollTimer?.cancel();
    // First disconnect, then free the context.
    // Note: We don't close the callback before freeing because
    // redictAsyncFree may invoke callbacks during cleanup.
    bindings.redictAsyncDisconnect(ctx);
    bindings.redictAsyncFree(ctx);
    callback.close();
    commandPort.close();
  }

  // Listen for commands from main isolate
  commandPort.listen((message) {
    if (message == null) {
      cleanup();
      return;
    }

    if (message is _CommandMessage) {
      final cmdArgs = message.args;
      final argc = cmdArgs.length;
      final argv = calloc<Pointer<Char>>(argc);
      final argvlen = calloc<Size>(argc);

      try {
        for (var i = 0; i < argc; i++) {
          final arg = cmdArgs[i].toNativeUtf8();
          argv[i] = arg.cast();
          argvlen[i] = cmdArgs[i].length;
        }

        // Use privdata to track which command this reply is for
        final privdata = nextPrivdata++;
        pendingCallbacks[privdata] = message.commandId;

        bindings.redictAsyncCommandArgv(
          ctx,
          callback.nativeFunction.cast(),
          Pointer<Void>.fromAddress(privdata),
          argc,
          argv,
          argvlen,
        );

        // Flush to send the command immediately
        bindings.redis_async_flush(ctx);
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
  });

  // Poll loop
  pollTimer = Timer.periodic(const Duration(milliseconds: 1), (_) {
    if (!running) return;
    bindings.redis_async_poll(ctx, 0);
  });
}

void _handlePubSubReply(
  SendPort replyPort,
  Pointer<redictReply> reply,
  String type,
  HiredisBindings bindings,
) {
  String? channel;
  String? payload;
  String? pattern;

  if (type == 'pmessage' && reply.ref.elements >= 4) {
    pattern = reply.ref.element[1].ref.str.cast<Utf8>().toDartString();
    channel = reply.ref.element[2].ref.str.cast<Utf8>().toDartString();
    payload = reply.ref.element[3].ref.str.cast<Utf8>().toDartString();
  } else if (type == 'message' && reply.ref.elements >= 3) {
    channel = reply.ref.element[1].ref.str.cast<Utf8>().toDartString();
    payload = reply.ref.element[2].ref.str.cast<Utf8>().toDartString();
  } else if (reply.ref.elements >= 2) {
    channel = reply.ref.element[1].ref.str.cast<Utf8>().toDartString();
  }

  replyPort.send(_PubSubMessage(type, channel ?? '', payload, pattern));
}
