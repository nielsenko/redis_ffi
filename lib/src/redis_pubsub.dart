import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'hiredis_bindings.g.dart';
import 'redis_reply.dart';

/// A message received from a Redis pub/sub subscription.
class RedisPubSubMessage {
  /// The type of message ('message', 'pmessage', 'subscribe', 'unsubscribe', etc.)
  final String type;

  /// The channel or pattern the message was received on.
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

  /// Creates a message from a Redis reply.
  static RedisPubSubMessage? fromReply(RedisReply reply) {
    if (reply.type != RedisReplyType.array || reply.length < 3) {
      return null;
    }

    final typeStr = reply[0]?.string?.toLowerCase();
    if (typeStr == null) return null;

    switch (typeStr) {
      case 'message':
        return RedisPubSubMessage._(
          type: typeStr,
          channel: reply[1]?.string ?? '',
          message: reply[2]?.string,
        );
      case 'pmessage':
        if (reply.length < 4) return null;
        return RedisPubSubMessage._(
          type: typeStr,
          pattern: reply[1]?.string,
          channel: reply[2]?.string ?? '',
          message: reply[3]?.string,
        );
      case 'subscribe':
      case 'unsubscribe':
      case 'psubscribe':
      case 'punsubscribe':
        return RedisPubSubMessage._(
          type: typeStr,
          channel: reply[1]?.string ?? '',
        );
      default:
        return RedisPubSubMessage._(
          type: typeStr,
          channel: reply[1]?.string ?? '',
          message: reply.length > 2 ? reply[2]?.string : null,
        );
    }
  }

  @override
  String toString() {
    if (pattern != null) {
      return 'RedisPubSubMessage($type, pattern: $pattern, channel: $channel, message: $message)';
    }
    return 'RedisPubSubMessage($type, channel: $channel, message: $message)';
  }
}

/// A pub/sub client for Redis using the async hiredis API.
///
/// This class uses [NativeCallable.listener] for callbacks from the native
/// library, allowing messages to be received asynchronously.
///
/// Messages are exposed as a [Stream] for idiomatic Dart consumption.
///
/// Example:
/// ```dart
/// final pubsub = RedisPubSub.connect('localhost', 6379);
/// pubsub.subscribe('my-channel');
///
/// await for (final message in pubsub.messages) {
///   print('Received: ${message.message}');
/// }
/// ```
final class RedisPubSub implements Finalizable {
  /// The native finalizer that calls redictAsyncFree.
  static NativeFinalizer? _finalizer;

  /// Initialize the finalizer with the dynamic library.
  static void _ensureFinalizerInitialized(DynamicLibrary dylib) {
    if (_finalizer == null) {
      final redictAsyncFreePtr = dylib
          .lookup<NativeFunction<Void Function(Pointer<redictAsyncContext>)>>(
            'redictAsyncFree',
          );
      _finalizer = NativeFinalizer(redictAsyncFreePtr.cast());
    }
  }

  final HiredisBindings _bindings;
  final DynamicLibrary _dylib;
  Pointer<redictAsyncContext>? _asyncContext;
  bool _closed = false;

  final StreamController<RedisPubSubMessage> _messageController =
      StreamController<RedisPubSubMessage>.broadcast();

  /// The native callback for receiving messages.
  late final NativeCallable<
    Void Function(Pointer<redictAsyncContext>, Pointer<Void>, Pointer<Void>)
  >
  _callback;

  RedisPubSub._(this._bindings, this._dylib, this._asyncContext) {
    _ensureFinalizerInitialized(_dylib);
    _finalizer!.attach(this, _asyncContext!.cast(), detach: this);

    // Create a listener callback that can be called from any thread
    _callback =
        NativeCallable<
          Void Function(
            Pointer<redictAsyncContext>,
            Pointer<Void>,
            Pointer<Void>,
          )
        >.listener(_onMessage);
  }

  /// Opens the hiredis dynamic library.
  static DynamicLibrary _openLibrary() {
    if (Platform.isMacOS) {
      return DynamicLibrary.open('libhiredis.dylib');
    } else if (Platform.isLinux || Platform.isAndroid) {
      return DynamicLibrary.open('libhiredis.so');
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('hiredis.dll');
    } else {
      throw UnsupportedError(
        'Unsupported platform: ${Platform.operatingSystem}',
      );
    }
  }

  /// Connects to a Redis server for pub/sub operations.
  factory RedisPubSub.connect(String host, int port) {
    final dylib = _openLibrary();
    final bindings = HiredisBindings(dylib);

    // Set up connection options with manual memory management
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

        // Set options for Dart-controlled memory management
        options.ref.options =
            REDICT_OPT_NOAUTOFREE |
            REDICT_OPT_NOAUTOFREEREPLIES |
            REDICT_OPT_NO_PUSH_AUTOFREE;

        final asyncContext = bindings.redictAsyncConnectWithOptions(options);
        if (asyncContext == nullptr) {
          throw StateError('Failed to allocate async context');
        }

        if (asyncContext.ref.err != 0) {
          final errArray = asyncContext.ref.errstr;
          final buffer = StringBuffer();
          for (var i = 0; i < 128 && errArray[i] != 0; i++) {
            buffer.writeCharCode(errArray[i]);
          }
          bindings.redictAsyncFree(asyncContext);
          throw StateError('Connection failed: $buffer');
        }

        return RedisPubSub._(bindings, dylib, asyncContext);
      } finally {
        calloc.free(hostPtr);
      }
    } finally {
      calloc.free(options);
    }
  }

  /// Stream of pub/sub messages.
  Stream<RedisPubSubMessage> get messages => _messageController.stream;

  /// Callback invoked when a message is received from Redis.
  void _onMessage(
    Pointer<redictAsyncContext> ac,
    Pointer<Void> replyPtr,
    Pointer<Void> privdata,
  ) {
    if (_closed || replyPtr == nullptr) return;

    // Wrap the reply with our managed wrapper
    final reply = RedisReply.fromPointer(_bindings, _dylib, replyPtr);
    if (reply == null) return;

    try {
      final message = RedisPubSubMessage.fromReply(reply);
      if (message != null && !_messageController.isClosed) {
        _messageController.add(message);
      }
    } finally {
      // With NOAUTOFREEREPLIES, we're responsible for freeing
      reply.free();
    }
  }

  /// Subscribes to a channel.
  void subscribe(String channel) {
    _checkNotClosed();
    _sendCommand(['SUBSCRIBE', channel]);
  }

  /// Subscribes to multiple channels.
  void subscribeAll(List<String> channels) {
    _checkNotClosed();
    _sendCommand(['SUBSCRIBE', ...channels]);
  }

  /// Subscribes to a pattern.
  void psubscribe(String pattern) {
    _checkNotClosed();
    _sendCommand(['PSUBSCRIBE', pattern]);
  }

  /// Unsubscribes from a channel.
  void unsubscribe(String channel) {
    _checkNotClosed();
    _sendCommand(['UNSUBSCRIBE', channel]);
  }

  /// Unsubscribes from a pattern.
  void punsubscribe(String pattern) {
    _checkNotClosed();
    _sendCommand(['PUNSUBSCRIBE', pattern]);
  }

  void _sendCommand(List<String> args) {
    final argc = args.length;
    final argv = calloc<Pointer<Char>>(argc);
    final argvlen = calloc<Size>(argc);

    try {
      for (var i = 0; i < argc; i++) {
        final arg = args[i].toNativeUtf8();
        argv[i] = arg.cast();
        argvlen[i] = args[i].length;
      }

      _bindings.redictAsyncCommandArgv(
        _asyncContext!,
        _callback.nativeFunction.cast(),
        nullptr, // privdata
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

  /// Processes pending I/O operations.
  ///
  /// This must be called periodically to receive messages.
  /// In a real application, you would typically integrate this with
  /// an event loop or use a dedicated isolate.
  void poll() {
    _checkNotClosed();
    _bindings.redictAsyncHandleRead(_asyncContext!);
    _bindings.redictAsyncHandleWrite(_asyncContext!);
  }

  /// Closes the pub/sub connection.
  void close() {
    if (_closed) return;
    _closed = true;

    _callback.close();
    _messageController.close();

    _finalizer!.detach(this);
    if (_asyncContext != null) {
      _bindings.redictAsyncFree(_asyncContext!);
      _asyncContext = null;
    }
  }

  void _checkNotClosed() {
    if (_closed) {
      throw StateError('RedisPubSub has been closed');
    }
  }
}
