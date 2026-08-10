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
        .running => "running",
        .done => "done",
        .stopped => "stopped",
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
