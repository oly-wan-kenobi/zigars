const std = @import("std");

pub const max_jobs = 32;
pub const max_events = 256;
pub const max_subscriptions = 64;
pub const max_roots = 16;
pub const max_text_tail = 4096;
pub const max_event_text = 512;
pub const max_label = 160;

pub const JobStatus = enum {
    queued,
    running,
    completed,
    failed,
    cancelled,

    pub fn text(self: JobStatus) []const u8 {
        return @tagName(self);
    }

    pub fn terminal(self: JobStatus) bool {
        return switch (self) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }
};

pub const JobRecord = struct {
    id: FixedString(32) = .{},
    label: FixedString(max_label) = .{},
    command: FixedString(max_label) = .{},
    status: JobStatus = .queued,
    ok: bool = false,
    created_sequence: u64 = 0,
    updated_sequence: u64 = 0,
    duration_ms: i64 = 0,
    timeout_ms: i64 = 0,
    term: FixedString(32) = .{},
    exit_code: ?i64 = null,
    stdout_tail: FixedString(max_text_tail) = .{},
    stderr_tail: FixedString(max_text_tail) = .{},
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    cancellation_requested: bool = false,
    cancellation_reason: FixedString(max_label) = .{},

    pub fn idSlice(self: *const JobRecord) []const u8 {
        return self.id.slice();
    }
};

pub const EventRecord = struct {
    sequence: u64 = 0,
    job_id: FixedString(32) = .{},
    event: FixedString(32) = .{},
    stream: FixedString(16) = .{},
    message: FixedString(max_label) = .{},
    text: FixedString(max_event_text) = .{},
    elapsed_ms: i64 = 0,
};

pub const Subscription = struct {
    id: FixedString(32) = .{},
    uri: FixedString(max_label) = .{},
    active: bool = false,
    created_sequence: u64 = 0,
};

pub const WorkspaceRoot = struct {
    id: FixedString(32) = .{},
    path: FixedString(std.fs.max_path_bytes) = .{},
    uri: FixedString(std.fs.max_path_bytes + "file://".len) = .{},
    name: FixedString(80) = .{},
    selected: bool = false,
};

pub const State = struct {
    next_job_number: u64 = 1,
    next_subscription_number: u64 = 1,
    sequence: u64 = 0,
    job_count: usize = 0,
    event_count: u64 = 0,
    subscription_count: usize = 0,
    root_count: usize = 0,
    selected_root: usize = 0,
    jobs: [max_jobs]JobRecord = [_]JobRecord{.{}} ** max_jobs,
    events: [max_events]EventRecord = [_]EventRecord{.{}} ** max_events,
    subscriptions: [max_subscriptions]Subscription = [_]Subscription{.{}} ** max_subscriptions,
    roots: [max_roots]WorkspaceRoot = [_]WorkspaceRoot{.{}} ** max_roots,

    pub fn ensureDefaultRoot(self: *State, workspace_root: []const u8) void {
        if (self.root_count > 0) return;
        _ = self.setRoot(0, "root-1", workspace_root, "default", true);
        self.root_count = 1;
        self.selected_root = 0;
    }

    pub fn startJob(self: *State, label: []const u8, command_text: []const u8, timeout_ms: i64) *JobRecord {
        const slot = self.reserveJobSlot();
        const job_number = self.next_job_number;
        self.next_job_number += 1;
        self.sequence += 1;
        slot.* = .{};
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "job-{d}", .{job_number}) catch "job";
        slot.id.set(id);
        slot.label.set(label);
        slot.command.set(command_text);
        slot.status = .running;
        slot.timeout_ms = timeout_ms;
        slot.created_sequence = self.sequence;
        slot.updated_sequence = self.sequence;
        self.appendEvent(slot.id.slice(), "started", "status", "job started", command_text, 0);
        return slot;
    }

    pub fn finishJob(self: *State, job: *JobRecord, status: JobStatus, ok: bool, duration_ms: i64, term: []const u8, exit_code: ?i64, stdout_tail: []const u8, stderr_tail: []const u8, stdout_truncated: bool, stderr_truncated: bool) void {
        self.sequence += 1;
        job.status = status;
        job.ok = ok;
        job.duration_ms = duration_ms;
        job.term.set(term);
        job.exit_code = exit_code;
        job.stdout_tail.setTail(stdout_tail);
        job.stderr_tail.setTail(stderr_tail);
        job.stdout_truncated = stdout_truncated or stdout_tail.len > job.stdout_tail.capacity();
        job.stderr_truncated = stderr_truncated or stderr_tail.len > job.stderr_tail.capacity();
        job.updated_sequence = self.sequence;
        self.appendEvent(job.id.slice(), status.text(), "status", "job finished", job.command.slice(), duration_ms);
        if (stdout_tail.len > 0) self.appendEvent(job.id.slice(), "stdout", "stdout", "stdout tail captured", stdout_tail, duration_ms);
        if (stderr_tail.len > 0) self.appendEvent(job.id.slice(), "stderr", "stderr", "stderr tail captured", stderr_tail, duration_ms);
    }

    pub fn failJob(self: *State, job: *JobRecord, err_name: []const u8, duration_ms: i64) void {
        self.sequence += 1;
        job.status = .failed;
        job.ok = false;
        job.duration_ms = duration_ms;
        job.term.set("error");
        job.stderr_tail.set(err_name);
        job.updated_sequence = self.sequence;
        self.appendEvent(job.id.slice(), "failed", "status", "job command failed", err_name, duration_ms);
    }

    pub fn cancelJob(self: *State, id: []const u8, reason: []const u8) ?*JobRecord {
        const job = self.jobById(id) orelse return null;
        job.cancellation_requested = true;
        job.cancellation_reason.set(reason);
        if (!job.status.terminal()) {
            self.sequence += 1;
            job.status = .cancelled;
            job.ok = false;
            job.updated_sequence = self.sequence;
            self.appendEvent(job.id.slice(), "cancelled", "status", "job cancellation requested", reason, job.duration_ms);
        } else {
            self.appendEvent(job.id.slice(), "cancel_requested", "status", "cancellation recorded for terminal job", reason, job.duration_ms);
        }
        return job;
    }

    pub fn jobById(self: *State, id: []const u8) ?*JobRecord {
        for (self.jobs[0..self.job_count]) |*job| {
            if (std.mem.eql(u8, job.id.slice(), id)) return job;
        }
        return null;
    }

    pub fn subscribe(self: *State, uri: []const u8) *Subscription {
        var slot: *Subscription = undefined;
        if (self.subscription_count < self.subscriptions.len) {
            slot = &self.subscriptions[self.subscription_count];
            self.subscription_count += 1;
        } else {
            slot = &self.subscriptions[0];
        }
        const sub_number = self.next_subscription_number;
        self.next_subscription_number += 1;
        self.sequence += 1;
        slot.* = .{};
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "sub-{d}", .{sub_number}) catch "sub";
        slot.id.set(id);
        slot.uri.set(uri);
        slot.active = true;
        slot.created_sequence = self.sequence;
        return slot;
    }

    pub fn unsubscribe(self: *State, id: []const u8, uri: ?[]const u8) ?*Subscription {
        for (self.subscriptions[0..self.subscription_count]) |*sub| {
            if (std.mem.eql(u8, sub.id.slice(), id) or (uri != null and std.mem.eql(u8, sub.uri.slice(), uri.?))) {
                sub.active = false;
                self.sequence += 1;
                return sub;
            }
        }
        return null;
    }

    pub fn syncRoots(self: *State, workspace_root: []const u8, roots_text: []const u8, apply: bool) void {
        if (!apply) return;
        self.root_count = 0;
        self.selected_root = 0;
        var tokens = std.mem.tokenizeAny(u8, roots_text, "\n\r\t ");
        while (tokens.next()) |token| {
            if (self.root_count >= self.roots.len) break;
            const path = if (std.mem.startsWith(u8, token, "file://")) token["file://".len..] else token;
            if (path.len == 0) continue;
            var id_buf: [32]u8 = undefined;
            const id = std.fmt.bufPrint(&id_buf, "root-{d}", .{self.root_count + 1}) catch "root";
            _ = self.setRoot(self.root_count, id, path, std.fs.path.basename(path), self.root_count == 0);
            self.root_count += 1;
        }
        if (self.root_count == 0) {
            _ = self.setRoot(0, "root-1", workspace_root, "default", true);
            self.root_count = 1;
        }
    }

    pub fn selectRoot(self: *State, root_id: []const u8, apply: bool) ?*WorkspaceRoot {
        for (self.roots[0..self.root_count], 0..) |*root, index| {
            if (std.mem.eql(u8, root.id.slice(), root_id) or std.mem.eql(u8, root.path.slice(), root_id)) {
                if (apply) {
                    for (self.roots[0..self.root_count]) |*other| other.selected = false;
                    root.selected = true;
                    self.selected_root = index;
                    self.sequence += 1;
                }
                return root;
            }
        }
        return null;
    }

    pub fn appendEvent(self: *State, job_id: []const u8, event: []const u8, stream: []const u8, message: []const u8, text: []const u8, elapsed_ms: i64) void {
        const sequence = self.event_count + 1;
        const index = ringIndex(sequence, max_events);
        self.events[index] = .{};
        self.events[index].sequence = sequence;
        self.events[index].job_id.set(job_id);
        self.events[index].event.set(event);
        self.events[index].stream.set(stream);
        self.events[index].message.set(message);
        self.events[index].text.setTail(text);
        self.events[index].elapsed_ms = elapsed_ms;
        self.event_count = sequence;
    }

    fn reserveJobSlot(self: *State) *JobRecord {
        if (self.job_count < self.jobs.len) {
            const slot = &self.jobs[self.job_count];
            self.job_count += 1;
            return slot;
        }
        return &self.jobs[0];
    }

    fn setRoot(self: *State, index: usize, id: []const u8, path: []const u8, name: []const u8, selected: bool) *WorkspaceRoot {
        const root = &self.roots[index];
        root.* = .{};
        root.id.set(id);
        root.path.set(path);
        root.name.set(name);
        root.selected = selected;
        var uri_buf: [std.fs.max_path_bytes + "file://".len]u8 = undefined;
        const uri = std.fmt.bufPrint(&uri_buf, "file://{s}", .{path}) catch "file://";
        root.uri.set(uri);
        return root;
    }
};

pub fn ringIndex(sequence: u64, comptime capacity: usize) usize {
    return @intCast((sequence - 1) % capacity);
}

pub fn FixedString(comptime n: usize) type {
    return struct {
        bytes: [n]u8 = [_]u8{0} ** n,
        len: usize = 0,
        truncated: bool = false,

        const Self = @This();

        pub fn set(self: *Self, text: []const u8) void {
            self.len = @min(text.len, n);
            if (self.len > 0) @memcpy(self.bytes[0..self.len], text[0..self.len]);
            self.truncated = text.len > n;
        }

        pub fn setTail(self: *Self, text: []const u8) void {
            if (text.len <= n) {
                self.set(text);
                return;
            }
            self.len = n;
            @memcpy(self.bytes[0..n], text[text.len - n ..]);
            self.truncated = true;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn capacity(_: Self) usize {
            return n;
        }
    };
}

test "runtime job state stores bounded command results" {
    var state: State = .{};
    const job = state.startJob("build test", "zig build test", 1000);
    state.finishJob(job, .completed, true, 12, "exited", 0, "ok\n", "", false, false);

    try std.testing.expectEqualStrings("job-1", job.id.slice());
    try std.testing.expectEqual(JobStatus.completed, job.status);
    try std.testing.expectEqual(@as(u64, 3), state.event_count);
}

test "runtime roots preview and apply are separate" {
    var state: State = .{};
    state.ensureDefaultRoot("/tmp/project");
    state.syncRoots("/tmp/project", "/tmp/a\n/tmp/b", false);
    try std.testing.expectEqual(@as(usize, 1), state.root_count);
    state.syncRoots("/tmp/project", "/tmp/a\n/tmp/b", true);
    try std.testing.expectEqual(@as(usize, 2), state.root_count);
    try std.testing.expectEqualStrings("/tmp/a", state.roots[0].path.slice());
}
