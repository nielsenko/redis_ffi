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

/// Runs a blocking event loop that waits for socket activity.
///
/// This function blocks on poll() waiting for I/O events and processes them.
///
/// The loop exits when:
/// - The stop_flag pointer is set to true (non-zero)
/// - The connection is closed or errors
/// - The context becomes invalid
///
/// Parameters:
/// - ctx: The async Redis context
/// - stop_flag: Pointer to a bool that Dart can set to signal stop
export fn redis_async_run_loop(
    ctx: ?*c.redisAsyncContext,
    stop_flag: ?*volatile bool,
) void {
    const async_ctx = ctx orelse return;
    const stop = stop_flag orelse return;

    while (true) {
        // Check stop flag first
        if (stop.*) break;

        // Check if connection is still valid
        if (async_ctx.c.fd < 0) break;
        if (async_ctx.c.flags & c.REDIS_DISCONNECTING != 0) break;

        // Block waiting for socket activity (up to 100ms to allow periodic stop flag checks)
        const result = redis_async_poll(ctx, 100);

        // Check result
        switch (result) {
            .closed, .err => break,
            .timeout, .activity => {},
        }

        // Check stop flag again after poll
        if (stop.*) break;
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

/// Thread context for the background loop.
const LoopThreadContext = struct {
    ctx: *c.redisAsyncContext,
    stop_flag: *volatile bool,
};

/// Handle to a background loop thread.
pub const LoopThreadHandle = struct {
    thread: std.Thread,
    context: *LoopThreadContext,
};

/// Global allocator for thread contexts.
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

/// Starts the event loop on a background thread.
///
/// This function spawns a new thread that runs the blocking event loop,
/// allowing the calling thread (Dart's event loop) to continue processing.
///
/// Returns an opaque handle that must be passed to redis_async_stop_loop_thread
/// to stop the thread and clean up resources.
///
/// Parameters:
/// - ctx: The async Redis context
/// - stop_flag: Pointer to a bool that can be set to signal stop
///
/// Returns: Opaque handle pointer, or null on failure.
export fn redis_async_start_loop_thread(
    ctx: ?*c.redisAsyncContext,
    stop_flag: ?*volatile bool,
) ?*LoopThreadHandle {
    const async_ctx = ctx orelse return null;
    const stop = stop_flag orelse return null;

    const allocator = gpa.allocator();

    // Allocate context struct
    const thread_ctx = allocator.create(LoopThreadContext) catch return null;
    thread_ctx.* = .{
        .ctx = async_ctx,
        .stop_flag = stop,
    };

    // Allocate handle
    const handle = allocator.create(LoopThreadHandle) catch {
        allocator.destroy(thread_ctx);
        return null;
    };

    // Spawn thread
    handle.thread = std.Thread.spawn(.{}, struct {
        fn run(context: *LoopThreadContext) void {
            redis_async_run_loop(@ptrCast(context.ctx), context.stop_flag);
        }
    }.run, .{thread_ctx}) catch {
        allocator.destroy(handle);
        allocator.destroy(thread_ctx);
        return null;
    };

    handle.context = thread_ctx;
    return handle;
}

/// Stops the background loop thread and cleans up resources.
///
/// This function sets the stop flag, waits for the thread to exit,
/// and frees all associated resources.
///
/// Parameters:
/// - handle: The handle returned by redis_async_start_loop_thread
export fn redis_async_stop_loop_thread(handle: ?*LoopThreadHandle) void {
    const h = handle orelse return;
    const allocator = gpa.allocator();

    // Signal stop (caller should have already done this, but ensure it)
    h.context.stop_flag.* = true;

    // Wait for thread to exit
    h.thread.join();

    // Free resources
    allocator.destroy(h.context);
    allocator.destroy(h);
}
