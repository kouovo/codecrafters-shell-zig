const std = @import("std");

const State = enum { normal, single, double };

/// 词素迭代器:按空白切分,保留引号与转义的原始字节,不做展开。
///
/// 仿 std.mem.TokenIterator:
///   - 输入 `[]const u8`,只读,不 mutate 用户数据;
///   - 单个 `index` 游标;
///   - `next` / `peek` / `rest` 三件套;
///   - yield 的切片借用原 buffer,零分配。
///
/// 引号/转义的"展开"是独立一步(见 unescape),这样:
///   - 只想看第一个词决定走哪个 builtin 时(exit/pwd),零成本;
///   - 真正要传给 echo/spawn 时才分配展开后的字符串。
pub const TokenIterator = struct {
    buffer: []const u8,
    index: usize = 0,

    const Self = @This();

    /// 返回当前词素并前进,到末尾返回 null。
    pub fn next(self: *Self) ?[]const u8 {
        const result = self.peek() orelse return null;
        self.index += result.len;
        return result;
    }

    /// 返回当前词素,不前进。
    pub fn peek(self: *Self) ?[]const u8 {
        while (self.index < self.buffer.len and isBlank(self.buffer[self.index])) self.index += 1;
        const start = self.index;
        if (start == self.buffer.len) return null;

        var end = start;
        var state: State = .normal;
        while (end < self.buffer.len) {
            const c = self.buffer[end];
            switch (state) {
                .normal => {
                    if (isBlank(c)) break;
                    if (c == '\'') {
                        state = .single;
                        end += 1;
                        continue;
                    }
                    if (c == '"') {
                        state = .double;
                        end += 1;
                        continue;
                    }
                    if (c == '\\') {
                        end += 1; // 吞掉反斜杠
                        if (end < self.buffer.len) end += 1; // 连同下一字符,避免在转义空格处断开
                        continue;
                    }
                    end += 1;
                },
                .single => {
                    if (c == '\'') {
                        state = .normal;
                        end += 1;
                        continue;
                    }
                    end += 1;
                },
                .double => {
                    if (c == '"') {
                        state = .normal;
                        end += 1;
                        continue;
                    }
                    end += 1;
                },
            }
        }
        return self.buffer[start..end];
    }

    /// 剩余未消费字节(跳过前导空白),不影响迭代状态。
    pub fn rest(self: Self) []const u8 {
        var i = self.index;
        while (i < self.buffer.len and isBlank(self.buffer[i])) i += 1;
        return self.buffer[i..];
    }

    fn isBlank(c: u8) bool {
        return c == ' ' or c == '\t';
    }
};

/// 构造一个 TokenIterator,对应 std.mem.tokenizeScalar 的角色。
pub fn tokenize(buffer: []const u8) TokenIterator {
    return .{ .buffer = buffer };
}

/// 把单个词素展开成实际参数,写入 dst,返回写入字节数。
/// dst 至少需要 lexeme.len 字节(展开只会变短或等长)。零分配。
pub fn unescapeInto(dst: []u8, lexeme: []const u8) usize {
    var r: usize = 0;
    var w: usize = 0;
    var state: State = .normal;
    while (r < lexeme.len) {
        const c = lexeme[r];
        switch (state) {
            .normal => {
                if (c == '\'') {
                    state = .single;
                    r += 1;
                    continue;
                }
                if (c == '"') {
                    state = .double;
                    r += 1;
                    continue;
                }
                if (c == '\\') {
                    r += 1;
                    if (r < lexeme.len) {
                        dst[w] = lexeme[r];
                        w += 1;
                        r += 1;
                    }
                    continue;
                }
                dst[w] = c;
                w += 1;
                r += 1;
            },
            .single => {
                if (c == '\'') {
                    state = .normal;
                    r += 1;
                    continue;
                }
                dst[w] = c;
                w += 1;
                r += 1;
            },
            .double => {
                if (c == '"') {
                    state = .normal;
                    r += 1;
                    continue;
                }
                if (c == '\\') {
                    if (r + 1 >= lexeme.len) {
                        dst[w] = c;
                        w += 1;
                        r += 1;
                        continue;
                    }
                    const n = lexeme[r + 1];
                    if (n == '"' or n == '\\' or n == '$' or n == '`') {
                        dst[w] = n;
                        w += 1;
                        r += 2;
                    } else {
                        dst[w] = c;
                        w += 1;
                        r += 1;
                    }
                    continue;
                }
                dst[w] = c;
                w += 1;
                r += 1;
            },
        }
    }
    return w;
}

/// 分配并返回展开后的参数。调用方负责 free。
pub fn unescape(alloc: std.mem.Allocator, lexeme: []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, lexeme.len);
    const n = unescapeInto(buf, lexeme);
    // 缩到实际长度,确保返回的切片就是整块分配(便于 free)。
    return try alloc.realloc(buf, n);
}

test "tokenize basic" {
    var it = tokenize("echo hello world");
    try std.testing.expectEqualStrings("echo", it.next().?);
    try std.testing.expectEqualStrings("hello", it.next().?);
    try std.testing.expectEqualStrings("world", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "tokenize keeps quotes raw" {
    var it = tokenize("echo \"quoted   spaces\" 'single'");
    try std.testing.expectEqualStrings("echo", it.next().?);
    try std.testing.expectEqualStrings("\"quoted   spaces\"", it.next().?);
    try std.testing.expectEqualStrings("'single'", it.next().?);
}

test "tokenize escapes keep backslash" {
    var it = tokenize("echo a\\ b");
    try std.testing.expectEqualStrings("echo", it.next().?);
    try std.testing.expectEqualStrings("a\\ b", it.next().?);
}

test "peek does not advance" {
    var it = tokenize("a b");
    try std.testing.expectEqualStrings("a", it.peek().?);
    try std.testing.expectEqualStrings("a", it.peek().?);
    _ = it.next().?;
    try std.testing.expectEqualStrings("b", it.peek().?);
}

test "rest" {
    var it = tokenize("a b c");
    _ = it.next().?;
    _ = it.next().?;
    try std.testing.expectEqualStrings("c", it.rest());
}

test "unescape double quote" {
    var dst: [64]u8 = undefined;
    const n = unescapeInto(&dst, "\"double \\\"esc\\\"\"");
    try std.testing.expectEqualStrings("double \"esc\"", dst[0..n]);
}

test "unescape single literal" {
    var dst: [64]u8 = undefined;
    const n = unescapeInto(&dst, "'no \\\"escape'");
    try std.testing.expectEqualStrings("no \\\"escape", dst[0..n]);
}

test "unescape backslash space" {
    var dst: [64]u8 = undefined;
    const n = unescapeInto(&dst, "a\\ b");
    try std.testing.expectEqualStrings("a b", dst[0..n]);
}

test "unescape mixed quoting" {
    var dst: [64]u8 = undefined;
    // a"b"'c' -> abc
    const n = unescapeInto(&dst, "a\"b\"'c'");
    try std.testing.expectEqualStrings("abc", dst[0..n]);
}

test "unescape empty quoted" {
    var dst: [64]u8 = undefined;
    const n = unescapeInto(&dst, "\"\"");
    try std.testing.expectEqualStrings("", dst[0..n]);
}

test "unescape allocating" {
    const s = try unescape(std.testing.allocator, "\"hi there\"");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hi there", s);
}