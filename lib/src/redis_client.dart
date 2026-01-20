import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'hiredis_bindings.g.dart';
import 'redis_reply.dart';

/// Exception thrown when a Redis operation fails.
class RedisException implements Exception {
  /// The error message.
  final String message;

  /// Creates a RedisException with the given message.
  RedisException(this.message);

  @override
  String toString() => 'RedisException: $message';
}

/// A synchronous Redis client using hiredis FFI bindings.
///
/// This class implements [Finalizable] to prevent premature garbage collection
/// during FFI calls. The native context is automatically freed when this object
/// is garbage collected, or can be freed manually with [close].
///
/// Memory management options:
/// - Uses REDICT_OPT_NOAUTOFREE to control context lifetime from Dart
/// - Uses REDICT_OPT_NOAUTOFREEREPLIES to control reply lifetime from Dart
/// - Uses REDICT_OPT_NO_PUSH_AUTOFREE for pub/sub PUSH message handling
final class RedisClient implements Finalizable {
  /// The native finalizer that calls redictFree.
  static NativeFinalizer? _finalizer;

  /// Initialize the finalizer with the dynamic library.
  static void _ensureFinalizerInitialized(DynamicLibrary dylib) {
    if (_finalizer == null) {
      final redictFreePtr = dylib
          .lookup<NativeFunction<Void Function(Pointer<redictContext>)>>(
            'redictFree',
          );
      _finalizer = NativeFinalizer(redictFreePtr.cast());
    }
  }

  final HiredisBindings _bindings;
  final DynamicLibrary _dylib;
  Pointer<redictContext>? _context;
  bool _closed = false;

  RedisClient._(this._bindings, this._dylib, this._context) {
    _ensureFinalizerInitialized(_dylib);
    _finalizer!.attach(this, _context!.cast(), detach: this);
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

  /// Connects to a Redis server at the given host and port.
  ///
  /// Throws [RedisException] if the connection fails.
  factory RedisClient.connect(String host, int port) {
    final dylib = _openLibrary();
    final bindings = HiredisBindings(dylib);

    // Set up connection options with manual memory management
    final options = calloc<redictOptions>();
    try {
      // Zero-initialize the options struct
      for (var i = 0; i < sizeOf<redictOptions>(); i++) {
        options.cast<Uint8>()[i] = 0;
      }

      // Set TCP connection parameters
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

        final context = bindings.redictConnectWithOptions(options);
        if (context == nullptr) {
          throw RedisException('Failed to allocate Redis context');
        }

        if (context.ref.err != 0) {
          final errstr = _extractErrorString(context);
          bindings.redictFree(context);
          throw RedisException('Connection failed: $errstr');
        }

        return RedisClient._(bindings, dylib, context);
      } finally {
        calloc.free(hostPtr);
      }
    } finally {
      calloc.free(options);
    }
  }

  /// Connects to a Redis server using a Unix socket.
  ///
  /// Throws [RedisException] if the connection fails.
  factory RedisClient.connectUnix(String path) {
    final dylib = _openLibrary();
    final bindings = HiredisBindings(dylib);

    final pathPtr = path.toNativeUtf8();
    try {
      final context = bindings.redictConnectUnix(pathPtr.cast());
      if (context == nullptr) {
        throw RedisException('Failed to allocate Redis context');
      }

      if (context.ref.err != 0) {
        final errstr = _extractErrorString(context);
        bindings.redictFree(context);
        throw RedisException('Connection failed: $errstr');
      }

      // Set flags for manual memory management after connection
      context.ref.flags |= REDICT_NO_AUTO_FREE | REDICT_NO_AUTO_FREE_REPLIES;

      return RedisClient._(bindings, dylib, context);
    } finally {
      calloc.free(pathPtr);
    }
  }

  static String _extractErrorString(Pointer<redictContext> context) {
    final errArray = context.ref.errstr;
    final buffer = StringBuffer();
    for (var i = 0; i < 128 && errArray[i] != 0; i++) {
      buffer.writeCharCode(errArray[i]);
    }
    return buffer.toString();
  }

  /// Whether the client is connected.
  bool get isConnected {
    if (_closed || _context == null) return false;
    return (_context!.ref.flags & REDICT_CONNECTED) != 0;
  }

  /// Executes a Redis command and returns the reply.
  ///
  /// The command string uses printf-style formatting.
  /// Example: `command('SET %s %s', ['key', 'value'])`
  ///
  /// Throws [RedisException] if the command fails.
  /// Throws [StateError] if the client is closed.
  RedisReply command(String format, [List<String>? args]) {
    _checkNotClosed();

    final formatPtr = format.toNativeUtf8();
    try {
      Pointer<Void> replyPtr;

      if (args == null || args.isEmpty) {
        replyPtr = _bindings.redictCommand(_context!, formatPtr.cast());
      } else {
        // For commands with arguments, use redictCommandArgv for safety
        return commandArgv([format, ...args]);
      }

      if (replyPtr == nullptr) {
        final errstr = _extractErrorString(_context!);
        throw RedisException('Command failed: $errstr');
      }

      final reply = RedisReply.fromPointer(_bindings, _dylib, replyPtr);
      if (reply == null) {
        throw RedisException('Failed to parse reply');
      }

      if (reply.isError) {
        final errorMsg = reply.string ?? 'Unknown error';
        reply.free();
        throw RedisException(errorMsg);
      }

      return reply;
    } finally {
      calloc.free(formatPtr);
    }
  }

  /// Executes a Redis command with explicit arguments.
  ///
  /// This is the safest way to execute commands as it properly handles
  /// binary data and special characters.
  ///
  /// Example: `commandArgv(['SET', 'key', 'value'])`
  ///
  /// Throws [RedisException] if the command fails.
  /// Throws [StateError] if the client is closed.
  RedisReply commandArgv(List<String> args) {
    _checkNotClosed();

    final argc = args.length;
    final argv = calloc<Pointer<Char>>(argc);
    final argvlen = calloc<Size>(argc);

    try {
      // Convert all arguments to native strings
      for (var i = 0; i < argc; i++) {
        final arg = args[i].toNativeUtf8();
        argv[i] = arg.cast();
        argvlen[i] = args[i].length;
      }

      final replyPtr = _bindings.redictCommandArgv(
        _context!,
        argc,
        argv,
        argvlen,
      );

      if (replyPtr == nullptr) {
        final errstr = _extractErrorString(_context!);
        throw RedisException('Command failed: $errstr');
      }

      final reply = RedisReply.fromPointer(_bindings, _dylib, replyPtr);
      if (reply == null) {
        throw RedisException('Failed to parse reply');
      }

      if (reply.isError) {
        final errorMsg = reply.string ?? 'Unknown error';
        reply.free();
        throw RedisException(errorMsg);
      }

      return reply;
    } finally {
      // Free all the argument strings
      for (var i = 0; i < argc; i++) {
        if (argv[i] != nullptr) {
          calloc.free(argv[i].cast<Utf8>());
        }
      }
      calloc.free(argv);
      calloc.free(argvlen);
    }
  }

  /// Executes a PING command.
  ///
  /// Returns the PONG response string.
  String ping([String? message]) {
    final reply = message != null
        ? commandArgv(['PING', message])
        : commandArgv(['PING']);
    try {
      return reply.string ?? 'PONG';
    } finally {
      reply.free();
    }
  }

  /// Gets the value of a key.
  ///
  /// Returns null if the key doesn't exist.
  String? get(String key) {
    final reply = commandArgv(['GET', key]);
    try {
      if (reply.isNil) return null;
      return reply.string;
    } finally {
      reply.free();
    }
  }

  /// Sets the value of a key.
  void set(String key, String value) {
    final reply = commandArgv(['SET', key, value]);
    reply.free();
  }

  /// Deletes one or more keys.
  ///
  /// Returns the number of keys that were deleted.
  int del(List<String> keys) {
    final reply = commandArgv(['DEL', ...keys]);
    try {
      return reply.integer;
    } finally {
      reply.free();
    }
  }

  /// Checks if a key exists.
  bool exists(String key) {
    final reply = commandArgv(['EXISTS', key]);
    try {
      return reply.integer > 0;
    } finally {
      reply.free();
    }
  }

  /// Closes the Redis connection.
  ///
  /// After calling this method, the client can no longer be used.
  void close() {
    if (_closed) return;
    _finalizer!.detach(this);
    if (_context != null) {
      _bindings.redictFree(_context!);
      _context = null;
    }
    _closed = true;
  }

  void _checkNotClosed() {
    if (_closed) {
      throw StateError('RedisClient has been closed');
    }
  }
}
