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

/// Starts a polling loop in the current thread.
///
/// This function runs until:
/// - The context is disconnected
/// - An unrecoverable error occurs
///
/// @param ctx The async context to run the loop for.
/// @param poll_interval_ms Timeout for each poll iteration.
void redis_async_run_loop(redisAsyncContext *ctx, int poll_interval_ms);

/// Gets the file descriptor from an async context.
/// @return The fd, or -1 if the context is null or disconnected.
int redis_async_get_fd(redisAsyncContext *ctx);

/// Checks if the async context is connected.
/// @return true if connected, false otherwise.
bool redis_async_is_connected(redisAsyncContext *ctx);

/// Forces a write flush - sends any pending commands immediately.
void redis_async_flush(redisAsyncContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // REDIS_FFI_ASYNC_LOOP_H
