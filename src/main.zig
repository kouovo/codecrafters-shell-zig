const std = @import("std");

const Builtin = enum { exit, echo, type, pwd, unknown, cd };

fn parseBuiltin(name: []const u8) Builtin {
    return std.meta.stringToEnum(Builtin, name) orelse .unknown;
}

pub const Tokenizer = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    buffer: []u8,
    index: usize = 0,
    start: usize = 0,
    end: usize = 0,

    const Self = @This();
    const Msg = enum { normal, single, double, done };

    pub const InitError = error{OutOfMemory};
    pub const Error = error{UnclosedQuote};

    pub fn init(allocator: std.mem.Allocator, src: []const u8) InitError!Self {
        const buffer = try allocator.alloc(u8, src.len + 1);
        errdefer allocator.free(buffer);
        return .{ .allocator = allocator, .src = src, .buffer = buffer };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }

    pub fn next(self: *Self) Error!?[:0]const u8 {
        while (self.index < self.src.len and isBlank(self.src[self.index])) self.index += 1;
        if (self.index >= self.src.len) return null;

        self.start = self.end;
        var m: Msg = .normal;
        while (true) {
            m = switch (m) {
                .normal => try self.handleNormal(),
                .single => try self.handleSingle(),
                .double => try self.handleDouble(),
                .done => return self.finish(),
            };
        }
    }

    fn handleNormal(self: *Self) Error!Msg {
        if (self.index >= self.src.len) return .done;
        const c = self.src[self.index];
        switch (c) {
            ' ', '\t' => return .done,
            '\'' => {
                self.index += 1;
                return .single;
            },
            '"' => {
                self.index += 1;
                return .double;
            },
            '\\' => {
                self.index += 1;
                if (self.index < self.src.len) {
                    self.write(self.src[self.index]);
                    self.index += 1;
                }
                return .normal;
            },
            else => {
                self.write(c);
                self.index += 1;
                return .normal;
            },
        }
    }

    fn handleSingle(self: *Self) Error!Msg {
        if (self.index >= self.src.len) return Error.UnclosedQuote;
        const c = self.src[self.index];
        switch (c) {
            '\'' => {
                self.index += 1;
                return .normal;
            },
            else => {
                self.write(c);
                self.index += 1;
                return .single;
            },
        }
    }

    fn handleDouble(self: *Self) Error!Msg {
        if (self.index >= self.src.len) return Error.UnclosedQuote;
        const c = self.src[self.index];
        switch (c) {
            '"' => {
                self.index += 1;
                return .normal;
            },
            '\\' => {
                if (self.index + 1 >= self.src.len) {
                    self.write(c);
                    self.index += 1;
                    return .double;
                }
                const n = self.src[self.index + 1];
                if (n == '"' or n == '\\' or n == '$' or n == '`') {
                    self.write(n);
                    self.index += 2;
                } else {
                    self.write(c);
                    self.index += 1;
                }
                return .double;
            },
            else => {
                self.write(c);
                self.index += 1;
                return .double;
            },
        }
    }

    fn finish(self: *Self) [:0]const u8 {
        self.buffer[self.end] = 0;
        const token = self.buffer[self.start..self.end :0];
        self.end += 1;
        self.start = self.end;
        return token;
    }

    fn write(self: *Self, c: u8) void {
        self.buffer[self.end] = c;
        self.end += 1;
    }

    fn isBlank(c: u8) bool {
        return c == ' ' or c == '\t';
    }
};

fn findExecutable(io: std.Io, gpa: std.mem.Allocator, path_env: []const u8, name: []const u8) !?[]u8 {
    var dirs = std.mem.tokenizeScalar(u8, path_env, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fs.path.join(gpa, &.{ dir, name });
        errdefer gpa.free(full);

        std.Io.Dir.accessAbsolute(io, full, .{ .execute = true }) catch {
            gpa.free(full);
            continue;
        };
        return full;
    }
    return null;
}

const LineResult = enum { cont, exit };

fn processLine(
    init: std.process.Init,
    out: anytype,
    path_env: []const u8,
    line: []const u8,
) !LineResult {
    var it = try Tokenizer.init(init.gpa, line);
    defer it.deinit();

    const cmd = (try it.next()) orelse return .cont;

    switch (parseBuiltin(cmd)) {
        .exit => return .exit,
        .type => {
            const cmd2 = (try it.next()) orelse {
                try out.writeAll("type: usage: type NAME\n");
                return .cont;
            };
            if (parseBuiltin(cmd2) != .unknown) {
                try out.print("{s} is a shell builtin\n", .{cmd2});
            } else if (try findExecutable(init.io, init.gpa, path_env, cmd2)) |full| {
                defer init.gpa.free(full);
                try out.print("{s} is {s}\n", .{ cmd2, full });
            } else {
                try out.print("{s}: not found\n", .{cmd2});
            }
        },
        .echo => {
            var first = true;
            while (try it.next()) |arg| {
                if (!first) try out.writeAll(" ");
                try out.writeAll(arg);
                first = false;
            }
            try out.writeAll("\n");
        },
        .pwd => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = try std.process.currentPath(init.io, &buf);
            try out.print("{s}\n", .{buf[0..n]});
        },
        .cd => {
            const home = init.environ_map.get("HOME") orelse "";
            const raw = (try it.next()) orelse home;
            const path = if (raw.len == 0 or std.mem.eql(u8, raw, "~"))
                home
            else
                raw;

            std.process.setCurrentPath(init.io, path) catch {
                try out.print("cd: {s}: No such file or directory\n", .{path});
            };
        },
        .unknown => {
            if (try findExecutable(init.io, init.gpa, path_env, cmd)) |full| {
                defer init.gpa.free(full);

                var argv: std.ArrayList([]const u8) = .empty;
                defer argv.deinit(init.gpa);
                try argv.append(init.gpa, cmd);
                while (try it.next()) |arg| try argv.append(init.gpa, arg);

                try out.flush();
                var child = try std.process.spawn(init.io, .{ .argv = argv.items });
                _ = try child.wait(init.io);
            } else {
                try out.print("{s}: command not found\n", .{cmd});
            }
        },
    }
    return .cont;
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);

    const out = &stdout.interface;

    const path_env = init.environ_map.get("PATH") orelse "";
    while (true) {
        try out.writeAll("$ ");
        try out.flush();

        const line = (try stdin.interface.takeDelimiter('\n')) orelse break;
        const r = processLine(init, out, path_env, line) catch {
            try out.writeAll("unexpected EOF while looking for matching quote\n");
            continue;
        };
        if (r == .exit) break;
        try out.flush();
    }
}

