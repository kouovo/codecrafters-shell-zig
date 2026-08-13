const std = @import("std");
pub const State = enum { running, stopped, done };
pub const Type = enum { bg, fg };

pub fn marker(self: *JobRegistry, id: usize) []const u8 {
    if (self.current_id == id) return "+";
    if (self.previous_id == id) return "-";
    return " ";
}

pub fn stateName(state: State) []const u8 {
    return switch (state) {
        .running => "Running",
        .done => "Done",
        .stopped => "Stopped",
    };
}

pub const Job = struct {
    id: usize,
    type: Type,
    pgid: std.posix.pid_t,
    state: State,
    command: []u8,
};

pub const JobRegistry = @This();
jobs: std.ArrayList(Job) = .empty,
next_id: usize = 1,
current_id: ?usize = null,
previous_id: ?usize = null,

fn waitpidNoHang(pid: std.posix.pid_t) !?struct {
    pid: std.posix.pid_t,
    status: u32,
} {
    var status: u32 = undefined;
    const rc = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);

    switch (std.posix.errno(rc)) {
        .SUCCESS => {
            const got: std.posix.pid_t = @intCast(rc);
            if (got == 0) return null;
            return .{ .pid = got, .status = status };
        },
        .CHILD => return null,
        .INTR => return error.Interrupted,
        else => return error.Unexpected,
    }
}

pub fn reap(
    self: *JobRegistry,
) !void {
    for (self.jobs.items) |*job| {
        if (job.state != .running) continue;

        if (try waitpidNoHang(job.pgid) == null) {
            continue;
        }

        job.state = .done;
    }
}

pub fn add(
    self: *JobRegistry,
    gpa: std.mem.Allocator,
    job: Job,
) !usize {
    const id = self.next_id;
    self.next_id += 1;
    var owned = job;
    owned.id = id;
    try self.jobs.append(gpa, owned);
    self.previous_id = self.current_id;
    self.current_id = id;
    return id;
}

pub fn deinit(self: *JobRegistry, gpa: std.mem.Allocator) void {
    for (self.jobs.items) |job| {
        gpa.free(job.command);
    }
    self.jobs.deinit(gpa);
}

pub fn items(self: *const JobRegistry) []const Job {
    return self.jobs.items;
}
