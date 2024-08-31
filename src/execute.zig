const std = @import("std");
const mem = std.mem;
const os = std.os;
const posix = std.posix;
const log = std.log;
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

pub const ArgumentResult = struct {
    const Self = @This();

    buffer: []u8,
    argv: [:null]?[*:0]u8,

    // i only did this because passing the arguments directly from argv gave me EFAULT
    // TODO find if putting argv on heap is necessary
    pub fn init(
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

    pub fn deinit(self: Self, alloc: Allocator) void {
        alloc.free(self.buffer);
        alloc.free(self.argv);
    }
};

// portable signals from https://en.wikipedia.org/wiki/Signal_%28IPC%29#POSIX_signals
// TODO make this exhaustive if it is possible to optionally check if value is defined...
pub const Signal = enum(u8) {
    abrt = 6,
    alrm = 14,
    fpe = 8,
    hup = 1,
    ill = 4,
    kill = 9,
    pipe = 13,
    quit = 3,
    segv = 11,
    term = 15,
    trap = 5,

    pub fn read(reader: anytype) !@This() {
        return std.meta.intToEnum(
            @This(),
            try reader.readByte(),
        );
    }
};

pub const Executable = struct {
    const Self = @This();

    meta: posix.mode_t,
    data: []const u8,
    alloc: Allocator,

    pub fn write(self: Self, path: [*:0]const u8) !void {
        const file = try std.fs.cwd().openFileZ(
            path,
            .{ .mode = .write_only },
        );
        defer file.close();

        try file.writeAll(self.data);
    }

    pub fn read(reader: anytype, allocator: Allocator) !Self {
        var self: Self = undefined;

        self.alloc = allocator;
        self.meta = try reader.readInt(posix.mode_t, .big);

        const n: usize = try reader.readInt(usize, .big);
        const data: []u8 = try allocator.alloc(u8, n);
        errdefer self.alloc.free(data);

        try reader.readNoEof(data);
        self.data = data;

        return self;
    }

    pub fn deinit(self: Self) void {
        self.alloc.free(self.data);
    }
};

pub const Command = enum(u8) {
    kill = 'k',
    reload = 'r',
    watch = 'w',
    stderr = 'e',
    upload = 'u',

    pub fn which(self: @This()) []const u8 {
        return switch (self) {
            .kill => "killing process",
            .reload => "reloading process",
            .watch => "watching stdout",
            .stderr => "watching stderr",
            .upload => "updating binary",
        };
    }
};

pub const Payload = union(Command) {
    const Self = @This();
    kill: Signal,
    reload: void,
    watch: bool,
    stderr: bool,
    upload: Executable,

    // map '0' to false and '1' to true
    fn readBool(reader: anytype) !bool {
        const byte = try reader.readByte();

        return switch (byte) {
            '0' => false,
            '1' => true,
            else => error.InvalidPayload,
        };
    }

    pub fn getPayload(reader: anytype, allocator: Allocator, command: Command) !Self {
        return switch (command) {
            .kill => Self{ .kill = try Signal.read(reader) },
            .reload => Self{ .reload = {} },
            .watch => Self{ .watch = try readBool(reader) },
            .stderr => Self{ .stderr = try readBool(reader) },
            .upload => Self{ .upload = try Executable.read(reader, allocator) },
        };
    }

    pub fn deinit(self: Self) void {
        switch (self) {
            .upload => |exec| exec.deinit(),
            else => {},
        }
    }
};

// TODO read stdout and stderr using pipes...
pub fn execute(
    path: [:0]const u8, // path to executable
    args: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    context: anytype,
    comptime waitFn: fn (@TypeOf(context)) anyerror!?Payload,
) anyerror!u32 {
    var ret: u32 = 0;

    const fork_pid: posix.pid_t = try posix.fork();
    if (fork_pid == 0) {
        const err: posix.ExecveError = posix.execveZ(path, args, envp);
        log.err("failed to execute: {}", .{err});
        return err; // is this allowed?
    } else {
        log.info("executing command with pid: {}", .{fork_pid});
        var wait_result = posix.waitpid(fork_pid, posix.W.NOHANG);

        while (wait_result.pid != fork_pid) {
            if (try waitFn(context)) |payload| payload.deinit();

            // std.time.sleep(100 * std.time.ns_per_ms); // poll(2) can handle this
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
