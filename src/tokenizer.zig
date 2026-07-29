const std = @import("std");

pub const Result = union(enum) { word: [:0]const u8, op: Op };
pub const Op = struct {
    kind: enum { gt, gtgt, lt },
    fd: u8, // 0=stdin, 1=stdout, 2=stderr
};

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
