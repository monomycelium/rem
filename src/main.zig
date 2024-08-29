const std = @import("std");
const Server = @import("server.zig").Server;
const os = std.os;
const log = std.log;
const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;

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
    comptime waitFn: fn (@TypeOf(context)) anyerror!bool,
) anyerror!u32 {
    const path = args[0].?;
    var ret: u32 = 0;

    const fork_pid: posix.pid_t = try posix.fork();
    if (fork_pid == 0) {
        const err: posix.ExecveError = posix.execveZ(path, args, envp);
        log.err("failed to execute: {}", .{err});
        return err; // is this allowed?
    } else {
        log.info("executing command with pid: {}", .{fork_pid});
        var wait_result = posix.waitpid(fork_pid, posix.W.NOHANG);

        outer: while (wait_result.pid != fork_pid) {
            log.info("received: {}", .{wait_result.pid});

            if (try waitFn(context)) {
                log.info("killing process {}", .{fork_pid});
                // TODO implement killing process
                wait_result = posix.waitpid(fork_pid, 0);
                break :outer;
            }

            std.time.sleep(100 * std.time.ns_per_ms); // poll(2) can handle this
            wait_result = posix.waitpid(fork_pid, posix.W.NOHANG);
        }

        const status = wait_result.status;
        if (posix.W.IFEXITED(status)) {
            // the macros ensure that the correct bits are used as the exit code
            ret = posix.W.EXITSTATUS(status);
            log.info("command exited with code: {}", .{ret});
        }
    }

    return ret;
}

const ArgumentResult = struct {
    const Self = @This();

    buffer: []u8,
    argv: [:null]?[*:0]u8,

// i only did this because passing the arguments directly from argv gave me EFAULT
// TODO find if putting argv on heap is necessary
fn init(
    slice: []const [*:0]const u8,
    alloc: Allocator,
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

    fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.buffer);
        alloc.free(self.argv);
    }
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const addr = std.net.Address.parseIp("0.0.0.0", 8080) catch unreachable;
    var server = try Server.init(alloc, addr);

    std.debug.print("listening on {}!\n", .{addr});
    const connection = try server.server.accept();
    const writer = connection.stream.writer();
    try writer.print("Hello, world!\n", .{});
    connection.stream.close();
    std.debug.print("wrote to server!\n", .{});

    // argument after the current executable path will be passed as argv
    if (os.argv.len < 2) {
        log.err("usage: {s} <executable> ...", .{os.argv[0]});
        return error.InvalidUsage;
    }

    const res = try ArgumentResult.init(os.argv[1..], alloc);
    const envs: ?[*:0]const u8 = null;
    // TODO propagate environment using `std.os.environ`
    _ = try execute(res.argv, @ptrCast(&envs), &server, Server.waitFn);

    log.info("called callback {} times", .{server.n});
    server.deinit();
}
