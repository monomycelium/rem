const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;
const posix = std.posix;
const Map = std.AutoHashMap(net.Server.Connection, void);

pub const Server = struct {
    const Self = @This();
    const ContextError = posix.PollError;

    n: usize,
    server: net.Server,
    fd_s: Map,

    pub fn init(alloc: std.mem.Allocator, address: net.Address) !Self {
        var self: Self = undefined;
        
        self.fd_s = Map.init(alloc);
        self.n = 0;
        self.server = try net.Address.listen(
            address,
            .{ .reuse_address = true },
        );

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.server.deinit();
        self.fd_s.deinit();
    }

    pub fn waitFn(self: *Self) !bool {
        self.n += 1;
        std.debug.print("called callback\n", .{});

        // should this be saved in Server?
        var fds: [1]posix.pollfd = undefined;
        fds[0].fd = self.get_fd();
        fds[0].events = posix.POLL.IN;
        _ = try posix.poll(fds[0..], -1);

        if (fds[0].revents & posix.POLL.IN != 0) { // TODO update fd_s
            std.debug.print("got a connection! see you!\n", .{});
            return true;
        }

        std.debug.print("unexpected event!\n", .{});
        return false;
    }

    pub fn get_fd(self: Self) posix.socket_t {
        return self.server.stream.handle;
    }
};
