// FFI bindings for the event loop API.
//
// These bindings use Dart_PostCObject_DL for efficient native -> Dart
// notifications via SendPort.

// ignore_for_file: non_constant_identifier_names

@ffi.DefaultAsset('package:redis_ffi/redis_ffi.dart')
library;

import 'dart:ffi' as ffi;

import 'hiredis_bindings.g.dart';

/// Opaque handle to the native event loop state.
final class EventLoopState extends ffi.Opaque {}

/// Initialize the Dart API DL. Must be called once before using the event loop.
/// Pass `ffi.NativeApi.initializeApiDLData` as the argument.
@ffi.Native<ffi.IntPtr Function(ffi.Pointer<ffi.Void>)>()
external int redis_init_dart_api(ffi.Pointer<ffi.Void> data);

/// Create a new event loop state.
///
/// - [ctx]: The async Redis context.
/// - [dartPort]: The native port from `receivePort.sendPort.nativePort`.
///
/// Returns null on failure.
@ffi.Native<
  ffi.Pointer<EventLoopState> Function(
    ffi.Pointer<redisAsyncContext>,
    ffi.Int64,
  )
>()
external ffi.Pointer<EventLoopState> redis_event_loop_create(
  ffi.Pointer<redisAsyncContext> ctx,
  int dartPort,
);

/// Destroy the event loop state.
@ffi.Native<ffi.Void Function(ffi.Pointer<EventLoopState>)>()
external void redis_event_loop_destroy(ffi.Pointer<EventLoopState> state);

/// Start the poll loop on a background thread.
///
/// Returns true on success, false if already running or on error.
@ffi.Native<ffi.Bool Function(ffi.Pointer<EventLoopState>)>()
external bool redis_event_loop_start(ffi.Pointer<EventLoopState> state);

/// Stop the poll loop.
@ffi.Native<ffi.Void Function(ffi.Pointer<EventLoopState>)>()
external void redis_event_loop_stop(ffi.Pointer<EventLoopState> state);

/// Notify the poll thread that there's work to do.
@ffi.Native<ffi.Void Function(ffi.Pointer<EventLoopState>)>()
external void redis_event_loop_wakeup(ffi.Pointer<EventLoopState> state);

/// Check if the context is connected.
@ffi.Native<ffi.Bool Function(ffi.Pointer<redisAsyncContext>)>()
external bool redis_async_is_connected(ffi.Pointer<redisAsyncContext> ctx);

/// Queue a command without waking up the poll thread.
/// Use redis_event_loop_wakeup after queuing multiple commands to batch wakeups.
///
/// Returns 0 on success, -1 on error.
@ffi.Native<
  ffi.Int Function(
    ffi.Pointer<EventLoopState>,
    ffi.Int64,
    ffi.Int64,
    ffi.Int,
    ffi.Pointer<ffi.Pointer<ffi.Char>>,
    ffi.Pointer<ffi.Size>,
  )
>()
external int redis_async_command_enqueue(
  ffi.Pointer<EventLoopState> state,
  int dartPort,
  int commandId,
  int argc,
  ffi.Pointer<ffi.Pointer<ffi.Char>> argv,
  ffi.Pointer<ffi.Size> argvlen,
);

/// Send an async command and wake up the poll thread.
/// For pipelining, use redis_async_command_enqueue + redis_event_loop_wakeup.
///
/// Returns 0 on success, -1 on error.
@ffi.Native<
  ffi.Int Function(
    ffi.Pointer<EventLoopState>,
    ffi.Int64,
    ffi.Int64,
    ffi.Int,
    ffi.Pointer<ffi.Pointer<ffi.Char>>,
    ffi.Pointer<ffi.Size>,
  )
>()
external int redis_async_command(
  ffi.Pointer<EventLoopState> state,
  int dartPort,
  int commandId,
  int argc,
  ffi.Pointer<ffi.Pointer<ffi.Char>> argv,
  ffi.Pointer<ffi.Size> argvlen,
);

/// Send a pub/sub command (SUBSCRIBE, PSUBSCRIBE, etc.).
/// The callback is persistent and will be called for each message.
///
/// Returns 0 on success, -1 on error.
@ffi.Native<
  ffi.Int Function(
    ffi.Pointer<EventLoopState>,
    ffi.Int64,
    ffi.Int64,
    ffi.Int,
    ffi.Pointer<ffi.Pointer<ffi.Char>>,
    ffi.Pointer<ffi.Size>,
  )
>()
external int redis_async_pubsub_command(
  ffi.Pointer<EventLoopState> state,
  int dartPort,
  int commandId,
  int argc,
  ffi.Pointer<ffi.Pointer<ffi.Char>> argv,
  ffi.Pointer<ffi.Size> argvlen,
);

/// Helper to initialize the Dart API.
bool initializeDartApi() {
  final result = redis_init_dart_api(ffi.NativeApi.initializeApiDLData);
  return result == 0;
}
