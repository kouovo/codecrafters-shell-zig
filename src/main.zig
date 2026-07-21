const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var stdout = std.Io.File.stdout().writer(init.io, &.{});
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);

    while (true) {
        try stdout.interface.print("$ ", .{});
        const command = try stdin.interface.takeDelimiter('\n');
        const cmd = command orelse break;
        var args_iter = std.mem.tokenizeSequence(u8, cmd, " ");
        const name = args_iter.next().?;

        // while (args_iter.next()) |item| {
        //     std.debug.print("args: '{s}'\n", .{item});
        // }

        if (std.mem.eql(u8, name, "exit")) {
            break;
        } else if (std.mem.eql(u8, name, "echo")) {
            // std.debug.print("{s} ", .{cmd[1..cmd.len]});
            while (args_iter.next()) |item| {
                std.debug.print("{s} ", .{item});
            }

            std.debug.print("\n", .{});
            continue;
        }
        // else if (std.mem.eql()) {
        //     // const args = cmd[1..cmd.len];
        //     // std.debug.print("{s}\n", .{args});
        // }

        try stdout.interface.print("{s}: command not found\n", .{command.?});
    }
}
