// Async event loop wrapper for hiredis.
//
// This provides a blocking poll function that can be called from a separate
// thread/isolate to wait for Redis events without busy-polling.

const std = @import("std");
const builtin = @import("builtin");

// Import hiredis types via C interop
const c = @cImport({
    @cInclude("hiredis.h");
    @cInclude("async.h");
});

/// Result of a poll operation.
pub const PollResult = enum(c_int) {
    /// Timeout expired, no events.
    timeout = 0,
    /// Data was read and/or written.
    activity = 1,
    /// Error occurred.
    err = -1,
    /// Connection closed or invalid fd.
    closed = -2,
};

/// Polls the Redis async context for I/O readiness and handles events.
///
/// This function blocks until:
/// - Data is available to read
/// - The socket is ready for writing (and we have data to write)
/// - The timeout expires
/// - An error occurs
///
/// Returns:
/// - `activity` (1) if I/O was handled
/// - `timeout` (0) if timeout expired with no activity
/// - `err` (-1) on poll error
/// - `closed` (-2) if the connection is closed or fd is invalid
export fn redis_async_poll(ctx: ?*c.redisAsyncContext, timeout_ms: c_int) PollResult {
    const async_ctx = ctx orelse return .err;

    const fd = async_ctx.c.fd;
    if (fd < 0) return .closed;

    // Determine what events to wait for
    var events: i16 = std.posix.POLL.IN; // Always interested in reading
    if (async_ctx.c.obuf != null and std.mem.len(async_ctx.c.obuf) > 0) {
        // Have data to write
        events |= std.posix.POLL.OUT;
    }

    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = events,
        .revents = 0,
    }};

    const timeout: i32 = if (timeout_ms < 0) -1 else timeout_ms;
    const poll_result = std.posix.poll(&fds, timeout) catch {
        return .err;
    };

    if (poll_result == 0) {
        return .timeout;
    }

    const revents = fds[0].revents;

    // Check for errors/hangup
    if (revents & std.posix.POLL.ERR != 0 or revents & std.posix.POLL.HUP != 0) {
        return .closed;
    }

    // Handle I/O
    if (revents & std.posix.POLL.IN != 0) {
        c.redisAsyncHandleRead(async_ctx);
    }
    if (revents & std.posix.POLL.OUT != 0) {
        c.redisAsyncHandleWrite(async_ctx);
    }

    return .activity;
}

/// Starts a polling loop in the current thread.
///
/// This function runs until:
/// - The context is disconnected
/// - `redis_async_stop_loop` is called
/// - An unrecoverable error occurs
///
/// The `poll_interval_ms` controls how often to check for stop requests
/// between I/O operations.
export fn redis_async_run_loop(ctx: ?*c.redisAsyncContext, poll_interval_ms: c_int) void {
    const async_ctx = ctx orelse return;

    while (true) {
        // Check if we should stop (context disconnected or freed)
        if (async_ctx.c.fd < 0) break;
        if (async_ctx.c.flags & c.REDIS_DISCONNECTING != 0) break;

        const result = redis_async_poll(ctx, poll_interval_ms);
        switch (result) {
            .closed, .err => break,
            .timeout, .activity => continue,
        }
    }
}

/// Gets the file descriptor from an async context.
/// Returns -1 if the context is null or disconnected.
export fn redis_async_get_fd(ctx: ?*c.redisAsyncContext) c_int {
    const async_ctx = ctx orelse return -1;
    return async_ctx.c.fd;
}

/// Checks if the async context is connected.
export fn redis_async_is_connected(ctx: ?*c.redisAsyncContext) bool {
    const async_ctx = ctx orelse return false;
    if (async_ctx.c.fd < 0) return false;
    if (async_ctx.c.flags & c.REDIS_CONNECTED == 0) return false;
    if (async_ctx.c.flags & c.REDIS_DISCONNECTING != 0) return false;
    return true;
}

/// Forces a write flush - sends any pending commands immediately.
export fn redis_async_flush(ctx: ?*c.redisAsyncContext) void {
    const async_ctx = ctx orelse return;
    c.redisAsyncHandleWrite(async_ctx);
}
