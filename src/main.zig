const std = @import("std");
const Server = @import("server.zig").Server;
const execute = @import("execute.zig");
const os = std.os;
const log = std.log;
const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const addr = std.net.Address.parseIp("0.0.0.0", 8080) catch unreachable;
    var server = try Server.init(alloc, addr);

    // argument after the current executable path will be passed as argv
    if (os.argv.len < 2) {
        log.err("usage: {s} <executable> ...", .{os.argv[0]});
        return error.InvalidUsage;
    }

    const res = try execute.ArgumentResult.init(os.argv[1..], alloc);
    defer res.deinit(alloc);
    // TODO propagate environment using `std.os.environ`
    const envs: ?[*:0]const u8 = null;
    const path = mem.span(res.argv[0].?);
    _ = try execute.execute(path, res.argv, @ptrCast(&envs), &server, Server.waitFn);

    log.info("called callback {} times", .{server.n});
    server.deinit();
}
