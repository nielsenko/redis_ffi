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
  final String _host;
  final int _port;
  final HiredisBindings _bindings;
  final DynamicLibrary _dylib;
  final SendPort _commandPort;
  final Isolate _pollIsolate;
  final RawReceivePort _replyPort;

  final _pendingCommands = <int, Completer<RedisReply?>>{};
  var _nextCommandId = 0;
  var _closed = false;

  RedisClient._(
    this._host,
    this._port,
    this._bindings,
    this._dylib,
    this._commandPort,
    this._pollIsolate,
    this._replyPort,
  ) {
    _replyPort.handler = _handleReply;
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

        // Create ports for isolate communication
        final replyPort = RawReceivePort(null, 'replyPort');
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
          host,
          port,
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
          final replyPtr = Pointer<redisReply>.fromAddress(
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
    }
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

    // Tell the isolate to stop and clean up (it will free the context and exit)
    _commandPort.send(null);

    // Give the isolate time to clean up and exit
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Allow the process to exit even if port isn't closed yet
    _replyPort.keepIsolateAlive = false;

    // Close the reply port
    _replyPort.close();

    // Force kill the isolate if it hasn't terminated yet
    _pollIsolate.kill(priority: Isolate.immediate);

    // Note: The isolate is responsible for calling redisAsyncFree
    // after closing the NativeCallable
  }
}

// ============ Redis Subscription ============

/// A subscription stream that manages its own Redis connection.
class _RedisSubscription {
  /// Creates a subscription stream that opens a dedicated connection.
  static Stream<RedisPubSubMessage> create(
    String host,
    int port,
    List<String> channels,
    List<String> patterns,
  ) {
    late StreamController<RedisPubSubMessage> controller;
    RedisClient? client;
    RawReceivePort? replyPort;

    controller = StreamController<RedisPubSubMessage>(
      onListen: () async {
        try {
          // Open a dedicated connection for this subscription
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

              // Set up reply port for this subscription
              replyPort = RawReceivePort(null, 'subscriptionReplyPort')
                ..keepIsolateAlive = false;
              final initPort = ReceivePort();

              // Start the polling isolate
              final isolate = await Isolate.spawn(
                _subscriptionIsolateEntry,
                _SubscriptionIsolateArgs(
                  ctxAddress: ctx.address,
                  replyPort: replyPort!.sendPort,
                  initPort: initPort.sendPort,
                  channels: channels,
                  patterns: patterns,
                ),
              );

              // Wait for the isolate to signal it's ready
              final commandPort = await initPort.first as SendPort;
              initPort.close();

              // Create a minimal client to hold the connection state
              client = RedisClient._(
                host,
                port,
                bindings,
                dylib,
                commandPort,
                isolate,
                replyPort!,
              );

              // Handle incoming messages
              replyPort!.handler = (dynamic message) {
                if (controller.isClosed) return;
                if (message is _PubSubMessage) {
                  final pubsubMsg = RedisPubSubMessage._(
                    type: message.type,
                    channel: message.channel,
                    message: message.payload,
                    pattern: message.pattern,
                  );
                  controller.add(pubsubMsg);
                }
              };
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
        // Close the dedicated connection
        if (client != null) {
          await client!.close();
          client = null;
        }
        // Close the stream controller
        await controller.close();
      },
    );

    return controller.stream;
  }
}

/// Arguments for the subscription isolate.
class _SubscriptionIsolateArgs {
  final int ctxAddress;
  final SendPort replyPort;
  final SendPort initPort;
  final List<String> channels;
  final List<String> patterns;

  _SubscriptionIsolateArgs({
    required this.ctxAddress,
    required this.replyPort,
    required this.initPort,
    required this.channels,
    required this.patterns,
  });
}

/// Isolate entry point for subscription connections.
void _subscriptionIsolateEntry(_SubscriptionIsolateArgs args) {
  final dylib = RedisClient._openLibrary();
  final bindings = HiredisBindings(dylib);
  final ctx = Pointer<redisAsyncContext>.fromAddress(args.ctxAddress);

  final commandPort = ReceivePort();
  args.initPort.send(commandPort.sendPort);

  var running = true;

  // Reply callback - forwards pub/sub messages to the main isolate
  void onReply(
    Pointer<redisAsyncContext> ac,
    Pointer<Void> replyPtr,
    Pointer<Void> privdata,
  ) {
    if (!running) return;
    if (replyPtr == nullptr) return;

    final reply = replyPtr.cast<redisReply>();

    // Check if this is a pub/sub message
    if (reply.ref.type == REDIS_REPLY_ARRAY && reply.ref.elements >= 3) {
      final firstElem = reply.ref.element[0];
      if (firstElem.ref.type == REDIS_REPLY_STRING) {
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
        }
      }
    }
  }

  final replyCallback =
      NativeCallable<
        Void Function(Pointer<redisAsyncContext>, Pointer<Void>, Pointer<Void>)
      >.listener(onReply);

  // Allocate stop flag
  final stopFlag = calloc<Bool>();
  stopFlag.value = false;

  Pointer<LoopThreadHandle>? loopThreadHandle;

  void cleanup() {
    running = false;
    stopFlag.value = true;

    if (loopThreadHandle != null) {
      bindings.redis_async_stop_loop_thread(loopThreadHandle!);
      loopThreadHandle = null;
    }

    bindings.redisAsyncFree(ctx);
    replyCallback.close();
    calloc.free(stopFlag);
    commandPort.close();
    Isolate.exit();
  }

  // Send subscribe commands
  void sendSubscribeCommand(String cmd, List<String> targets) {
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

      bindings.redisAsyncCommandArgv(
        ctx,
        replyCallback.nativeFunction.cast(),
        nullptr,
        argc,
        argv,
        argvlen,
      );

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

  // Listen for shutdown signal
  commandPort.listen((message) {
    if (message == null) {
      cleanup();
    }
  });

  // Start the I/O loop
  loopThreadHandle = bindings.redis_async_start_loop_thread(ctx, stopFlag);

  if (loopThreadHandle == null || loopThreadHandle == nullptr) {
    replyCallback.close();
    calloc.free(stopFlag);
    bindings.redisAsyncFree(ctx);
    commandPort.close();
    Isolate.exit();
  }

  // Send SUBSCRIBE and PSUBSCRIBE commands
  sendSubscribeCommand('SUBSCRIBE', args.channels);
  sendSubscribeCommand('PSUBSCRIBE', args.patterns);
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
  final ctx = Pointer<redisAsyncContext>.fromAddress(args.ctxAddress);

  final commandPort = ReceivePort();
  args.initPort.send(commandPort.sendPort);

  // Map from privdata to command id
  final pendingCallbacks = <int, int>{};
  var nextPrivdata = 1;
  var running = true;

  // Reply callback - called by hiredis when a command completes
  void onReply(
    Pointer<redisAsyncContext> ac,
    Pointer<Void> replyPtr,
    Pointer<Void> privdata,
  ) {
    // Ignore callbacks after shutdown
    if (!running) return;

    final privdataValue = privdata.address;
    final commandId = pendingCallbacks.remove(privdataValue);

    if (replyPtr == nullptr) {
      if (commandId != null) {
        args.replyPort.send(_ReplyMessage(commandId, 0, 'Null reply'));
      }
      return;
    }

    final reply = replyPtr.cast<redisReply>();

    // Check if this is a pub/sub message
    if (reply.ref.type == REDIS_REPLY_ARRAY && reply.ref.elements >= 3) {
      final firstElem = reply.ref.element[0];
      if (firstElem.ref.type == REDIS_REPLY_STRING) {
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
      args.replyPort.send(_ReplyMessage(commandId, replyPtr.address, null));
    }
  }

  final replyCallback =
      NativeCallable<
        Void Function(Pointer<redisAsyncContext>, Pointer<Void>, Pointer<Void>)
      >.listener(onReply);

  // Allocate stop flag that Zig will check to know when to exit the loop.
  final stopFlag = calloc<Bool>();
  stopFlag.value = false;

  // Handle to the background thread running the I/O loop
  Pointer<LoopThreadHandle>? loopThreadHandle;

  void cleanup() {
    running = false;

    // Signal the Zig loop to stop via the shared flag
    stopFlag.value = true;

    // Stop the background thread and wait for it to exit
    if (loopThreadHandle != null) {
      bindings.redis_async_stop_loop_thread(loopThreadHandle!);
      loopThreadHandle = null;
    }

    // Free the context
    bindings.redisAsyncFree(ctx);

    // Close the reply callback
    replyCallback.close();

    // Free the stop flag
    calloc.free(stopFlag);

    // Close the command port and exit
    commandPort.close();
    Isolate.exit();
  }

  // Listen for commands from main isolate
  commandPort.listen((message) {
    if (message == null) {
      cleanup();
      return;
    }

    if (!running) return;

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

        final privdata = nextPrivdata++;
        pendingCallbacks[privdata] = message.commandId;

        bindings.redisAsyncCommandArgv(
          ctx,
          replyCallback.nativeFunction.cast(),
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

  // Start the blocking I/O loop on a background thread.
  // This spawns a native thread that runs the blocking poll loop, leaving
  // Dart's event loop free to process commands from the main isolate.
  loopThreadHandle = bindings.redis_async_start_loop_thread(ctx, stopFlag);

  if (loopThreadHandle == null || loopThreadHandle == nullptr) {
    // Failed to start the loop thread - clean up and exit
    replyCallback.close();
    calloc.free(stopFlag);
    bindings.redisAsyncFree(ctx);
    commandPort.close();
    Isolate.exit();
  }
}

void _handlePubSubReply(
  SendPort replyPort,
  Pointer<redisReply> reply,
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
