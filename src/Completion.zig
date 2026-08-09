const std = @import("std");

const CompletionRegistry = @This();

pub const Provider = enum {
    command,
    file,
    directory,
};

pub const Action = enum {
    print,
    register_external,
    register_builtin,
    unregister_external,
};

pub const Spec = union(enum) {
    builtin: Provider,
    external: []u8,

    fn deinit(self: *Spec, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .builtin => {},
            .external => |generator| gpa.free(generator),
        }
    }
};

specs: std.StringArrayHashMapUnmanaged(Spec) = .empty,

pub fn providerName(provider: Provider) []const u8 {
    return switch (provider) {
        .command => "command",
        .file => "file",
        .directory => "directory",
    };
}

pub fn parseAction(args: []const []const u8) Action {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "-p")) return .print;
        if (std.mem.eql(u8, args[0], "-C")) return .register_external;
        if (std.mem.eql(u8, args[0], "-r")) return .unregister_external;
    }
    return .register_builtin;
}

pub fn register(
    self: *CompletionRegistry,
    gpa: std.mem.Allocator,
    command: []const u8,
    spec: Spec,
) !void {
    const owned_command = try gpa.dupe(u8, command);
    errdefer gpa.free(owned_command);
    const result = try self.specs.getOrPut(gpa, command);

    if (result.found_existing) {
        result.value_ptr.deinit(gpa);
        gpa.free(owned_command);
    } else {
        result.key_ptr.* = owned_command;
    }
    result.value_ptr.* = spec;
}

pub fn unregister(
    self: *CompletionRegistry,
    gpa: std.mem.Allocator,
    command: []const u8,
) void {
    var result = self.specs.fetchSwapRemove(command) orelse return;
    gpa.free(result.key);
    result.value.deinit(gpa);
}

pub fn registerExternal(
    self: *CompletionRegistry,
    gpa: std.mem.Allocator,
    command: []const u8,
    generator: []const u8,
) !void {
    const owned_generator = try gpa.dupe(u8, generator);
    errdefer gpa.free(owned_generator);
    try self.register(gpa, command, .{ .external = owned_generator });
}

pub fn lookup(self: *const CompletionRegistry, command: []const u8) ?Spec {
    return self.specs.get(command);
}

pub fn deinit(self: *CompletionRegistry, gpa: std.mem.Allocator) void {
    var it = self.specs.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        entry.value_ptr.deinit(gpa);
    }
    self.specs.deinit(gpa);
}
