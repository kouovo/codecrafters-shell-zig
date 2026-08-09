const std = @import("std");
pub const State = enum { running, stopped, done };
pub const Type = enum { bg, fg };

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
    return id;
}

pub fn deinit(self: *JobRegistry, gpa: std.mem.Allocator) void {
    for (self.jobs.items) |job| {
        gpa.free(job.command);
    }
    self.jobs.deinit(gpa);
}
