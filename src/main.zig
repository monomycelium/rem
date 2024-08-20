const std = @import("std");
const os = std.os;
const log = std.log;
const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;

const c = @cImport({
    @cInclude("sys/wait.h"); // WIFEXITED and WEXITSTATUS
});

const Server = struct {
    const Self = @This();

    n: usize,

    pub fn init() Self {
        return Self{ .n = 0 };
    }

    pub fn waitFn(self: *Self) bool {
        self.n += 1;
        return false;
    }
};

fn copySentinel(
    comptime T: type,
    comptime sentinel: T,
    dest: [*:sentinel]T,
    source: [*:sentinel]const T,
) usize {
    var i: usize = 0;
    while (source[i] != sentinel) : (i += 1) dest[i] = source[i];
    dest[i] = sentinel;
    return i;
}

fn execute(
    args: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    context: anytype,
    comptime waitFn: fn (@TypeOf(context)) bool,
) posix.ExecveError!u32 {
    const path = args[0].?;
    var ret: u32 = 0;

    const fork_pid: posix.pid_t = try posix.fork();
    if (fork_pid == 0) {
        const err: posix.ExecveError = posix.execveZ(path, args, envp);
        log.err("failed to execute: {}", .{err});
        return err; // is this allowed?
    } else {
        log.info("executing command with pid: {}", .{fork_pid});
        var wait_result = posix.waitpid(fork_pid, c.WNOHANG);

        outer: while (wait_result.pid != fork_pid) {
            log.info("received: {}", .{wait_result.pid});

            if (waitFn(context)) {
                log.info("killing process {}", .{fork_pid});
                // TODO implement killing process
                wait_result = posix.waitpid(fork_pid, 0);
                break :outer;
            }

            std.time.sleep(100 * std.time.ns_per_ms);
            wait_result = posix.waitpid(fork_pid, c.WNOHANG);
        }

        const status = @as(c_int, @bitCast(wait_result.status));
        if (c.WIFEXITED(status)) { // the macros ensure that the correct bits are used as the exit code
            ret = @bitCast(c.WEXITSTATUS(status));
            log.info("command exited with code: {}", .{ret});
        }
    }

    return ret;
}

const ArgumentResult = struct {
    buffer: []u8,
    argv: [:null]?[*:0]u8,
};

// remember to call free on `buffer` and `argv`!
// i only did this because passing the arguments directly from argv gave me EFAULT
// TODO find if putting argv on heap is necessary
fn argvFromSlice(
    alloc: Allocator,
    slice: []const [*:0]const u8,
) !ArgumentResult {
    var res: ArgumentResult = undefined;

    res.argv = try alloc.allocSentinel(?[*:0]u8, slice.len, null);
    errdefer alloc.free(res.argv);

    // allocate the buffer

    var n: usize = 0;
    for (0..res.argv.len) |i| {
        const ptr = os.argv[i + 1];
        const len = mem.indexOfSentinel(u8, 0, ptr);
        n += len + 1;
    }

    res.buffer = try alloc.alloc(u8, n);
    errdefer alloc.free(res.buffer);

    // copy the arguments to the buffer

    var x: usize = 0;
    for (0..res.argv.len) |i| {
        const ptr: [*:0]u8 = @ptrCast(&res.buffer[x]);
        res.argv[i] = ptr;
        const len: usize = copySentinel(u8, 0, ptr, slice[i]);
        x += len + 1;
    }
    std.debug.assert(x == n);

    return res;
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var server = Server.init(); // TODO use TCP sockets

    // argument after the current executable path will be passed as argv
    if (os.argv.len < 2) {
        log.err("usage: {s} <executable> ...", .{os.argv[0]});
        return error.InvalidUsage;
    }

    const res: ArgumentResult = try argvFromSlice(alloc, os.argv[1..]);
    const envs: ?[*:0]const u8 = null; // TODO propagate environment
    _ = try execute(res.argv, @ptrCast(&envs), &server, Server.waitFn);

    log.info("called callback {} times", .{server.n});
}
