const std = @import("std");
const CompletionRegistry = @import("Completion.zig");
const Tokenizer = @import("Tokenizer.zig");
const JobRegistry = @import("Job.zig");

const TabState = enum {
    first_press,
    second_press,
};

const Builtin = enum {
    exit,
    echo,
    type,
    pwd,
    unknown,
    cd,
    complete,
    jobs,
    fg,
    bg,
};
const Redir = struct { op: Tokenizer.Op, path: []const u8 };
const CompletionItem = struct {
    name: []u8,
    is_dir: bool = false,
};

fn parseBuiltin(name: []const u8) Builtin {
    return std.meta.stringToEnum(Builtin, name) orelse .unknown;
}

fn containsStr(items: []const CompletionItem, name: []const u8) bool {
    for (items) |it| if (std.mem.eql(u8, it.name, name)) return true;
    return false;
}

const BUILTIN_NAMES = [_][]const u8{ "cd", "echo", "exit", "pwd", "type", "complete" };

fn gatherDirectoryCompletion(init: std.process.Init, word: []const u8, list: *std.ArrayList(CompletionItem)) !void {
    try gatherFileCompletion(init, word, list);

    var write_index: usize = 0;
    for (list.items) |item| {
        if (item.is_dir) {
            list.items[write_index] = item;
            write_index += 1;
        } else {
            init.gpa.free(item.name);
        }
    }

    list.shrinkRetainingCapacity(write_index);
}

fn gatherExternalCompletion(
    init: std.process.Init,
    generator: []const u8,
    command: []const u8,
    current_word: []const u8,
    previous_word: []const u8,
    list: *std.ArrayList(CompletionItem),
    line: []const u8,
    point: usize,
) !void {
    var exec_argv: std.ArrayList([]const u8) = .empty;
    defer exec_argv.deinit(init.gpa);
    var env_map = try init.environ_map.clone(init.gpa);
    defer env_map.deinit();

    var point_buf: [32]u8 = undefined;
    const point_text = try std.fmt.bufPrint(&point_buf, "{d}", .{point});
    try env_map.put("COMP_LINE", line);
    try env_map.put("COMP_POINT", point_text);

    try exec_argv.append(init.gpa, generator);

    try exec_argv.append(init.gpa, command);
    try exec_argv.append(init.gpa, current_word);
    try exec_argv.append(init.gpa, previous_word);

    var child = try std.process.spawn(init.io, .{
        .argv = exec_argv.items,
        .stdout = .pipe,
        .stderr = .ignore,
        .environ_map = &env_map,
    });

    defer child.kill(init.io);

    if (child.stdout) |child_stdout| {
        var read_buf: [4096]u8 = undefined;
        var reader = child_stdout.readerStreaming(
            init.io,
            &read_buf,
        );
        while (try reader.interface.takeDelimiter('\n')) |l| {
            const name = std.mem.trimEnd(u8, l, "\r");

            if (name.len == 0) continue;

            try list.append(init.gpa, .{
                .name = try init.gpa.dupe(u8, name),
                .is_dir = false,
            });
        }
    }
    _ = try child.wait(init.io);
}

fn gatherFileCompletion(init: std.process.Init, word: []const u8, list: *std.ArrayList(CompletionItem)) !void {
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

    std.mem.sort(CompletionItem, list.items, {}, struct {
        fn lt(_: void, a: CompletionItem, b: CompletionItem) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
}
fn gatherCompletion(init: std.process.Init, path_env: []const u8, prefix: []const u8, list: *std.ArrayList(CompletionItem)) !void {
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

    std.mem.sort(CompletionItem, list.items, {}, struct {
        fn lt(_: void, a: CompletionItem, b: CompletionItem) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
}

fn commonPrefixLen(items: []const CompletionItem) usize {
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
fn findPreviousWord(
    init: std.process.Init,
    buf: []const u8,
    word_start: usize,
) ![]u8 {
    var previous_word: []const u8 = "";
    var prefix_tokens = try Tokenizer.init(init.gpa, buf[0..word_start]);
    defer prefix_tokens.deinit();

    while (try prefix_tokens.next()) |tok| {
        switch (tok) {
            .word => |w| {
                previous_word = w;
            },
            .op => {},
        }
    }
    return try init.gpa.dupe(u8, previous_word);
}
fn handleTab(
    init: std.process.Init,
    out: *std.Io.Writer,
    path_env: []const u8,
    registry: *const CompletionRegistry,
    buf: []u8,
    len_ptr: *usize,
    pos_ptr: *usize,
    tab_state_ptr: *TabState,
) !void {
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

    var completions: std.ArrayList(CompletionItem) = .empty;
    defer {
        for (completions.items) |c| init.gpa.free(c.name);
        completions.deinit(init.gpa);
    }

    if (word_start == 0) {
        try gatherCompletion(init, path_env, word, &completions);
    } else {
        var line_tokens = try Tokenizer.init(init.gpa, buf[0..len]);
        defer line_tokens.deinit();
        const first_token = (try line_tokens.next()) orelse return;
        const first_cmd = switch (first_token) {
            .word => |w| w,
            .op => return,
        };
        const spec: CompletionRegistry.Spec = registry.lookup(first_cmd) orelse .{ .builtin = .file };
        switch (spec) {
            .builtin => |provider| {
                switch (provider) {
                    .command => try gatherCompletion(init, path_env, word, &completions),
                    .file => try gatherFileCompletion(init, word, &completions),
                    .directory => try gatherDirectoryCompletion(init, word, &completions),
                }
            },
            .external => |generator| {
                const previous_word = try findPreviousWord(init, buf, word_start);
                defer init.gpa.free(previous_word);
                try gatherExternalCompletion(init, generator, first_cmd, word, previous_word, &completions, buf[0..len], pos_ptr.*);
            },
        }
    }

    if (completions.items.len == 0) {
        try out.writeByte(0x07);
        tab_state_ptr.* = .first_press;
        return;
    }

    if (completions.items.len == 1) {
        const comp = completions.items[0];
        try appendToLine(out, buf, len_ptr, pos_ptr, comp.name[word.len..]);
        try appendToLine(out, buf, len_ptr, pos_ptr, if (comp.is_dir) "/" else " ");
        tab_state_ptr.* = .first_press;
        return;
    }

    const common = commonPrefixLen(completions.items);
    if (common > word.len) {
        const comp = completions.items[0];
        try appendToLine(out, buf, len_ptr, pos_ptr, comp.name[word.len..common]);
        tab_state_ptr.* = .first_press;
        return;
    }
    switch (tab_state_ptr.*) {
        .first_press => {
            try out.writeByte(0x07);
            tab_state_ptr.* = .second_press;
        },
        .second_press => {
            try out.writeByte('\n');
            for (completions.items, 0..) |c, idx| {
                if (idx > 0) try out.writeAll("  ");
                try out.writeAll(c.name);
                if (c.is_dir) try out.writeByte('/');
            }

            try out.writeByte('\n');
            try out.writeAll("$ ");
            try out.writeAll(buf[0..len_ptr.*]);
            tab_state_ptr.* = .first_press;
        },
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
    registry: *CompletionRegistry,
    job_registry: *JobRegistry,
) !LineResult {
    var it = try Tokenizer.init(init.gpa, line);
    defer it.deinit();
    const cmd = (try it.next()) orelse return .cont;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);

    var background = false;
    var redir: ?Redir = null;

    while (try it.next()) |tok| switch (tok) {
        .word => |w| try argv.append(init.gpa, w),
        .op => |op| switch (op.kind) {
            .gt, .gtgt, .lt, .and_and => {
                const target = (try it.next()) orelse return .cont;
                redir = .{ .op = op, .path = target.word };
            },
            .bg => {
                // sleep 100 &
                background = true;
            },
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
        .bg => {},
        .fg => {},
        .complete => {
            const action = CompletionRegistry.parseAction(argv.items);
            switch (action) {
                .print => {
                    if (argv.items.len != 2) {
                        try out.writeAll("complete: usage: complete -p NAME\n");
                        return .cont;
                    }
                    const name = argv.items[1];
                    const spec = registry.lookup(name) orelse {
                        try out.print("complete: {s}: no completion specification\n", .{name});
                        return .cont;
                    };
                    switch (spec) {
                        .builtin => |provider| {
                            try out.print(
                                "complete {s} {s}\n",
                                .{
                                    name,
                                    CompletionRegistry.providerName(provider),
                                },
                            );
                        },
                        .external => |generator| {
                            try out.print(
                                "complete -C '{s}' {s}\n",
                                .{
                                    generator,
                                    name,
                                },
                            );
                        },
                    }
                    return .cont;
                },
                .unregister_external => {
                    if (argv.items.len != 2) {
                        try out.writeAll(
                            "complete: usage: complete -r NAME\n",
                        );
                        return .cont;
                    }

                    const name = argv.items[1];
                    registry.unregister(init.gpa, name);

                    return .cont;
                },
                .register_external => {
                    if (argv.items.len != 3) {
                        try out.writeAll(
                            "complete: usage: complete -C GENERATOR NAME\n",
                        );
                        return .cont;
                    }

                    const generator = argv.items[1];
                    const name = argv.items[2];
                    try registry.registerExternal(
                        init.gpa,
                        name,
                        generator,
                    );

                    return .cont;
                },
                .register_builtin => {
                    if (argv.items.len < 2) {
                        try out.writeAll("complete: useage: complete NAME[command|file|directory]\n");
                        return .cont;
                    }

                    const name = argv.items[0];
                    const kind_str = argv.items[1];
                    const kind = std.meta.stringToEnum(CompletionRegistry.Provider, kind_str) orelse {
                        try out.print(
                            "complete: unknown provider: {s}\n",
                            .{kind_str},
                        );
                        return .cont;
                    };
                    try registry.register(init.gpa, name, .{ .builtin = kind });
                    try out.print("{s} is now a {s} completion\n", .{ name, kind_str });
                },
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
        .jobs => {
            try job_registry.reap();
            for (job_registry.items()) |job| {
                const suffix: []const u8 = if (job.state == .running) " &" else "";

                try out.print(
                    "[{d}]{s}  {s}                 {s}{s}\n",
                    .{
                        job.id,
                        job_registry.marker(job.id),
                        JobRegistry.stateName(job.state),
                        job.command,
                        suffix,
                    },
                );
            }
            job_registry.removeNotified(init.gpa);
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
                if (background) {
                    const pgid = child.id orelse unreachable;
                    const command = try init.gpa.dupe(u8, line);
                    const id = job_registry.add(init.gpa, .{
                        .id = 0,
                        .type = .bg,
                        .pgid = pgid,
                        .state = .running,
                        .command = command,
                    }) catch |err| {
                        init.gpa.free(command);
                        return err;
                    };
                    try out.print("[{d}] {d}\n", .{ id, pgid });
                } else {
                    _ = try child.wait(init.io);
                }
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
    var registry: CompletionRegistry = .{};
    var jobRegistry: JobRegistry = .{};
    defer jobRegistry.deinit(init.gpa);
    defer registry.deinit(init.gpa);

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
        try runRawLoop(init, out, &stdin.interface, path_env, &registry, &jobRegistry, &line_buf);
    } else {
        while (true) {
            try out.writeAll("$ ");
            try out.flush();

            const line = (try stdin.interface.takeDelimiter('\n')) orelse break;
            const r = processLine(init, out, path_env, line, &registry, &jobRegistry) catch {
                try out.writeAll("unexpected EOF while looking for matching quote\n");
                continue;
            };
            if (r == .exit) break;
            try out.flush();
        }
    }
}

fn runRawLoop(
    init: std.process.Init,
    out: *std.Io.Writer,
    stdin: *std.Io.Reader,
    path_env: []const u8,
    registry: *CompletionRegistry,
    job_registry: *JobRegistry,
    buf: []u8,
) !void {
    while (true) {
        try out.writeAll("$ ");
        try out.flush();

        var len: usize = 0;
        var pos: usize = 0;
        var tab_state: TabState = .first_press;
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
                    try handleTab(init, out, path_env, registry, buf, &len, &pos, &tab_state);
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
                    tab_state = .first_press;
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
                        tab_state = .first_press;
                    } else {
                        tab_state = .first_press;
                    }
                },
            }
        }

        const r = processLine(init, out, path_env, buf[0..len], registry, job_registry) catch {
            try out.writeAll("unexpected EOF while looking for matching quote\n");
            continue;
        };

        if (r == .exit) return;
        try out.flush();
    }
}

// fn stripBackgroundSuffix(line: []const u8) []const u8 {
//     var s = std.mem.trimEnd(u8, line, " \t");
//     if (s.len > 0 and s[s.len - 1] == '&') {
//         s = std.mem.trimEnd(u8, s[0 .. s.len - 1], " \t");
//     }
//     return s;
// }
