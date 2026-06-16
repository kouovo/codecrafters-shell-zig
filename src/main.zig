const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var stdout = std.Io.File.stdout().writer(init.io, &.{});
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readStreaming(init.io, &stdin_buffer);

    const command = try stdin.interface.takeDelimiter('\n');

    try stdout.interface.print("$ ", .{});
    try stdout.interface.print("{s}: command not found\n", .{command.?});
}
