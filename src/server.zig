const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;
const posix = std.posix;
const linux = os.linux; // either signalfd or high-level event libraries
const List = std.ArrayListUnmanaged;
const Map = std.ArrayHashMapUnmanaged(posix.socket_t, void, ConnectionContext, false);
const AddrList = List(net.Address);
const PollList = List(posix.pollfd);
const mem = std.mem;
const Allocator = mem.Allocator;
const execute = @import("execute.zig");

pub const Server = struct {
    const Self = @This();
    const ContextError = posix.PollError;
    const SERVER = 0; // index of server fd
    const SIGNAL = 1; // index of signal fd
    const FIRST = 2; // index of first item in fds that belongs to client

    n: usize,
    server: net.Server,
    fds: Map,
    clients: AddrList, // list of addresses for connected clients
    poll_list: PollList,
    alloc: Allocator,

    pub fn init(alloc: Allocator, address: net.Address) !Self {
        var self: Self = undefined;

        self.alloc = alloc;
        self.n = 0;
        self.fds = Map{};
        errdefer self.fds.deinit(self.alloc);
        self.clients = AddrList{};
        errdefer self.clients.deinit(self.alloc);
        self.poll_list = PollList{};
        errdefer self.poll_list.deinit(self.alloc);

        self.server = try net.Address.listen(
            address,
            .{ .reuse_address = true },
        );
        errdefer self.server.deinit();
        try self.insertSocket(self.server.stream.handle);

        const signal_fd = try getSignalFd(&[_]u6{ linux.SIG.TERM, linux.SIG.INT });
        try self.insertSocket(signal_fd);

        return self;
    }

    pub fn deinit(self: *Self) void {
        std.debug.print("deinitialising server at {}\n", .{self.server.listen_address});

        for (FIRST..self.fds.entries.len) |i|
            self.getStream(self.fds.keys()[i]).?.close();

        self.server.deinit();
        posix.close(self.fds.keys()[SIGNAL]);

        // // deinitialise memory
        self.fds.deinit(self.alloc);
        self.clients.deinit(self.alloc);
        self.poll_list.deinit(self.alloc);
    }

    pub fn waitFn(self: *Self) !?execute.Payload {
        self.n += 1;
        std.debug.print("called callback", .{});
        std.debug.assert(self.fds.entries.len > 0);

        const fds: []posix.pollfd = self.poll_list.items;
        const events = try posix.poll(fds, 100); // wait forever
        std.debug.print(" and done polling\n", .{});

        if (events == 0) return null;

        if (ready(fds[SERVER])) |_| {
            const conn: net.Server.Connection = try self.server.accept();
            try self.insertConnection(conn);
        }

        if (ready(fds[SIGNAL])) |fd| {
            const info = try getSignal(fd);
            std.debug.print("got signal: {}\n", .{info.signo});

            switch (info.signo) {
                linux.SIG.INT, linux.SIG.TERM => return execute.Payload{ .exit = {} },
                else => {},
            }
        }

        for (FIRST..fds.len) |i| if (ready(fds[i])) |fd| {
            const connection = self.getConnection(fd).?;
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

    fn getPollfdRaw(socket: posix.socket_t) posix.pollfd {
        return posix.pollfd{
            .fd = socket,
            .events = posix.POLL.IN, // ready to read
            .revents = 0,
        };
    }

    fn insertSocket(self: *Self, socket: posix.socket_t) !void {
        try self.poll_list.append(self.alloc, getPollfdRaw(socket));
        try self.fds.putNoClobber(self.alloc, socket, {});
    }

    fn insertConnection(self: *Self, connection: net.Server.Connection) !void {
        try self.insertSocket(connection.stream.handle);
        try self.clients.append(self.alloc, connection.address);
        std.debug.print("sender {} connected\n", .{connection.address});
    }

    fn deleteSocket(self: *Self, socket: posix.socket_t) bool {
        const index = self.fds.getIndex(socket) orelse return false;

        _ = self.poll_list.swapRemove(index);
        self.fds.swapRemoveAt(index);

        return true;
    }

    fn deleteConnection(self: *Self, connection: net.Server.Connection) void {
        const addr = self.getAddress(connection.stream.handle).?;
        std.debug.print("removing sender {}\n", .{addr});

        connection.stream.close();
        std.debug.assert(self.deleteSocket(connection.stream.handle));
    }

    fn getStream(self: *Self, socket: posix.socket_t) ?net.Stream {
        return if (self.getConnection(socket)) |c| c.stream else null;
    }

    fn getAddress(self: *Self, socket: posix.socket_t) ?net.Address {
        return if (self.getConnection(socket)) |c| c.address else null;
    }

    fn getConnection(self: *Self, socket: posix.socket_t) ?net.Server.Connection {
        const index = self.fds.getIndex(socket) orelse return null;
        if (index < FIRST) return null; // server socket or signalfd

        return net.Server.Connection{
            .address = self.clients.items[index - FIRST],
            .stream = net.Stream{ .handle = socket },
        };
    }

    fn ready(fd: posix.pollfd) ?posix.socket_t {
        return if (fd.revents & posix.POLL.IN != 0) fd.fd else null;
    }

    // from https://gist.github.com/lithdew/79717cd161490bc1895a6df3f610a565
    fn getSignalFd(signals: []const u6) !posix.socket_t {
        var mask: linux.sigset_t = std.mem.zeroes(linux.sigset_t);

        for (signals) |signal|
            linux.sigaddset(&mask, signal);

        _ = posix.sigprocmask(linux.SIG.BLOCK, &mask, null);

        return posix.signalfd(-1, &mask, 0);
    }

    fn getSignal(signal_fd: posix.socket_t) !linux.signalfd_siginfo {
        var info: linux.signalfd_siginfo = undefined;
        const buf: []u8 = std.mem.asBytes(&info);
        const n = try posix.read(signal_fd, buf);
        std.debug.assert(n == buf.len);
        return info;
    }
};

// inspired by https://stackoverflow.com/a/77609482
// hashing context that only considers socket descriptor
const ConnectionContext = struct {
    const Self = @This();
    const Connection = posix.socket_t;

    pub fn hash(_: Self, key: Connection) u32 { // is a cast good enough?
        return @truncate(std.hash.Wyhash.hash(0, mem.asBytes(&key)));
    }

    pub fn eql(_: Self, a: Connection, b: Connection, _: usize) bool {
        return a == b;
    }
};
