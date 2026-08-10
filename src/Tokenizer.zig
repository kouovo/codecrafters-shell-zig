const std = @import("std");

const Tokenizer = @This();

pub const Result = union(enum) {
    word: [:0]const u8,
    op: Op,
};

pub const Op = struct {
    kind: enum { gt, gtgt, lt, bg, and_and },
    fd: u8, // 0=stdin, 1=stdout, 2=stderr
};

pub const InitError = error{OutOfMemory};
pub const Error = error{UnclosedQuote};

const Msg = enum { normal, single, double, done };

allocator: std.mem.Allocator,
src: []const u8,
buffer: []u8,
index: usize = 0,
start: usize = 0,
end: usize = 0,
pending: ?Result = null,

pub fn init(allocator: std.mem.Allocator, src: []const u8) InitError!Tokenizer {
    const buffer = try allocator.alloc(u8, src.len + 1);
    errdefer allocator.free(buffer);
    return .{ .allocator = allocator, .src = src, .buffer = buffer };
}

pub fn deinit(self: *Tokenizer) void {
    self.allocator.free(self.buffer);
}

pub fn next(self: *Tokenizer) Error!?Result {
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

fn handleNormal(self: *Tokenizer) Error!Msg {
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
        '>', '<', '&' => return self.emitOp(if (c == '>') 1 else 0),
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

fn emitOp(self: *Tokenizer, fd: u8) Msg {
    const c = self.src[self.index];
    self.index += 1;
    switch (c) {
        '>' => {
            if (self.index < self.src.len and self.src[self.index] == '>') {
                self.index += 1;
                self.pending = .{ .op = .{ .kind = .gtgt, .fd = fd } };
            } else {
                self.pending = .{ .op = .{ .kind = .gt, .fd = fd } };
            }
        },
        '<' => {
            self.pending = .{ .op = .{ .kind = .lt, .fd = fd } };
        },
        '&' => {
            if (self.index < self.src.len and self.src[self.index] == '&') {
                self.index += 1;
                self.pending = .{ .op = .{ .kind = .and_and, .fd = 0 } };
            } else {
                self.pending = .{ .op = .{ .kind = .bg, .fd = fd } };
            }
        },
        else => {},
    }

    return .done;
}

fn handleSingle(self: *Tokenizer) Error!Msg {
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

fn handleDouble(self: *Tokenizer) Error!Msg {
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

fn finish(self: *Tokenizer) Result {
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
    return .{ .word = token };
}

fn write(self: *Tokenizer, c: u8) void {
    self.buffer[self.end] = c;
    self.end += 1;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}
