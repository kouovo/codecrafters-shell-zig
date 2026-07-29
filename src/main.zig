const std = @import("std");
const tokenzier = @import("tokenizer.zig");

const Builtin = enum { exit, echo, type, pwd, unknown, cd };
const Redir = struct { op: tokenzier.Op, path: []const u8 };
const Candidate = struct {
    name: []u8,
    is_dir: bool = false,
};

fn parseBuiltin(name: []const u8) Builtin {
    return std.meta.stringToEnum(Builtin, name) orelse .unknown;
}

fn containsStr(items: []const Candidate, name: []const u8) bool {
    for (items) |it| if (std.mem.eql(u8, it.name, name)) return true;
    return false;
}

const BUILTIN_NAMES = [_][]const u8{ "cd", "echo", "exit", "pwd", "type" };

fn gatherFileCandidates(init: std.process.Init, word: []const u8, list: *std.ArrayList(Candidate)) !void {
    const gpa = init.gpa;

    const last_slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const dir_part: []const u8 = blk: {
        if (last_slash) |i| {
            if (i == 0) break :blk "/";
            break :blk word[0..i];
        }
        break :blk ".";
    };
    const prefix = if (last_slash) |i| word[i + 1 ..] else word;
    const stem: []const u8 = if (last_slash) |i| word[0 .. i + 1] else "";
    var dir = std.Io.Dir.cwd().openDir(init.io, dir_part, .{ .iterate = true, .access_sub_paths = false }) catch return;
    defer dir.close(init.io);

    var it = dir.iterate();
    while (try it.next(init.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (containsStr(list.items, entry.name)) continue;

        const candidate = try gpa.alloc(u8, stem.len + entry.name.len);
        @memcpy(candidate[0..stem.len], stem);
        @memcpy(candidate[stem.len..], entry.name);
        try list.append(gpa, .{ .name = candidate, .is_dir = entry.kind == .directory });
    }

    std.mem.sort(Candidate, list.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
}
fn gatherCandidates(init: std.process.Init, path_env: []const u8, prefix: []const u8, list: *std.ArrayList(Candidate)) !void {
    const gpa = init.gpa;

    for (BUILTIN_NAMES) |b| {
        if (std.mem.startsWith(u8, b, prefix)) {
            if (containsStr(list.items, b)) continue;
            try list.append(gpa, .{ .name = try gpa.dupe(u8, b) });
        }
    }
    var path_iter = std.mem.tokenizeScalar(u8, path_env, ':');
    while (path_iter.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        var dir = std.Io.Dir.cwd().openDir(init.io, dir_path, .{ .iterate = true, .access_sub_paths = false }) catch continue;
        defer dir.close(init.io);

        var it = dir.iterate();

        while (try it.next(init.io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            dir.access(init.io, entry.name, .{ .execute = true }) catch continue;
            if (containsStr(list.items, entry.name)) continue;
            try list.append(gpa, .{ .name = try gpa.dupe(u8, entry.name) });
        }
    }

    std.mem.sort(Candidate, list.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
}

fn commonPrefixLen(items: []const Candidate) usize {
    if (items.len == 0) return 0;
    const first = items[0].name;
    var i: usize = 0;
    outer: while (i < first.len) {
        const c = first[i];
        for (items[1..]) |rest| {
            if (i >= rest.name.len or rest.name[i] != c) break :outer;
        }
        i += 1;
    }
    return i;
}

fn appendToLine(out: *std.Io.Writer, buf: []u8, len_ptr: *usize, pos_ptr: *usize, s: []const u8) !void {
    for (s) |c| {
        if (len_ptr.* >= buf.len) break;
        buf[len_ptr.*] = c;
        len_ptr.* += 1;
        pos_ptr.* += 1;
        try out.writeByte(c);
    }
}
fn handleTab(init: std.process.Init, out: *std.Io.Writer, path_env: []const u8, buf: []u8, len_ptr: *usize, pos_ptr: *usize, tab_pending_ptr: *bool) !void {
    const len = len_ptr.*;
    var word_start: usize = 0;
    var j: usize = len;
    while (j > 0) {
        j -= 1;
        if (buf[j] == ' ' or buf[j] == '\t') {
            word_start = j + 1;
            break;
        }
    }

    const word = buf[word_start..len];

    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |c| init.gpa.free(c.name);
        candidates.deinit(init.gpa);
    }

    if (word_start != 0) {
        try gatherFileCandidates(init, word, &candidates);
    } else {
        try gatherCandidates(init, path_env, word, &candidates);
    }

    if (candidates.items.len == 0) {
        try out.writeByte(0x07);
        tab_pending_ptr.* = false;
        return;
    }

    if (candidates.items.len == 1) {
        const comp = candidates.items[0];
        try appendToLine(out, buf, len_ptr, pos_ptr, comp.name[word.len..]);
        try appendToLine(out, buf, len_ptr, pos_ptr, if (comp.is_dir) "/" else " ");
        tab_pending_ptr.* = false;
        return;
    }

    const common = commonPrefixLen(candidates.items);
    if (common > word.len) {
        const comp = candidates.items[0];
        try appendToLine(out, buf, len_ptr, pos_ptr, comp.name[word.len..common]);
        tab_pending_ptr.* = false;
        return;
    }

    if (tab_pending_ptr.*) {
        try out.writeByte('\n');
        for (candidates.items, 0..) |c, idx| {
            if (idx > 0) try out.writeAll("  ");
            try out.writeAll(c.name);
            if (c.is_dir) try out.writeByte('/');
        }

        try out.writeByte('\n');
        try out.writeAll("$ ");
        try out.writeAll(buf[0..len_ptr.*]);
        tab_pending_ptr.* = false;
    } else {
        try out.writeByte(0x07);
        tab_pending_ptr.* = true;
    }
}

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
    var it = try tokenzier.Tokenizer.init(init.gpa, line);
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

            var w: *std.Io.Writer = out;

            if (redir) |r| {
                if (r.op.kind != .lt) {
                    const flags: std.posix.O = .{
                        .ACCMODE = .WRONLY,
                        .CREAT = true,
                        .TRUNC = r.op.kind == .gt,
                        .APPEND = r.op.kind == .gtgt,
                    };
                    if (std.posix.openat(std.posix.AT.FDCWD, r.path, flags, 0o644)) |fd| {
                        redir_file = .{ .handle = fd, .flags = .{ .nonblocking = false } };
                        if (r.op.fd == 1) {
                            file_writer = redir_file.?.writerStreaming(init.io, &file_buf);
                            w = &file_writer.?.interface;
                        }
                    } else |_| {}
                }
            }

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

    var orig_termios: std.posix.termios = undefined;
    const interactive = blk: {
        orig_termios = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch break :blk false;
        break :blk true;
    };

    if (interactive) {
        var raw = orig_termios;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[4] = 1;
        raw.cc[5] = 0;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch {};
    }
    defer if (interactive) {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, orig_termios) catch {};
    };

    const out = &stdout.interface;

    const path_env = init.environ_map.get("PATH") orelse "";
    if (interactive) {
        var line_buf: [4096]u8 = undefined;
        try runRawLoop(init, out, &stdin.interface, path_env, &line_buf);
    } else {
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
}

fn runRawLoop(init: std.process.Init, out: *std.Io.Writer, stdin: *std.Io.Reader, path_env: []const u8, buf: []u8) !void {
    while (true) {
        try out.writeAll("$ ");
        try out.flush();

        var len: usize = 0;
        var pos: usize = 0;
        var tab_pending: bool = false;
        while (true) {
            const b = stdin.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    try out.writeAll("\n");
                    try out.flush();
                    return;
                },
                else => return err,
            };
            switch (b) {
                '\n', '\r' => {
                    try out.writeByte('\n');
                    try out.flush();
                    break;
                },
                '\t' => {
                    try handleTab(init, out, path_env, buf, &len, &pos, &tab_pending);
                    try out.flush();
                },
                0x7f, 0x08 => { //backspace
                    if (len > 0) {
                        len -= 1;
                        pos -= 1;
                        // move back, wipe, move back
                        try out.writeAll("\x08 \x08");
                        try out.flush();
                    }
                    tab_pending = false;
                },
                0x04 => { // ctrl - d
                    if (len == 0) {
                        try out.writeAll("\n");
                        try out.flush();
                        return;
                    }
                },
                else => {
                    if (b >= 0x20 and b <= 0x7e) {
                        if (len < buf.len) {
                            buf[len] = b;
                            len += 1;
                            pos += 1;
                            try out.writeByte(b);
                            try out.flush();
                        }
                        tab_pending = false;
                    } else {
                        tab_pending = false;
                    }
                },
            }
        }

        const r = processLine(init, out, path_env, buf[0..len]) catch {
            try out.writeAll("unexpected EOF while looking for matching quote\n");
            continue;
        };

        if (r == .exit) return;
        try out.flush();
    }
}
