const std = @import("std");

const Builtin = enum { exit, echo, unknown };
fn parseBuiltin(name: []const u8) Builtin {
    const map = std.StaticStringMap(Builtin).initComptime(.{
        .{ "exit", .exit },
        .{ "echo", .echo },
    });
    return map.get(name) orelse .unknown;
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);

    const out = &stdout.interface;

    while (true) {
        try out.writeAll("$ ");
        try out.flush();

        const line = (try stdin.interface.takeDelimiter('\n')) orelse
            break;
        var args = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = args.next() orelse continue;

        switch (parseBuiltin(cmd)) {
            .exit => break,
            .echo => {
                var first = true;
                while (args.next()) |arg| {
                    if (!first) try out.writeAll(" ");
                    try out.writeAll(arg);
                    first = false;
                }
                try out.writeAll("\n");
            },
            .unknown => try out.print("{s}: command not found\n", .{cmd}),
        }
        try out.flush();
    }
}
