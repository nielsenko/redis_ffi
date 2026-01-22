// Async event loop for hiredis with Dart SendPort notifications.
//
// Architecture:
// 1. Dart creates a ReceivePort and passes its nativePort to native code
// 2. Dart thread pushes commands to a lock-free MPSC queue
// 3. Native poll thread drains queue and submits to hiredis (single-threaded hiredis access)
// 4. When hiredis invokes reply callbacks, we copy the reply data and post to Dart
// 5. Hiredis frees the original reply (no NOAUTOFREEREPLIES)
// 6. Dart receives the copied data and processes it

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("hiredis.h");
    @cInclude("async.h");
    @cInclude("dart_api_dl.h");
});

const is_windows = builtin.os.tag == .windows;

// Message types sent to Dart
const MSG_DISCONNECT: i64 = -1;

// Redis reply types (from hiredis.h)
const REDIS_REPLY_STRING = 1;
const REDIS_REPLY_ARRAY = 2;
const REDIS_REPLY_INTEGER = 3;
const REDIS_REPLY_NIL = 4;
const REDIS_REPLY_STATUS = 5;
const REDIS_REPLY_ERROR = 6;
const REDIS_REPLY_DOUBLE = 7;
const REDIS_REPLY_BOOL = 8;
const REDIS_REPLY_MAP = 9;
const REDIS_REPLY_SET = 10;
const REDIS_REPLY_ATTR = 11;
const REDIS_REPLY_PUSH = 12;
const REDIS_REPLY_BIGNUM = 13;
const REDIS_REPLY_VERB = 14;

// ============================================================================
// Lock-free MPSC Queue (Multiple Producer, Single Consumer)
// Uses Michael-Scott algorithm with atomic compare-and-swap
// ============================================================================

/// A command node in the lock-free queue.
const CommandNode = struct {
    next: std.atomic.Value(?*CommandNode),
    // Command data - owned by this node, freed when processed
    dart_port: c.Dart_Port_DL,
    command_id: i64,
    argc: c_int,
    argv: [*c][*c]u8, // Owned copies of strings
    argvlen: [*c]usize,

    fn create(
        dart_port: c.Dart_Port_DL,
        command_id: i64,
        argc: c_int,
        argv: [*c][*c]const u8,
        argvlen: [*c]const usize,
    ) ?*CommandNode {
        const node = std.heap.c_allocator.create(CommandNode) catch return null;

        // Allocate arrays for argv and argvlen copies
        const argv_copy = std.heap.c_allocator.alloc([*c]u8, @intCast(argc)) catch {
            std.heap.c_allocator.destroy(node);
            return null;
        };
        const argvlen_copy = std.heap.c_allocator.alloc(usize, @intCast(argc)) catch {
            std.heap.c_allocator.free(argv_copy);
            std.heap.c_allocator.destroy(node);
            return null;
        };

        // Copy each argument string
        for (0..@intCast(argc)) |i| {
            const len = argvlen[i];
            const str_copy = std.heap.c_allocator.alloc(u8, len) catch {
                // Free already allocated strings
                for (0..i) |j| {
                    std.heap.c_allocator.free(argv_copy[j][0..argvlen_copy[j]]);
                }
                std.heap.c_allocator.free(argvlen_copy);
                std.heap.c_allocator.free(argv_copy);
                std.heap.c_allocator.destroy(node);
                return null;
            };
            @memcpy(str_copy, argv[i][0..len]);
            argv_copy[i] = str_copy.ptr;
            argvlen_copy[i] = len;
        }

        node.* = .{
            .next = std.atomic.Value(?*CommandNode).init(null),
            .dart_port = dart_port,
            .command_id = command_id,
            .argc = argc,
            .argv = argv_copy.ptr,
            .argvlen = argvlen_copy.ptr,
        };
        return node;
    }

    fn destroy(self: *CommandNode) void {
        // Free copied strings
        for (0..@intCast(self.argc)) |i| {
            const len = self.argvlen[i];
            std.heap.c_allocator.free(self.argv[i][0..len]);
        }
        // Free arrays
        std.heap.c_allocator.free(self.argv[0..@intCast(self.argc)]);
        std.heap.c_allocator.free(self.argvlen[0..@intCast(self.argc)]);
        // Free node
        std.heap.c_allocator.destroy(self);
    }
};

/// Simple MPSC queue using atomic swap for push.
/// Producers atomically swap the tail, consumer drains from head.
const CommandQueue = struct {
    // Tail is atomically swapped by producers
    tail: std.atomic.Value(?*CommandNode),
    // Mutex for consumer-side operations (only held briefly during drain)
    drain_mutex: std.Thread.Mutex,

    fn init(self: *CommandQueue) void {
        self.tail = std.atomic.Value(?*CommandNode).init(null);
        self.drain_mutex = .{};
    }

    /// Push a node to the queue (lock-free, multiple producers safe).
    /// Uses atomic swap to build a reversed list.
    fn push(self: *CommandQueue, node: *CommandNode) void {
        // Build a stack (LIFO) via atomic swap
        var old_tail = self.tail.load(.acquire);
        while (true) {
            node.next.store(old_tail, .release);
            if (self.tail.cmpxchgWeak(old_tail, node, .acq_rel, .acquire)) |updated| {
                old_tail = updated;
            } else {
                break;
            }
        }
    }

    /// Drain all nodes from the queue (single consumer).
    /// Returns nodes in FIFO order (reverses the internal LIFO stack).
    fn drainAll(self: *CommandQueue) ?*CommandNode {
        // Atomically take all nodes
        const stack = self.tail.swap(null, .acq_rel) orelse return null;

        // Reverse to get FIFO order
        var reversed: ?*CommandNode = null;
        var current: ?*CommandNode = stack;
        while (current) |node| {
            const next = node.next.load(.acquire);
            node.next.store(reversed, .release);
            reversed = node;
            current = next;
        }

        return reversed;
    }
};

/// State for the event loop.
pub const EventLoopState = struct {
    dart_port: c.Dart_Port_DL,
    ctx: *c.redisAsyncContext,
    stop: std.atomic.Value(bool),
    thread: ?std.Thread,
    mutex: std.Thread.Mutex, // For thread start/stop
    ctx_mutex: std.Thread.Mutex, // For hiredis context access
    // Lock-free command queue
    command_queue: CommandQueue,
    // Pipe for waking up the poll thread when commands are queued
    wakeup_read_fd: std.posix.fd_t,
    wakeup_write_fd: std.posix.fd_t,
};

/// Initialize the Dart API DL.
export fn redis_init_dart_api(data: ?*anyopaque) callconv(.c) isize {
    return c.Dart_InitializeApiDL(data);
}

/// Create a new event loop state.
export fn redis_event_loop_create(
    ctx: ?*c.redisAsyncContext,
    dart_port: c.Dart_Port_DL,
) callconv(.c) ?*EventLoopState {
    const async_ctx = ctx orelse return null;

    // Create wakeup pipe
    const pipe_fds = if (is_windows)
        .{ .read = -1, .write = -1 } // Windows uses different mechanism
    else
        std.posix.pipe() catch return null;

    const state = std.heap.c_allocator.create(EventLoopState) catch {
        if (!is_windows) {
            std.posix.close(pipe_fds[0]);
            std.posix.close(pipe_fds[1]);
        }
        return null;
    };
    state.* = .{
        .dart_port = dart_port,
        .ctx = async_ctx,
        .stop = std.atomic.Value(bool).init(false),
        .thread = null,
        .mutex = .{},
        .ctx_mutex = .{},
        .command_queue = undefined,
        .wakeup_read_fd = if (is_windows) -1 else pipe_fds[0],
        .wakeup_write_fd = if (is_windows) -1 else pipe_fds[1],
    };
    state.command_queue.init();

    // Store state in ev.data for cleanup callback
    async_ctx.ev.data = state;
    async_ctx.ev.cleanup = cleanupCallback;

    return state;
}

/// Destroy the event loop state and free the async context.
/// After calling this, do NOT call redisAsyncFree - this function handles it.
export fn redis_event_loop_destroy(state: ?*EventLoopState) callconv(.c) void {
    const s = state orelse return;
    redis_event_loop_stop(state);

    // Free any remaining queued commands
    var node = s.command_queue.drainAll();
    while (node) |n| {
        const next = n.next.load(.acquire);
        n.destroy();
        node = next;
    }

    // Free the async context - we use REDIS_OPT_NOAUTOFREE so we control when it's freed
    c.redisAsyncFree(s.ctx);

    // Close wakeup pipe
    if (!is_windows) {
        if (s.wakeup_read_fd >= 0) std.posix.close(s.wakeup_read_fd);
        if (s.wakeup_write_fd >= 0) std.posix.close(s.wakeup_write_fd);
    }
    std.heap.c_allocator.destroy(s);
}

/// Start the poll loop on a background thread.
export fn redis_event_loop_start(state: ?*EventLoopState) callconv(.c) bool {
    const s = state orelse return false;

    s.mutex.lock();
    defer s.mutex.unlock();

    if (s.thread != null) return false;
    s.stop.store(false, .release);
    s.thread = std.Thread.spawn(.{}, pollLoop, .{s}) catch return false;
    return true;
}

/// Stop the poll loop.
export fn redis_event_loop_stop(state: ?*EventLoopState) callconv(.c) void {
    const s = state orelse return;

    s.mutex.lock();
    const thread = s.thread;
    s.stop.store(true, .release);
    s.mutex.unlock();

    // Wake up the poll thread so it can exit
    redis_event_loop_wakeup(state);

    if (thread) |t| {
        t.join();
        s.mutex.lock();
        s.thread = null;
        s.mutex.unlock();
    }
}

/// Notify the poll thread that there's work to do (command queued).
/// This writes to the wakeup pipe to wake up the blocking poll.
export fn redis_event_loop_wakeup(state: ?*EventLoopState) callconv(.c) void {
    const s = state orelse return;
    if (is_windows) return; // TODO: Windows wakeup mechanism
    if (s.wakeup_write_fd < 0) return;

    // Write a single byte to wake up the poll
    const buf = [_]u8{1};
    _ = std.posix.write(s.wakeup_write_fd, &buf) catch {};
}

fn cleanupCallback(privdata: ?*anyopaque) callconv(.c) void {
    const state: *EventLoopState = @ptrCast(@alignCast(privdata orelse return));
    state.stop.store(true, .release);
}

fn pollLoop(state: *EventLoopState) void {
    const ctx = state.ctx;

    while (true) {
        // Check stop flag (lock-free)
        if (state.stop.load(.acquire)) break;

        // Check connection validity (single-threaded access, no lock needed)
        const fd_invalid = if (is_windows)
            ctx.c.fd == ~@as(@TypeOf(ctx.c.fd), 0)
        else
            ctx.c.fd < 0;
        const disconnecting = ctx.c.flags & c.REDIS_DISCONNECTING != 0;

        if (fd_invalid or disconnecting) break;

        // Drain command queue and submit to hiredis (single-threaded hiredis access)
        drainCommandQueue(state);

        // Poll and handle I/O
        const result = if (is_windows)
            pollAndHandleWindows(state)
        else
            pollAndHandlePosix(state);

        if (result < 0) break; // Error or disconnect
    }

    // Notify Dart of disconnect
    if (c.Dart_PostInteger_DL) |postFn| {
        _ = postFn(state.dart_port, MSG_DISCONNECT);
    }
}

/// Drain all pending commands from the queue and submit to hiredis.
/// Called only from the poll thread (single consumer).
fn drainCommandQueue(state: *EventLoopState) void {
    const ctx = state.ctx;

    // Get all queued commands at once (lock-free)
    var node = state.command_queue.drainAll();
    if (node == null) return;

    // Lock context for hiredis calls
    state.ctx_mutex.lock();
    defer state.ctx_mutex.unlock();

    while (node) |n| {
        const next = n.next.load(.acquire);

        // Allocate callback info
        const info = std.heap.c_allocator.create(CallbackInfo) catch {
            n.destroy();
            node = next;
            continue;
        };
        info.* = .{
            .dart_port = n.dart_port,
            .command_id = n.command_id,
            .persistent = false,
        };

        // Submit to hiredis
        const result = c.redisAsyncCommandArgv(
            ctx,
            nativeReplyCallback,
            info,
            n.argc,
            @ptrCast(n.argv),
            n.argvlen,
        );

        if (result != c.REDIS_OK) {
            std.heap.c_allocator.destroy(info);
        }

        // Free the node (we've copied what we need)
        n.destroy();
        node = next;
    }
}

fn pollAndHandlePosix(state: *EventLoopState) i32 {
    const ctx = state.ctx;
    const wakeup_fd = state.wakeup_read_fd;

    // Single-threaded access to ctx, no lock needed
    const fd = ctx.c.fd;
    if (fd < 0) return -1;

    // Poll redis socket for read/write and wakeup pipe for commands
    var fds = [_]std.posix.pollfd{
        .{ .fd = fd, .events = std.posix.POLL.IN | std.posix.POLL.OUT, .revents = 0 },
        .{ .fd = wakeup_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    const nfds: usize = if (wakeup_fd >= 0) 2 else 1;

    // Block until events occur - wakeup pipe signals when commands are queued
    const poll_result = std.posix.poll(fds[0..nfds], -1) catch return -1;

    if (poll_result == 0) return 0; // Timeout (shouldn't happen with -1)

    // Drain wakeup pipe if signaled
    if (nfds > 1 and fds[1].revents & std.posix.POLL.IN != 0) {
        var buf: [64]u8 = undefined;
        _ = std.posix.read(wakeup_fd, &buf) catch {};
    }

    const revents = fds[0].revents;

    // Only treat socket errors as fatal, not wakeup pipe issues
    if (revents & std.posix.POLL.ERR != 0 or revents & std.posix.POLL.HUP != 0) {
        return -1;
    }

    // Handle I/O with lock
    state.ctx_mutex.lock();
    defer state.ctx_mutex.unlock();

    if (revents & std.posix.POLL.OUT != 0) {
        c.redisAsyncHandleWrite(ctx);
    }
    if (revents & std.posix.POLL.IN != 0) {
        c.redisAsyncHandleRead(ctx);
    }

    return 0;
}

fn pollAndHandleWindows(state: *EventLoopState) i32 {
    const ctx = state.ctx;

    // Single-threaded access to ctx, no lock needed
    const socket_raw = ctx.c.fd;

    if (socket_raw == ~@as(@TypeOf(socket_raw), 0)) return -1;

    const ws2 = std.os.windows.ws2_32;
    const socket: ws2.SOCKET = @ptrFromInt(socket_raw);

    var read_fds: ws2.fd_set = .{ .fd_count = 0, .fd_array = undefined };
    var write_fds: ws2.fd_set = .{ .fd_count = 0, .fd_array = undefined };
    var except_fds: ws2.fd_set = .{ .fd_count = 0, .fd_array = undefined };

    read_fds.fd_array[0] = socket;
    read_fds.fd_count = 1;

    write_fds.fd_array[0] = socket;
    write_fds.fd_count = 1;

    except_fds.fd_array[0] = socket;
    except_fds.fd_count = 1;

    // Use short timeout since we don't have wakeup mechanism on Windows yet
    // TODO: Use Windows event object for proper wakeup
    var timeout: ws2.timeval = .{ .sec = 0, .usec = 10000 }; // 10ms

    const result = ws2.select(0, &read_fds, &write_fds, &except_fds, &timeout);

    if (result == ws2.SOCKET_ERROR) return -1;
    if (result == 0) return 0;

    if (except_fds.fd_count > 0) return -1;

    // Handle I/O with lock
    state.ctx_mutex.lock();
    defer state.ctx_mutex.unlock();

    if (write_fds.fd_count > 0) {
        c.redisAsyncHandleWrite(ctx);
    }
    if (read_fds.fd_count > 0) {
        c.redisAsyncHandleRead(ctx);
    }

    return 0;
}

/// Check if the context is connected.
export fn redis_async_is_connected(ctx: ?*c.redisAsyncContext) callconv(.c) bool {
    const async_ctx = ctx orelse return false;
    if (is_windows) {
        if (async_ctx.c.fd == ~@as(@TypeOf(async_ctx.c.fd), 0)) return false;
    } else {
        if (async_ctx.c.fd < 0) return false;
    }
    if (async_ctx.c.flags & c.REDIS_CONNECTED == 0) return false;
    if (async_ctx.c.flags & c.REDIS_DISCONNECTING != 0) return false;
    return true;
}

/// Callback info passed as privdata to hiredis.
const CallbackInfo = struct {
    dart_port: c.Dart_Port_DL,
    command_id: i64,
    /// If true, this is a pub/sub callback that should NOT be freed after each message.
    /// It will be freed when the context is destroyed.
    persistent: bool,
};

/// Serialize a redisReply to a Dart_CObject.
/// Returns a newly allocated Dart_CObject that must be freed after posting.
/// The serialization format is:
/// - NULL reply: null
/// - STRING/STATUS/ERROR/VERB: [type, string_bytes]
/// - INTEGER: [type, int64]
/// - DOUBLE: [type, double_as_string_bytes]
/// - BOOL: [type, bool_as_int (0/1)]
/// - NIL: [type]
/// - ARRAY/MAP/SET/PUSH: [type, element1, element2, ...]
fn serializeReply(reply: *c.redisReply, allocator: std.mem.Allocator) ?*c.Dart_CObject {
    const obj = allocator.create(c.Dart_CObject) catch return null;

    switch (reply.type) {
        REDIS_REPLY_NIL => {
            obj.* = .{
                .type = c.Dart_CObject_kNull,
                .value = undefined,
            };
        },
        REDIS_REPLY_STRING, REDIS_REPLY_STATUS, REDIS_REPLY_ERROR, REDIS_REPLY_VERB, REDIS_REPLY_BIGNUM, REDIS_REPLY_DOUBLE => {
            // Copy string data
            const len = reply.len;
            const str_copy = allocator.alloc(u8, len) catch {
                allocator.destroy(obj);
                return null;
            };
            if (reply.str != null and len > 0) {
                @memcpy(str_copy, reply.str[0..len]);
            }

            // Create array [type, string_bytes]
            const values = allocator.alloc(*c.Dart_CObject, 2) catch {
                allocator.free(str_copy);
                allocator.destroy(obj);
                return null;
            };

            const type_obj = allocator.create(c.Dart_CObject) catch {
                allocator.free(values);
                allocator.free(str_copy);
                allocator.destroy(obj);
                return null;
            };
            type_obj.* = .{
                .type = c.Dart_CObject_kInt32,
                .value = .{ .as_int32 = reply.type },
            };

            const str_obj = allocator.create(c.Dart_CObject) catch {
                allocator.destroy(type_obj);
                allocator.free(values);
                allocator.free(str_copy);
                allocator.destroy(obj);
                return null;
            };
            str_obj.* = .{
                .type = c.Dart_CObject_kTypedData,
                .value = .{
                    .as_typed_data = .{
                        .type = c.Dart_TypedData_kUint8,
                        .length = @intCast(len),
                        .values = str_copy.ptr,
                    },
                },
            };

            values[0] = type_obj;
            values[1] = str_obj;

            obj.* = .{
                .type = c.Dart_CObject_kArray,
                .value = .{
                    .as_array = .{
                        .length = 2,
                        .values = @ptrCast(values.ptr),
                    },
                },
            };
        },
        REDIS_REPLY_INTEGER => {
            // Create array [type, int64]
            const values = allocator.alloc(*c.Dart_CObject, 2) catch {
                allocator.destroy(obj);
                return null;
            };

            const type_obj = allocator.create(c.Dart_CObject) catch {
                allocator.free(values);
                allocator.destroy(obj);
                return null;
            };
            type_obj.* = .{
                .type = c.Dart_CObject_kInt32,
                .value = .{ .as_int32 = reply.type },
            };

            const int_obj = allocator.create(c.Dart_CObject) catch {
                allocator.destroy(type_obj);
                allocator.free(values);
                allocator.destroy(obj);
                return null;
            };
            int_obj.* = .{
                .type = c.Dart_CObject_kInt64,
                .value = .{ .as_int64 = reply.integer },
            };

            values[0] = type_obj;
            values[1] = int_obj;

            obj.* = .{
                .type = c.Dart_CObject_kArray,
                .value = .{
                    .as_array = .{
                        .length = 2,
                        .values = @ptrCast(values.ptr),
                    },
                },
            };
        },
        REDIS_REPLY_BOOL => {
            // Create array [type, bool_as_int]
            const values = allocator.alloc(*c.Dart_CObject, 2) catch {
                allocator.destroy(obj);
                return null;
            };

            const type_obj = allocator.create(c.Dart_CObject) catch {
                allocator.free(values);
                allocator.destroy(obj);
                return null;
            };
            type_obj.* = .{
                .type = c.Dart_CObject_kInt32,
                .value = .{ .as_int32 = reply.type },
            };

            const bool_obj = allocator.create(c.Dart_CObject) catch {
                allocator.destroy(type_obj);
                allocator.free(values);
                allocator.destroy(obj);
                return null;
            };
            bool_obj.* = .{
                .type = c.Dart_CObject_kInt32,
                .value = .{ .as_int32 = if (reply.integer != 0) @as(i32, 1) else @as(i32, 0) },
            };

            values[0] = type_obj;
            values[1] = bool_obj;

            obj.* = .{
                .type = c.Dart_CObject_kArray,
                .value = .{
                    .as_array = .{
                        .length = 2,
                        .values = @ptrCast(values.ptr),
                    },
                },
            };
        },
        REDIS_REPLY_ARRAY, REDIS_REPLY_MAP, REDIS_REPLY_SET, REDIS_REPLY_PUSH => {
            const elements = reply.elements;
            // Create array [type, element1, element2, ...]
            const values = allocator.alloc(*c.Dart_CObject, elements + 1) catch {
                allocator.destroy(obj);
                return null;
            };

            const type_obj = allocator.create(c.Dart_CObject) catch {
                allocator.free(values);
                allocator.destroy(obj);
                return null;
            };
            type_obj.* = .{
                .type = c.Dart_CObject_kInt32,
                .value = .{ .as_int32 = reply.type },
            };
            values[0] = type_obj;

            // Recursively serialize elements
            for (0..elements) |i| {
                const element_reply = reply.element[i];
                if (element_reply) |er| {
                    const element_obj = serializeReply(er, allocator);
                    if (element_obj) |eo| {
                        values[i + 1] = eo;
                    } else {
                        // Allocation failed, clean up
                        for (0..i + 1) |j| {
                            freeSerializedReply(values[j], allocator);
                        }
                        allocator.free(values);
                        allocator.destroy(obj);
                        return null;
                    }
                } else {
                    // Null element
                    const null_obj = allocator.create(c.Dart_CObject) catch {
                        for (0..i + 1) |j| {
                            freeSerializedReply(values[j], allocator);
                        }
                        allocator.free(values);
                        allocator.destroy(obj);
                        return null;
                    };
                    null_obj.* = .{
                        .type = c.Dart_CObject_kNull,
                        .value = undefined,
                    };
                    values[i + 1] = null_obj;
                }
            }

            obj.* = .{
                .type = c.Dart_CObject_kArray,
                .value = .{
                    .as_array = .{
                        .length = @intCast(elements + 1),
                        .values = @ptrCast(values.ptr),
                    },
                },
            };
        },
        else => {
            // Unknown type, return null
            obj.* = .{
                .type = c.Dart_CObject_kNull,
                .value = undefined,
            };
        },
    }

    return obj;
}

/// Free a serialized reply and all its allocations.
fn freeSerializedReply(obj: *c.Dart_CObject, allocator: std.mem.Allocator) void {
    switch (obj.type) {
        c.Dart_CObject_kArray => {
            const arr = obj.value.as_array;
            const values: [*]*c.Dart_CObject = @ptrCast(arr.values);
            for (0..@intCast(arr.length)) |i| {
                freeSerializedReply(values[i], allocator);
            }
            const slice = values[0..@intCast(arr.length)];
            allocator.free(slice);
        },
        c.Dart_CObject_kTypedData => {
            const td = obj.value.as_typed_data;
            if (td.length > 0) {
                const slice = td.values[0..@intCast(td.length)];
                allocator.free(slice);
            }
        },
        else => {},
    }
    allocator.destroy(obj);
}

/// Native callback invoked by hiredis when a reply arrives.
/// Copies the reply data and posts it to Dart before hiredis frees it.
fn nativeReplyCallback(
    _: ?*c.redisAsyncContext,
    reply_ptr: ?*anyopaque,
    privdata: ?*anyopaque,
) callconv(.c) void {
    const info_ptr = privdata orelse return;
    const info: *CallbackInfo = @ptrCast(@alignCast(info_ptr));

    // Copy values before potentially freeing
    const command_id = info.command_id;
    const dart_port = info.dart_port;
    const persistent = info.persistent;

    // Only free non-persistent callbacks (pub/sub callbacks are persistent)
    if (!persistent) {
        std.heap.c_allocator.destroy(info);
    }

    const postFn = c.Dart_PostCObject_DL orelse return;
    const allocator = std.heap.c_allocator;

    // Create message: [commandId, serializedReply]
    var command_id_obj: c.Dart_CObject = .{
        .type = c.Dart_CObject_kInt64,
        .value = .{ .as_int64 = command_id },
    };

    var reply_obj: c.Dart_CObject = undefined;
    var serialized_reply: ?*c.Dart_CObject = null;

    if (reply_ptr) |rp| {
        const reply: *c.redisReply = @ptrCast(@alignCast(rp));
        serialized_reply = serializeReply(reply, allocator);
        if (serialized_reply) |sr| {
            reply_obj = sr.*;
        } else {
            // Allocation failed, send null
            reply_obj = .{
                .type = c.Dart_CObject_kNull,
                .value = undefined,
            };
        }
    } else {
        // Null reply
        reply_obj = .{
            .type = c.Dart_CObject_kNull,
            .value = undefined,
        };
    }

    var values: [2]*c.Dart_CObject = .{ &command_id_obj, &reply_obj };

    var array_obj: c.Dart_CObject = .{
        .type = c.Dart_CObject_kArray,
        .value = .{
            .as_array = .{
                .length = 2,
                .values = @ptrCast(&values),
            },
        },
    };

    _ = postFn(dart_port, &array_obj);

    // Free the serialized reply after posting
    if (serialized_reply) |sr| {
        freeSerializedReply(sr, allocator);
    }
}

/// Queue a command without waking up the poll thread.
/// Use redis_event_loop_wakeup after queuing multiple commands to batch wakeups.
export fn redis_async_command_enqueue(
    state: ?*EventLoopState,
    dart_port: c.Dart_Port_DL,
    command_id: i64,
    argc: c_int,
    argv: [*c][*c]const u8,
    argvlen: [*c]const usize,
) callconv(.c) c_int {
    const s = state orelse return -1;

    // Create command node (copies all data)
    const node = CommandNode.create(dart_port, command_id, argc, argv, argvlen) orelse return -1;

    // Push to lock-free queue (no mutex needed)
    s.command_queue.push(node);

    return 0;
}

/// Send an async command by pushing to the lock-free queue and waking up the poll thread.
/// For pipelining, use redis_async_command_enqueue + redis_event_loop_wakeup instead.
export fn redis_async_command(
    state: ?*EventLoopState,
    dart_port: c.Dart_Port_DL,
    command_id: i64,
    argc: c_int,
    argv: [*c][*c]const u8,
    argvlen: [*c]const usize,
) callconv(.c) c_int {
    const result = redis_async_command_enqueue(state, dart_port, command_id, argc, argv, argvlen);
    if (result == 0) {
        redis_event_loop_wakeup(state);
    }
    return result;
}

/// Send a pub/sub command (SUBSCRIBE, PSUBSCRIBE, etc.).
/// The callback for pub/sub commands is persistent and will be called for each message.
/// The callback info will be freed when the context is destroyed, not after each message.
export fn redis_async_pubsub_command(
    state: ?*EventLoopState,
    dart_port: c.Dart_Port_DL,
    command_id: i64,
    argc: c_int,
    argv: [*c][*c]const u8,
    argvlen: [*c]const usize,
) callconv(.c) c_int {
    const s = state orelse return -1;

    // For pub/sub, we need to submit directly to hiredis with a persistent callback
    // We can't use the queue because we need to mark the callback as persistent

    // Allocate callback info
    const info = std.heap.c_allocator.create(CallbackInfo) catch return -1;
    info.* = .{
        .dart_port = dart_port,
        .command_id = command_id,
        .persistent = true, // This callback will be called multiple times
    };

    // Lock context for hiredis call
    s.ctx_mutex.lock();
    defer s.ctx_mutex.unlock();

    // Submit directly to hiredis (not through the queue)
    const result = c.redisAsyncCommandArgv(
        s.ctx,
        nativeReplyCallback,
        info,
        argc,
        @ptrCast(argv),
        argvlen,
    );

    if (result != c.REDIS_OK) {
        std.heap.c_allocator.destroy(info);
        return -1;
    }

    // Wake up the poll thread to process the command
    redis_event_loop_wakeup(state);

    return 0;
}
