const std = @import("std");

const Builtin = enum { exit, echo, type, pwd, unknown, cd };
fn parseBuiltin(name: []const u8) Builtin {
    const map = std.StaticStringMap(Builtin).initComptime(.{ .{ "exit", .exit }, .{ "echo", .echo }, .{ "type", .type }, .{ "pwd", .pwd }, .{ "cd", .cd } });
    return map.get(name) orelse .unknown;
    // std.meta.stringToEnum(Builtin, name);
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

        const line = (try stdin.interface.takeDelimiter('\n')) orelse
            break;
        var it = try std.process.Args.IteratorGeneral(.{ .single_quotes = true }).init(init.gpa, line);

        defer it.deinit();

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(init.gpa);

        while (it.next()) |arg| {
            try argv.append(init.gpa, arg);
        }

        var args = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = args.next() orelse continue;

        switch (parseBuiltin(cmd)) {
            .exit => break,
            .type => {
                const cmd2 = args.next() orelse continue;

                if (parseBuiltin(cmd2) != .unknown) {
                    try out.print("{s} is a shell builtin\n", .{cmd2});
                } else {
                    if (try findExecutable(init.io, init.gpa, path_env, cmd2)) |full| {
                        defer init.gpa.free(full);
                        try out.print("{s} is {s}\n", .{ cmd2, full });
                    } else {
                        try out.print("{s}: not found\n", .{cmd2});
                    }
                }
            },
            .echo => {
                var first = true;
                while (args.next()) |arg| {
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
                const raw = args.next() orelse home;
                const path = if (raw.len == 0 or std.mem.eql(u8, raw, "~"))
                    home
                else
                    raw;

                // try out.print("{s}", .{path});
                std.process.setCurrentPath(init.io, path) catch {
                    try out.print("cd: {s}: No such file or directory\n", .{path});
                };
            },
            .unknown => {
                if (try findExecutable(init.io, init.gpa, path_env, cmd)) |full| {
                    defer init.gpa.free(full);
                    try out.flush();
                    var child = try std.process.spawn(init.io, .{ .argv = argv.items });
                    _ = try child.wait(init.io);
                } else {
                    try out.print("{s}: command not found\n", .{cmd});
                }
            },
        }
        try out.flush();
    }
}
