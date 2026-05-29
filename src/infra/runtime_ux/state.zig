const std = @import("std");

/// Maximum active job snapshots retained in memory.
pub const max_jobs = 32;
/// Maximum runtime events retained in the ring.
pub const max_events = 256;
/// Maximum subscriptions retained in memory.
pub const max_subscriptions = 64;
/// Maximum workspace roots retained in memory.
pub const max_roots = 16;
/// Maximum tail bytes retained from command output.
pub const max_text_tail = 4096;
/// Maximum event text bytes retained per event.
pub const max_event_text = 512;
/// Maximum label bytes retained for job/root/subscription fields.
pub const max_label = 160;

/// Runtime job lifecycle state exposed through RuntimeSession snapshots.
pub const JobStatus = enum {
    queued,
    running,
    completed,
    failed,
    cancelled,

    /// Stable text used in runtime event names.
    pub fn text(self: JobStatus) []const u8 {
        return @tagName(self);
    }

    /// True when no further command execution is expected for this job.
    pub fn terminal(self: JobStatus) bool {
        return switch (self) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }
};

/// Fixed-size record for one runtime command job.
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

    /// Returns the current job id slice without exposing the backing buffer.
    pub fn idSlice(self: *const JobRecord) []const u8 {
        return self.id.slice();
    }
};

/// Fixed-size record for one job or runtime event.
pub const EventRecord = struct {
    sequence: u64 = 0,
    job_id: FixedString(32) = .{},
    event: FixedString(32) = .{},
    stream: FixedString(16) = .{},
    message: FixedString(max_label) = .{},
    text: FixedString(max_event_text) = .{},
    elapsed_ms: i64 = 0,
};

/// Fixed-size record for an active or inactive runtime subscription.
pub const Subscription = struct {
    id: FixedString(32) = .{},
    uri: FixedString(max_label) = .{},
    active: bool = false,
    created_sequence: u64 = 0,
};

/// Fixed-size record for a workspace root known to the runtime session.
pub const WorkspaceRoot = struct {
    id: FixedString(32) = .{},
    path: FixedString(std.fs.max_path_bytes) = .{},
    uri: FixedString(std.fs.max_path_bytes + "file://".len) = .{},
    name: FixedString(80) = .{},
    selected: bool = false,
};

/// In-memory runtime UX state with bounded job, event, subscription, and root storage.
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

    /// Ensures at least one selected root exists, using the process workspace root.
    pub fn ensureDefaultRoot(self: *State, workspace_root: []const u8) void {
        if (self.root_count > 0) return;
        _ = self.setRoot(0, "root-1", workspace_root, "default", true);
        self.root_count = 1;
        self.selected_root = 0;
    }

    /// Starts a job, assigns a monotonic id, and emits a started event.
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

    /// Finalizes a job and records bounded stdout/stderr tails as events.
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

    /// Marks a job failed from an infra error name.
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

    /// Records cancellation intent and transitions non-terminal jobs to cancelled.
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

    /// Finds a retained job by id.
    pub fn jobById(self: *State, id: []const u8) ?*JobRecord {
        for (self.jobs[0..self.job_count]) |*job| {
            if (std.mem.eql(u8, job.id.slice(), id)) return job;
        }
        return null;
    }

    /// Creates a subscription, overwriting the oldest slot after capacity.
    pub fn subscribe(self: *State, uri: []const u8) *Subscription {
        // Rotate slots via the about-to-be-assigned monotonic number so the
        // oldest subscription is evicted once the buffer fills (same ring as jobs).
        const slot = &self.subscriptions[ringIndex(self.next_subscription_number, max_subscriptions)];
        if (self.subscription_count < self.subscriptions.len) self.subscription_count += 1;
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

    /// Marks a subscription inactive by id, or by uri when provided.
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

    /// Replaces roots from whitespace-separated paths when `apply` is true.
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

    /// Selects a root by id or path; preview calls return a match without mutation.
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

    /// Appends an event to the bounded event ring.
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

    /// Reserves the next runtime job slot, overwriting the oldest after capacity.
    fn reserveJobSlot(self: *State) *JobRecord {
        // Mirror the event ring: the about-to-be-assigned monotonic number maps
        // to a rotating slot so the oldest job is evicted once the buffer fills.
        const slot = &self.jobs[ringIndex(self.next_job_number, max_jobs)];
        if (self.job_count < self.jobs.len) self.job_count += 1;
        return slot;
    }

    /// Stores a runtime root entry at the requested index.
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

/// Maps a one-based event sequence to its ring slot.
pub fn ringIndex(sequence: u64, comptime capacity: usize) usize {
    return @intCast((sequence - 1) % capacity);
}

/// Fixed-capacity string that records truncation instead of allocating.
pub fn FixedString(comptime n: usize) type {
    return struct {
        bytes: [n]u8 = [_]u8{0} ** n,
        len: usize = 0,
        truncated: bool = false,

        const Self = @This();

        /// Stores the prefix of `text` up to capacity.
        pub fn set(self: *Self, text: []const u8) void {
            self.len = @min(text.len, n);
            if (self.len > 0) @memcpy(self.bytes[0..self.len], text[0..self.len]);
            self.truncated = text.len > n;
        }

        /// Stores the suffix of `text` up to capacity.
        pub fn setTail(self: *Self, text: []const u8) void {
            if (text.len <= n) {
                self.set(text);
                return;
            }
            self.len = n;
            @memcpy(self.bytes[0..n], text[text.len - n ..]);
            self.truncated = true;
        }

        /// Returns the populated portion of the fixed buffer.
        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        /// Returns the compile-time byte capacity.
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

test "runtime subscriptions cancellation roots and rings cover branch behavior" {
    var state: State = .{};
    try std.testing.expect(!JobStatus.running.terminal());
    try std.testing.expect(JobStatus.cancelled.terminal());
    try std.testing.expectEqualStrings("failed", JobStatus.failed.text());

    const job = state.startJob("check", "zig ast-check src/main.zig", 100);
    try std.testing.expectEqualStrings("job-1", job.idSlice());
    try std.testing.expect(state.jobById("job-1") != null);
    try std.testing.expect(state.jobById("job-404") == null);
    const cancelled = state.cancelJob("job-1", "client requested").?;
    try std.testing.expectEqual(JobStatus.cancelled, cancelled.status);
    try std.testing.expectEqualStrings("client requested", cancelled.cancellation_reason.slice());
    const terminal_cancel = state.cancelJob("job-1", "audit").?;
    try std.testing.expectEqual(JobStatus.cancelled, terminal_cancel.status);
    try std.testing.expect(state.cancelJob("job-404", "none") == null);

    const failed_job = state.startJob("build", "zig build", 200);
    state.failJob(failed_job, "Timeout", 55);
    try std.testing.expectEqual(JobStatus.failed, failed_job.status);
    try std.testing.expectEqualStrings("error", failed_job.term.slice());
    try std.testing.expectEqualStrings("Timeout", failed_job.stderr_tail.slice());

    const sub = state.subscribe("zigars://jobs");
    try std.testing.expectEqualStrings("sub-1", sub.id.slice());
    try std.testing.expect(sub.active);
    try std.testing.expect(!state.unsubscribe("missing", "zigars://jobs").?.active);
    try std.testing.expect(state.unsubscribe("missing", null) == null);

    state.syncRoots("/tmp/project", "", true);
    try std.testing.expectEqual(@as(usize, 1), state.root_count);
    try std.testing.expectEqualStrings("/tmp/project", state.roots[0].path.slice());
    state.syncRoots("/tmp/project", "file:///tmp/a\n/tmp/b\n/tmp/c", true);
    try std.testing.expectEqual(@as(usize, 3), state.root_count);
    try std.testing.expectEqualStrings("file:///tmp/a", state.roots[0].uri.slice());
    const preview = state.selectRoot("root-2", false).?;
    try std.testing.expect(!preview.selected);
    const selected = state.selectRoot("/tmp/b", true).?;
    try std.testing.expect(selected.selected);
    try std.testing.expectEqual(@as(usize, 1), state.selected_root);
    try std.testing.expect(state.selectRoot("root-missing", true) == null);

    const before_ring_events = state.event_count;
    var i: usize = 0;
    while (i < max_events + 3) : (i += 1) {
        state.appendEvent("job-1", "stdout", "stdout", "tail", "line", @intCast(i));
    }
    try std.testing.expectEqual(before_ring_events + max_events + 3, state.event_count);
    try std.testing.expectEqual(@as(usize, 0), ringIndex(1, max_events));
    try std.testing.expectEqual(@as(usize, 0), ringIndex(max_events + 1, max_events));

    var short: FixedString(4) = .{};
    short.set("abcdef");
    try std.testing.expect(short.truncated);
    try std.testing.expectEqualStrings("abcd", short.slice());
    short.setTail("xyzabcdef");
    try std.testing.expect(short.truncated);
    try std.testing.expectEqualStrings("cdef", short.slice());
    try std.testing.expectEqual(@as(usize, 4), short.capacity());
}

test "runtime rings overwrite oldest jobs and subscriptions" {
    var state: State = .{};

    var i: usize = 0;
    while (i < max_jobs + 1) : (i += 1) {
        _ = state.startJob("job", "zig build", 100);
    }
    try std.testing.expectEqual(@as(usize, max_jobs), state.job_count);
    try std.testing.expectEqualStrings("job-33", state.jobs[0].id.slice());

    i = 0;
    while (i < max_subscriptions + 1) : (i += 1) {
        _ = state.subscribe("zigars://jobs");
    }
    try std.testing.expectEqual(@as(usize, max_subscriptions), state.subscription_count);
    var expected_sub_id: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_sub_id, "sub-{d}", .{max_subscriptions + 1});
    try std.testing.expectEqualStrings(expected, state.subscriptions[0].id.slice());
}

test "runtime job ring evicts the oldest after max_jobs + 2 and keeps the newest retrievable" {
    var state: State = .{};

    // Push two past capacity. The pre-fix slot-0 churn loses job-33 (clobbered by
    // job-34) and never evicts the genuinely oldest entries.
    var i: usize = 0;
    while (i < max_jobs + 2) : (i += 1) {
        _ = state.startJob("job", "zig build", 100);
    }
    try std.testing.expectEqual(@as(usize, max_jobs), state.job_count);

    // Oldest two (job-1, job-2) are evicted; everything newer survives.
    try std.testing.expect(state.jobById("job-1") == null);
    try std.testing.expect(state.jobById("job-2") == null);
    var n: usize = 3;
    while (n <= max_jobs + 2) : (n += 1) {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "job-{d}", .{n});
        try std.testing.expect(state.jobById(id) != null);
    }

    // The 33rd and 34th jobs (first two past capacity) remain retrievable by id.
    try std.testing.expect(state.jobById("job-33") != null);
    try std.testing.expect(state.jobById("job-34") != null);

    // created_sequence must be strictly increasing in job-number order, so a
    // tasks/list projection sorted by created_sequence yields oldest-to-newest.
    var previous_sequence: u64 = 0;
    n = 3;
    while (n <= max_jobs + 2) : (n += 1) {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "job-{d}", .{n});
        const job = state.jobById(id).?;
        try std.testing.expect(job.created_sequence > previous_sequence);
        previous_sequence = job.created_sequence;
    }
}

test "runtime subscription ring evicts the oldest after max_subscriptions + 2" {
    var state: State = .{};

    var i: usize = 0;
    while (i < max_subscriptions + 2) : (i += 1) {
        _ = state.subscribe("zigars://jobs");
    }
    try std.testing.expectEqual(@as(usize, max_subscriptions), state.subscription_count);

    // Slot 1 now holds the newest subscription (sub-66), not a frozen old one;
    // the pre-fix slot-0 churn would clobber sub-65 and leave sub-2 pinned here.
    var expected_sub_id: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_sub_id, "sub-{d}", .{max_subscriptions + 2});
    try std.testing.expectEqualStrings(expected, state.subscriptions[1].id.slice());

    // The two slots that wrapped hold the two newest ids; the genuinely oldest
    // subscriptions (sub-1, sub-2) are gone rather than pinned forever.
    for (state.subscriptions[0..state.subscription_count]) |sub| {
        try std.testing.expect(!std.mem.eql(u8, sub.id.slice(), "sub-1"));
        try std.testing.expect(!std.mem.eql(u8, sub.id.slice(), "sub-2"));
    }
    var sub65_buf: [32]u8 = undefined;
    const sub65 = try std.fmt.bufPrint(&sub65_buf, "sub-{d}", .{max_subscriptions + 1});
    var found_sub65 = false;
    for (state.subscriptions[0..state.subscription_count]) |sub| {
        if (std.mem.eql(u8, sub.id.slice(), sub65)) found_sub65 = true;
    }
    try std.testing.expect(found_sub65);
}
