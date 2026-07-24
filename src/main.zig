const std = @import("std");

const Builtin = enum { exit, echo, type, pwd, unknown, cd };
const Op = struct {
    kind: enum { gt, gtgt, lt },
    fd: u8, // 0=stdin, 1=stdout, 2=stderr
};
const Result = union(enum) { word: [:0]const u8, op: Op };
const Redir = struct { op: Op, path: []const u8 };

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
    pending: ?Result = null,

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

    pub fn next(self: *Self) Error!?Result {
        if (self.pending) |p| {
            self.pending = null;
            return p;
        }
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
    fn handleOperator(self: *Self) Result {
        const c = self.src[self.index];
        switch (c) {}
        return Result{};
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
            '>', '<' => return self.emitOp(if (c == '>') 1 else 0),
            '0', '1', '2' => {
                if (self.index + 1 < self.src.len and
                    (self.src[self.index + 1] == '>' or self.src[self.index + 1] == '<'))
                {
                    const fd = c - '0';
                    self.index += 1;
                    return self.emitOp(fd);
                }
                self.write(c);
                self.index += 1;
                return .normal;
            },
            else => {
                self.write(c);
                self.index += 1;
                return .normal;
            },
        }
    }

    fn emitOp(self: *Self, fd: u8) Msg {
        const c = self.src[self.index];
        self.index += 1;
        if (c == '>') {
            if (self.index < self.src.len and self.src[self.index] == '>') {
                self.index += 1;
                self.pending = .{ .op = .{ .kind = .gtgt, .fd = fd } };
            } else {
                self.pending = .{ .op = .{ .kind = .gt, .fd = fd } };
            }
        } else { // '<'
            self.pending = .{ .op = .{ .kind = .lt, .fd = fd } };
        }
        return .done;
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
    fn peek(self: *Self) ?u8 {
        if (self.index + 1 >= self.src.len) return null;
        return self.src[self.index + 1];
    }

    fn finish(self: *Self) Result {
        if (self.start == self.end) {
            if (self.pending) |p| {
                self.pending = null;
                return p;
            }
        }
        self.buffer[self.end] = 0;
        const token = self.buffer[self.start..self.end :0];
        self.end += 1;
        self.start = self.end;
        return Result{ .word = token };
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
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);

    var redir: ?Redir = null;
    while (try it.next()) |tok| switch (tok) {
        .word => |w| try argv.append(init.gpa, w),
        .op => |op| {
            const target = (try it.next()) orelse return .cont;
            redir = .{ .op = op, .path = target.word };
        },
    };

    switch (parseBuiltin(cmd.word)) {
        .exit => return .exit,
        .type => {
            if (argv.items.len == 0) {
                try out.writeAll("type: usage: type NAME\n");
                return .cont;
            }
            const cmd2 = argv.items[0];
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
            var file_buf: [4096]u8 = undefined;
            var file_writer: ?std.Io.File.Writer = null;
            var redir_file: ?std.Io.File = null;
            defer if (redir_file) |f| f.close(init.io);

            const w: *std.Io.Writer = blk: {
                if (redir) |r| {
                    if (r.op.fd == 1 and r.op.kind != .lt) {
                        const flags: std.posix.O = .{
                            .ACCMODE = .WRONLY,
                            .CREAT = true,
                            .TRUNC = r.op.kind == .gt,
                            .APPEND = r.op.kind == .gtgt,
                        };
                        const fd = std.posix.openat(std.posix.AT.FDCWD, r.path, flags, 0o644) catch {
                            break :blk out;
                        };
                        redir_file = .{ .handle = fd, .flags = .{ .nonblocking = false } };
                        file_writer = redir_file.?.writerStreaming(init.io, &file_buf);
                        break :blk &file_writer.?.interface;
                    }
                }
                break :blk out;
            };

            var first = true;
            for (argv.items) |arg| {
                if (!first) try w.writeAll(" ");
                try w.writeAll(arg);
                first = false;
            }
            try w.writeAll("\n");
            try w.flush();
        },
        .pwd => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = try std.process.currentPath(init.io, &buf);
            try out.print("{s}\n", .{buf[0..n]});
        },
        .cd => {
            const home = init.environ_map.get("HOME") orelse "";
            const raw = if (argv.items.len > 0) argv.items[0] else home;
            const path = if (raw.len == 0 or std.mem.eql(u8, raw, "~"))
                home
            else
                raw;

            std.process.setCurrentPath(init.io, path) catch {
                try out.print("cd: {s}: No such file or directory\n", .{path});
            };
        },
        .unknown => {
            if (try findExecutable(init.io, init.gpa, path_env, cmd.word)) |full| {
                defer init.gpa.free(full);

                // exec argv = [cmd.word, ...argv.items]
                var exec_argv: std.ArrayList([]const u8) = .empty;
                defer exec_argv.deinit(init.gpa);
                try exec_argv.append(init.gpa, cmd.word);
                for (argv.items) |arg| try exec_argv.append(init.gpa, arg);

                try out.flush();

                var redir_file: ?std.Io.File = null;
                defer if (redir_file) |f| f.close(init.io);
                var opts: std.process.SpawnOptions = .{ .argv = exec_argv.items };

                if (redir) |r| {
                    const flags: std.posix.O = if (r.op.kind == .lt) .{ .ACCMODE = .RDONLY } else .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = r.op.kind == .gt, .APPEND = r.op.kind == .gtgt };
                    const fd = try std.posix.openat(std.posix.AT.FDCWD, r.path, flags, 0o644);

                    redir_file = .{ .handle = fd, .flags = .{ .nonblocking = false } };
                    const io_val: std.process.SpawnOptions.StdIo = .{ .file = redir_file.? };
                    switch (r.op.fd) {
                        0 => opts.stdin = io_val,
                        1 => opts.stdout = io_val,
                        2 => opts.stderr = io_val,
                        else => {},
                    }
                }

                var child = try std.process.spawn(init.io, opts);
                _ = try child.wait(init.io);
            } else {
                try out.print("{s}: command not found\n", .{cmd.word});
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
