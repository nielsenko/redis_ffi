// Async event loop wrapper for hiredis - C header for FFI bindings.

#ifndef REDIS_FFI_ASYNC_LOOP_H
#define REDIS_FFI_ASYNC_LOOP_H

#include <stdbool.h>
#include "async.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Result of a poll operation.
typedef enum {
    REDIS_POLL_TIMEOUT = 0,   // Timeout expired, no events.
    REDIS_POLL_ACTIVITY = 1,  // Data was read and/or written.
    REDIS_POLL_ERROR = -1,    // Error occurred.
    REDIS_POLL_CLOSED = -2,   // Connection closed or invalid fd.
} RedisPollResult;

/// Polls the Redis async context for I/O readiness and handles events.
///
/// This function blocks until:
/// - Data is available to read
/// - The socket is ready for writing (and we have data to write)
/// - The timeout expires
/// - An error occurs
///
/// @param ctx The async context to poll.
/// @param timeout_ms Timeout in milliseconds. Use -1 for infinite wait.
/// @return Poll result code.
RedisPollResult redis_async_poll(redisAsyncContext *ctx, int timeout_ms);

/// Runs a blocking event loop that waits for socket activity.
///
/// This function blocks on poll() waiting for I/O events and processes them.
///
/// The loop exits when:
/// - The stop_flag pointer is set to true (non-zero)
/// - The connection is closed or errors
/// - The context becomes invalid
///
/// @param ctx The async context to run the loop for.
/// @param stop_flag Pointer to a bool that Dart can set to signal stop.
void redis_async_run_loop(redisAsyncContext *ctx, volatile bool *stop_flag);

/// Gets the file descriptor from an async context.
/// @return The fd, or -1 if the context is null or disconnected.
int redis_async_get_fd(redisAsyncContext *ctx);

/// Checks if the async context is connected.
/// @return true if connected, false otherwise.
bool redis_async_is_connected(redisAsyncContext *ctx);

/// Forces a write flush - sends any pending commands immediately.
void redis_async_flush(redisAsyncContext *ctx);

/// Opaque handle to a background loop thread.
typedef struct LoopThreadHandle LoopThreadHandle;

/// Starts the event loop on a background thread.
///
/// This function spawns a new thread that runs the blocking event loop,
/// allowing the calling thread (Dart's event loop) to continue processing.
///
/// @param ctx The async context to run the loop for.
/// @param stop_flag Pointer to a bool that can be set to signal stop.
/// @return Opaque handle pointer, or NULL on failure.
LoopThreadHandle* redis_async_start_loop_thread(
    redisAsyncContext *ctx,
    volatile bool *stop_flag
);

/// Stops the background loop thread and cleans up resources.
///
/// This function sets the stop flag, waits for the thread to exit,
/// and frees all associated resources.
///
/// @param handle The handle returned by redis_async_start_loop_thread.
void redis_async_stop_loop_thread(LoopThreadHandle *handle);

#ifdef __cplusplus
}
#endif

#endif // REDIS_FFI_ASYNC_LOOP_H
