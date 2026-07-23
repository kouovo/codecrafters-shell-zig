const std = @import("std");

const Builtin = enum { exit, echo, type, pwd, unknown, cd };
const State = enum { normal, double, single };

fn parseBuiltin(name: []const u8) Builtin {
    return std.meta.stringToEnum(Builtin, name) orelse .unknown;
}

// const Token = struct {
//     text: u8,
// };

const Tokenizer = struct {
    src: []u8,
    read: usize = 0,
    write: usize = 0,
    fn isBlank(c: u8) bool {
        return c == ' ' or c == '\t';
    }
    pub fn next(self: *Tokenizer) ?[]u8 {
        while (self.read < self.src.len and isBlank(self.src[self.read])) self.read += 1;
        if (self.read >= self.src.len) return null;
        const start = self.write;
        var state: State = .normal;
        while (self.read < self.src.len) {
            const c = self.src[self.read];
            switch (state) {
                .normal => {
                    if (isBlank(c)) break;
                    if (c == '\'') {
                        state = .single;
                        self.read += 1;
                        continue;
                    }

                    if (c == '"') {
                        state = .double;
                        self.read += 1;
                        continue;
                    }

                    if (c == '\\') {
                        self.read += 1;
                        if (self.read < self.src.len) {
                            self.src[self.write] = self.src[self.read];
                            self.write += 1;
                            self.read += 1;
                        }
                        continue;
                    }
                    self.src[self.write] = c;
                    self.write += 1;
                    self.read += 1;
                },

                .single => {
                    if (c == '\'') {
                        state = .normal;
                        self.read += 1;
                        continue;
                    }

                    self.src[self.write] = c;
                    self.write += 1;
                    self.read += 1;
                },

                .double => {
                    if (c == '"') {
                        state = .normal;
                        self.read += 1;
                        continue;
                    }
                    if (c == '\\') {
                        const next_c = self.src[self.read + 1];
                        if (next_c == '"' or next_c == '\\' or next_c == '$' or next_c == '`') {
                            self.read += 1;
                            self.src[self.write] += self.src[self.read];
                            self.write += 1;
                            self.read += 1;
                        }
                        self.src[self.write] = c;
                        self.write += 1;
                        self.read += 1;
                        continue;
                    }
                    self.src[self.write] = c;
                    self.write += 1;
                    self.read += 1;
                },
            }
        }
        return self.src[start..self.write];
    }
    // pub fn deinit(){
    //
    // }
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
        var it: Tokenizer = .{ .write = 0, .read = 0, .src = line };

        const cmd = it.next() orelse continue;

        switch (parseBuiltin(cmd)) {
            .exit => break,
            .type => {
                const cmd2 = it.next() orelse {
                    try out.writeAll("type: usage: type NAME\n");
                    continue;
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
                while (it.next()) |arg| {
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
                const raw = it.next() orelse home;
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
                    while (it.next()) |arg| try argv.append(init.gpa, arg);

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
