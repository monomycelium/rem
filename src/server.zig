const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;
const posix = std.posix;
const Map = std.ArrayHashMapUnmanaged(net.Server.Connection, posix.pollfd, ConnectionContext, false);
const mem = std.mem;
const Allocator = mem.Allocator;
const execute = @import("execute.zig");

pub const Server = struct {
    const Self = @This();
    const ContextError = posix.PollError;

    n: usize,
    server: net.Server,
    fds: Map,
    alloc: Allocator,

    pub fn init(alloc: Allocator, address: net.Address) !Self {
        var self: Self = undefined;

        self.alloc = alloc;
        self.n = 0;
        self.server = try net.Address.listen(
            address,
            .{ .reuse_address = true },
        );
        self.fds = Map{};

        const connection = net.Server.Connection{
            .address = self.server.listen_address,
            .stream = self.server.stream,
        };
        try self.insertConnection(connection);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.server.deinit();
        self.fds.deinit(self.alloc);
    }

    pub fn waitFn(self: *Self) !?execute.Payload {
        self.n += 1;
        std.debug.print("called callback", .{});
        std.debug.assert(self.fds.entries.len > 0);

        const fds: []posix.pollfd = self.fds.values();
        const events = try posix.poll(fds, 100); // wait forever
        std.debug.print(" and done polling\n", .{});

        if (events == 0) return null;

        if (ready(fds[0])) |_| {
            const conn: net.Server.Connection = try self.server.accept();
            std.debug.print("sender {} connected\n", .{conn.address});
            try self.insertConnection(conn);
        }

        for (1..fds.len) |i| if (ready(fds[i])) |fd| {
            const connection = self.connectionFromHandle(fd).?;
            std.debug.print("reading stuff...", .{});
            var buffer: [1]u8 = undefined;
            const n = try connection.stream.read(buffer[0..]);
            const message = buffer[0..n];
            std.debug.print("\rsender {} sent: {s}\n", .{ connection.address, message });

            if (message.len == 0) {
                self.deleteConnection(connection);
                continue;
            }

            const command = std.meta.intToEnum(
                execute.Command,
                message[0],
            ) catch {
                // invalid enum tag
                std.debug.print("invalid enum tag; ", .{});
                self.deleteConnection(connection);
                continue;
            };

            const payload = execute.Payload.getPayload(
                connection.stream.reader(),
                self.alloc,
                command,
            ) catch |e| switch (e) {
                error.InvalidPayload, error.EndOfStream => {
                    std.debug.print("invalid payload; ", .{});
                    self.deleteConnection(connection);
                    continue;
                },
                else => return e,
            };
            std.debug.print("{any}\n", .{payload});
            return payload;
        };

        return null;
    }

    pub fn get_fd(self: Self) posix.socket_t {
        return self.server.stream.handle;
    }

    fn get_pollfd(connection: net.Server.Connection) posix.pollfd {
        return posix.pollfd{
            .fd = connection.stream.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        };
    }

    fn insertConnection(self: *Self, connection: net.Server.Connection) !void {
        return self.fds.putNoClobber(
            self.alloc,
            connection,
            get_pollfd(connection),
        );
    }

    /// Returns connection with undefined address.
    fn dummyConnection(fd: posix.socket_t) net.Server.Connection {
        return net.Server.Connection{
            .address = undefined,
            .stream = net.Stream{ .handle = fd },
        };
    }

    fn deleteConnection(self: *Self, connection: net.Server.Connection) void {
        std.debug.print("removing sender {}\n", .{connection.address});
        connection.stream.close();
        std.debug.assert(self.fds.swapRemove(connection));
    }

    fn connectionFromHandle(self: Self, fd: posix.socket_t) ?net.Server.Connection {
        const dummy_connection = dummyConnection(fd);
        return self.fds.getKey(dummy_connection);
    }

    fn ready(fd: posix.pollfd) ?posix.socket_t {
        return if (fd.revents & posix.POLL.IN != 0) fd.fd else null;
    }
};

// inspired by https://stackoverflow.com/a/77609482
// hashing context that only considers socket descriptor
const ConnectionContext = struct {
    const Self = @This();
    const Connection = net.Server.Connection;

    pub fn hash(_: Self, key: Connection) u32 { // is a cast good enough?
        return @truncate(std.hash.Wyhash.hash(0, mem.asBytes(&key.stream.handle)));
    }

    pub fn eql(_: Self, a: Connection, b: Connection, _: usize) bool {
        return a.stream.handle == b.stream.handle;
    }
};
