const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const path_policy = @import("../../../domain/editing/path_policy.zig");
const session_domain = @import("../../../domain/editing/patch_session.zig");
const validation_usecase = @import("../validation/workflows.zig");

pub const schema_version: i64 = 1;
pub const history_path_default = ".zigar-cache/patch-sessions/history.jsonl";
pub const max_session_file_bytes: usize = 10 * 1024 * 1024;
pub const history_max_bytes: usize = 8 * 1024 * 1024;

pub const PathPolicy = path_policy.PathPolicy;
pub const Identity = session_domain.Identity;
pub const ExpectedPreimage = session_domain.ExpectedPreimage;

pub const Replacement = struct {
    file: []const u8,
    content: []const u8,
};

pub const CreateRequest = struct {
    session_id: []const u8,
    goal: ?[]const u8 = null,
    paths: []const []const u8,
};

pub const SessionFileState = struct {
    file: []const u8,
    preimage_identity: Identity,
    policy: PathPolicy,

    pub fn deinit(self: *SessionFileState, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        self.preimage_identity.deinit(allocator);
        self.* = undefined;
    }
};

pub const FileFailure = struct {
    file: []const u8,
    error_name: []const u8,

    pub fn deinit(self: *FileFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        self.* = undefined;
    }
};

pub const CreateFile = union(enum) {
    ok: SessionFileState,
    err: FileFailure,

    pub fn deinit(self: *CreateFile, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*state| state.deinit(allocator),
            .err => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const CreateResult = struct {
    session_id: []const u8,
    goal: ?[]const u8,
    safe_to_edit: bool,
    files: []CreateFile,
    expected_preimages: []ExpectedPreimage,

    pub fn deinit(self: *CreateResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        if (self.goal) |goal| allocator.free(goal);
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        freeExpectedPreimages(allocator, self.expected_preimages);
        self.* = undefined;
    }
};

pub const ReplacementOperation = enum {
    preview,
    apply,

    pub fn kind(self: ReplacementOperation) []const u8 {
        return switch (self) {
            .preview => "zigar_patch_session_preview",
            .apply => "zigar_patch_session_apply",
        };
    }
};

pub const ReplacementRequest = struct {
    operation: ReplacementOperation,
    session_id: []const u8,
    goal: ?[]const u8 = null,
    replacements: []const Replacement,
    expected_preimages: []const ExpectedPreimage = &.{},
    apply: bool,
};

pub const ReplacementFile = struct {
    file: []const u8,
    changed: bool,
    preimage_identity: Identity,
    updated_identity: Identity,
    policy: PathPolicy,
    expected_preimage_matched: bool,
    diff: []const u8,

    pub fn deinit(self: *ReplacementFile, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        self.preimage_identity.deinit(allocator);
        self.updated_identity.deinit(allocator);
        allocator.free(self.diff);
        self.* = undefined;
    }
};

pub const HistoryFileRecord = struct {
    file: []const u8,
    preimage_identity: Identity,
    updated_identity: Identity,
    preimage_content_path: ?[]const u8,

    pub fn deinit(self: *HistoryFileRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        self.preimage_identity.deinit(allocator);
        self.updated_identity.deinit(allocator);
        if (self.preimage_content_path) |path| allocator.free(path);
        self.* = undefined;
    }

    pub fn clone(self: HistoryFileRecord, allocator: std.mem.Allocator) !HistoryFileRecord {
        const file = try allocator.dupe(u8, self.file);
        errdefer allocator.free(file);
        var preimage_identity = try self.preimage_identity.clone(allocator);
        errdefer preimage_identity.deinit(allocator);
        var updated_identity = try self.updated_identity.clone(allocator);
        errdefer updated_identity.deinit(allocator);
        const preimage_content_path = if (self.preimage_content_path) |path| try allocator.dupe(u8, path) else null;
        errdefer if (preimage_content_path) |path| allocator.free(path);
        return .{
            .file = file,
            .preimage_identity = preimage_identity,
            .updated_identity = updated_identity,
            .preimage_content_path = preimage_content_path,
        };
    }
};

pub const SessionRecord = struct {
    session_id: []const u8,
    goal: ?[]const u8,
    recorded_unix_ms: i64,
    files: []HistoryFileRecord,

    pub fn deinit(self: *SessionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        if (self.goal) |goal| allocator.free(goal);
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }
};

pub const ReplacementResult = struct {
    operation: ReplacementOperation,
    session_id: []const u8,
    goal: ?[]const u8,
    applied: bool,
    requires_apply: bool,
    safe_to_apply: bool,
    changed_file_count: usize,
    blocked: bool,
    files: []ReplacementFile,
    expected_preimages: []ExpectedPreimage,
    history_path: []const u8 = history_path_default,

    pub fn deinit(self: *ReplacementResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        if (self.goal) |goal| allocator.free(goal);
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        freeExpectedPreimages(allocator, self.expected_preimages);
        self.* = undefined;
    }
};

pub const RevertRequest = struct {
    session_id: []const u8,
    apply: bool = false,
    history: ?[]const u8 = null,
    history_path: []const u8 = history_path_default,
};

pub const RevertFile = struct {
    file: []const u8,
    safe_to_revert: bool,
    current_matches_session_output: bool,
    current_identity: Identity,
    target_preimage_identity: Identity,
    preimage_content_path: ?[]const u8,
    would_delete: bool,
    diff: []const u8,

    pub fn deinit(self: *RevertFile, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        self.current_identity.deinit(allocator);
        self.target_preimage_identity.deinit(allocator);
        if (self.preimage_content_path) |path| allocator.free(path);
        allocator.free(self.diff);
        self.* = undefined;
    }
};

pub const RevertResult = struct {
    session_id: []const u8,
    applied: bool,
    requires_apply: bool,
    safe_to_revert: bool,
    files: []RevertFile,
    record: SessionRecord,

    pub fn deinit(self: *RevertResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        self.record.deinit(allocator);
        self.* = undefined;
    }
};

pub const RevertFailure = union(enum) {
    not_found,
};

pub const RevertOutcome = union(enum) {
    ok: RevertResult,
    err: RevertFailure,

    pub fn deinit(self: *RevertOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*result| result.deinit(allocator),
            .err => {},
        }
        self.* = undefined;
    }
};

pub fn classifyPath(path: []const u8) PathPolicy {
    return path_policy.classify(path);
}

pub fn create(allocator: std.mem.Allocator, context: app_context.EditingContext, request: CreateRequest) !CreateResult {
    var files = std.ArrayList(CreateFile).empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }
    var expected = std.ArrayList(ExpectedPreimage).empty;
    errdefer {
        freeExpectedPreimageItems(allocator, expected.items);
        expected.deinit(allocator);
    }

    var safe = true;
    for (request.paths) |path| {
        var snapshot = readSnapshot(allocator, context, path) catch |err| {
            safe = false;
            try files.ensureUnusedCapacity(allocator, 1);
            const failed_file = try createFileError(allocator, path, @errorName(err));
            files.appendAssumeCapacity(failed_file);
            continue;
        };
        defer snapshot.deinit(allocator);

        const policy = classifyPath(snapshot.file);
        if (!policy.direct_edit_allowed) safe = false;
        var preimage = try session_domain.identityFromBytes(allocator, snapshot.exists, snapshot.bytes);
        defer preimage.deinit(allocator);
        try expected.ensureUnusedCapacity(allocator, 1);
        const expected_preimage = try expectedPreimageFromIdentity(allocator, snapshot.file, preimage);
        expected.appendAssumeCapacity(expected_preimage);

        try files.ensureUnusedCapacity(allocator, 1);
        const file = try createFileOk(allocator, snapshot.file, preimage, policy);
        files.appendAssumeCapacity(file);
    }

    const owned_files = try files.toOwnedSlice(allocator);
    errdefer {
        for (owned_files) |*file| file.deinit(allocator);
        allocator.free(owned_files);
    }
    const owned_expected = try expected.toOwnedSlice(allocator);
    errdefer freeExpectedPreimages(allocator, owned_expected);
    const session_id = try allocator.dupe(u8, request.session_id);
    errdefer allocator.free(session_id);
    const goal = if (request.goal) |text| try allocator.dupe(u8, text) else null;
    return .{
        .session_id = session_id,
        .goal = goal,
        .safe_to_edit = safe,
        .files = owned_files,
        .expected_preimages = owned_expected,
    };
}

pub fn replacementSession(allocator: std.mem.Allocator, context: app_context.EditingContext, request: ReplacementRequest) !ReplacementResult {
    var files = std.ArrayList(ReplacementFile).empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }
    var expected = std.ArrayList(ExpectedPreimage).empty;
    errdefer {
        freeExpectedPreimageItems(allocator, expected.items);
        expected.deinit(allocator);
    }
    var history_files = std.ArrayList(HistoryFileRecord).empty;
    errdefer {
        for (history_files.items) |*file| file.deinit(allocator);
        history_files.deinit(allocator);
    }

    var safe = true;
    var changed_count: usize = 0;
    for (request.replacements, 0..) |replacement, index| {
        var snapshot = try readSnapshot(allocator, context, replacement.file);
        defer snapshot.deinit(allocator);

        const policy = classifyPath(snapshot.file);
        var preimage = try session_domain.identityFromBytes(allocator, snapshot.exists, snapshot.bytes);
        defer preimage.deinit(allocator);
        var updated = try session_domain.identityFromBytes(allocator, true, replacement.content);
        defer updated.deinit(allocator);
        const changed = !snapshot.exists or !std.mem.eql(u8, snapshot.bytes, replacement.content);
        if (changed) changed_count += 1;
        const expected_ok = !request.apply or session_domain.expectedMatches(request.expected_preimages, snapshot.file, preimage);
        if (!policy.direct_edit_allowed or !expected_ok) safe = false;

        const diff = try session_domain.unifiedDiff(allocator, snapshot.file, snapshot.bytes, replacement.content);
        var diff_owned = false;
        errdefer if (!diff_owned) allocator.free(diff);
        const expected_item = try expectedPreimageFromIdentity(allocator, snapshot.file, preimage);
        var expected_owned = false;
        errdefer if (!expected_owned) deinitExpectedPreimage(allocator, expected_item);
        try expected.append(allocator, expected_item);
        expected_owned = true;

        var result_file = try replacementFileFromParts(allocator, snapshot.file, changed, preimage, updated, policy, expected_ok, diff);
        diff_owned = true;
        var result_file_owned = false;
        errdefer if (!result_file_owned) result_file.deinit(allocator);
        try files.append(allocator, result_file);
        result_file_owned = true;

        var history_file = try historyFileForReplacement(allocator, request.session_id, index, snapshot.file, preimage, updated, changed);
        var history_file_owned = false;
        errdefer if (!history_file_owned) history_file.deinit(allocator);
        try history_files.append(allocator, history_file);
        history_file_owned = true;
    }

    if (request.apply and !safe) {
        for (history_files.items) |*file| file.deinit(allocator);
        history_files.deinit(allocator);
        history_files = .empty;
        return replacementResultFromParts(allocator, request, false, false, false, changed_count, true, &files, &expected);
    }

    if (request.apply) {
        for (request.replacements, 0..) |replacement, index| {
            var snapshot = try readSnapshot(allocator, context, replacement.file);
            defer snapshot.deinit(allocator);
            if (!snapshot.exists or !std.mem.eql(u8, snapshot.bytes, replacement.content)) {
                const artifact_path = try session_domain.preimageArtifactPath(allocator, request.session_id, index, snapshot.file);
                defer allocator.free(artifact_path);
                _ = try context.workspace_store.write(.{
                    .path = artifact_path,
                    .bytes = snapshot.bytes,
                    .provenance = "patch_session_preimage",
                });
                _ = try context.workspace_store.write(.{
                    .path = snapshot.file,
                    .bytes = replacement.content,
                    .provenance = "patch_session_apply",
                });
            }
        }
        var record = try sessionRecord(allocator, context, request.session_id, request.goal, history_files.items);
        defer record.deinit(allocator);
        try appendSessionHistory(allocator, context, history_path_default, record);
    }

    for (history_files.items) |*file| file.deinit(allocator);
    history_files.deinit(allocator);
    history_files = .empty;
    return replacementResultFromParts(allocator, request, request.apply, !request.apply, safe, changed_count, false, &files, &expected);
}

pub fn revert(allocator: std.mem.Allocator, context: app_context.EditingContext, request: RevertRequest) !RevertOutcome {
    var record = loadSessionRecord(allocator, context, request) catch |err| switch (err) {
        error.SessionNotFound => return .{ .err = .not_found },
        else => return err,
    };
    errdefer record.deinit(allocator);

    var files = std.ArrayList(RevertFile).empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }
    var safe = true;
    for (record.files) |record_file| {
        const preview = try revertFilePreview(allocator, context, record_file);
        if (!preview.safe_to_revert) safe = false;
        try files.append(allocator, preview);
    }

    if (request.apply and safe) {
        for (record.files) |record_file| try applyRevertFile(allocator, context, record_file);
    }

    const owned_files = try files.toOwnedSlice(allocator);
    errdefer {
        for (owned_files) |*file| file.deinit(allocator);
        allocator.free(owned_files);
    }
    const session_id = try allocator.dupe(u8, request.session_id);
    return .{ .ok = .{
        .session_id = session_id,
        .applied = request.apply and safe,
        .requires_apply = !request.apply,
        .safe_to_revert = safe,
        .files = owned_files,
        .record = record,
    } };
}

pub fn validate(
    allocator: std.mem.Allocator,
    context: app_context.ValidationContext,
    request: validation_usecase.RunRequest,
) !validation_usecase.RunOutcome {
    return validation_usecase.run(allocator, context, request);
}

fn replacementResultFromParts(
    allocator: std.mem.Allocator,
    request: ReplacementRequest,
    applied: bool,
    requires_apply: bool,
    safe: bool,
    changed_count: usize,
    blocked: bool,
    files: *std.ArrayList(ReplacementFile),
    expected: *std.ArrayList(ExpectedPreimage),
) !ReplacementResult {
    const owned_files = try files.toOwnedSlice(allocator);
    errdefer {
        for (owned_files) |*file| file.deinit(allocator);
        allocator.free(owned_files);
    }
    const owned_expected = try expected.toOwnedSlice(allocator);
    errdefer freeExpectedPreimages(allocator, owned_expected);
    const session_id = try allocator.dupe(u8, request.session_id);
    errdefer allocator.free(session_id);
    const goal = if (request.goal) |text| try allocator.dupe(u8, text) else null;
    return .{
        .operation = request.operation,
        .session_id = session_id,
        .goal = goal,
        .applied = applied,
        .requires_apply = requires_apply,
        .safe_to_apply = safe,
        .changed_file_count = changed_count,
        .blocked = blocked,
        .files = owned_files,
        .expected_preimages = owned_expected,
    };
}

fn createFileOk(allocator: std.mem.Allocator, file: []const u8, preimage: Identity, policy: PathPolicy) !CreateFile {
    const owned_file = try allocator.dupe(u8, file);
    errdefer allocator.free(owned_file);
    var owned_identity = try preimage.clone(allocator);
    errdefer owned_identity.deinit(allocator);
    return .{ .ok = .{
        .file = owned_file,
        .preimage_identity = owned_identity,
        .policy = policy,
    } };
}

fn createFileError(allocator: std.mem.Allocator, file: []const u8, error_name: []const u8) !CreateFile {
    const owned_file = try allocator.dupe(u8, file);
    errdefer allocator.free(owned_file);
    return .{ .err = .{
        .file = owned_file,
        .error_name = error_name,
    } };
}

fn replacementFileFromParts(
    allocator: std.mem.Allocator,
    file: []const u8,
    changed: bool,
    preimage: Identity,
    updated: Identity,
    policy: PathPolicy,
    expected_ok: bool,
    diff: []const u8,
) !ReplacementFile {
    const owned_file = try allocator.dupe(u8, file);
    errdefer allocator.free(owned_file);
    var owned_preimage = try preimage.clone(allocator);
    errdefer owned_preimage.deinit(allocator);
    var owned_updated = try updated.clone(allocator);
    errdefer owned_updated.deinit(allocator);
    return .{
        .file = owned_file,
        .changed = changed,
        .preimage_identity = owned_preimage,
        .updated_identity = owned_updated,
        .policy = policy,
        .expected_preimage_matched = expected_ok,
        .diff = diff,
    };
}

fn historyFileForReplacement(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    index: usize,
    file: []const u8,
    preimage: Identity,
    updated: Identity,
    changed: bool,
) !HistoryFileRecord {
    const owned_file = try allocator.dupe(u8, file);
    errdefer allocator.free(owned_file);
    var owned_preimage = try preimage.clone(allocator);
    errdefer owned_preimage.deinit(allocator);
    var owned_updated = try updated.clone(allocator);
    errdefer owned_updated.deinit(allocator);
    const preimage_content_path = if (changed) try session_domain.preimageArtifactPath(allocator, session_id, index, file) else null;
    errdefer if (preimage_content_path) |path| allocator.free(path);
    return .{
        .file = owned_file,
        .preimage_identity = owned_preimage,
        .updated_identity = owned_updated,
        .preimage_content_path = preimage_content_path,
    };
}

const FileSnapshot = struct {
    file: []const u8,
    bytes: []const u8,
    exists: bool,
    read_result: ?ports.WorkspaceReadResult = null,

    fn deinit(self: *FileSnapshot, allocator: std.mem.Allocator) void {
        if (self.read_result) |result| result.deinit(allocator);
        self.* = undefined;
    }
};

fn readSnapshot(allocator: std.mem.Allocator, context: app_context.EditingContext, path: []const u8) !FileSnapshot {
    const result = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotFound => return .{
            .file = path,
            .bytes = "",
            .exists = false,
            .read_result = null,
        },
        else => return err,
    };
    return .{
        .file = path,
        .bytes = result.bytes,
        .exists = true,
        .read_result = result,
    };
}

fn expectedPreimageFromIdentity(allocator: std.mem.Allocator, file: []const u8, identity: Identity) !ExpectedPreimage {
    const owned_file = try allocator.dupe(u8, file);
    errdefer allocator.free(owned_file);
    var owned_identity = try identity.clone(allocator);
    errdefer owned_identity.deinit(allocator);
    return .{
        .file = owned_file,
        .identity = owned_identity,
    };
}

fn deinitExpectedPreimage(allocator: std.mem.Allocator, expected: ExpectedPreimage) void {
    allocator.free(expected.file);
    var identity = expected.identity;
    identity.deinit(allocator);
}

fn freeExpectedPreimages(allocator: std.mem.Allocator, expected: []const ExpectedPreimage) void {
    freeExpectedPreimageItems(allocator, expected);
    allocator.free(expected);
}

fn freeExpectedPreimageItems(allocator: std.mem.Allocator, expected: []const ExpectedPreimage) void {
    for (expected) |item| {
        deinitExpectedPreimage(allocator, item);
    }
}

fn sessionRecord(
    allocator: std.mem.Allocator,
    context: app_context.EditingContext,
    session_id: []const u8,
    goal: ?[]const u8,
    files: []const HistoryFileRecord,
) !SessionRecord {
    const now = try context.clock_and_ids.now();
    const owned_files = try allocator.alloc(HistoryFileRecord, files.len);
    var initialized: usize = 0;
    errdefer {
        for (owned_files[0..initialized]) |*file| file.deinit(allocator);
        allocator.free(owned_files);
    }
    for (files, 0..) |file, index| {
        owned_files[index] = try file.clone(allocator);
        initialized += 1;
    }
    const owned_session_id = try allocator.dupe(u8, session_id);
    errdefer allocator.free(owned_session_id);
    const owned_goal = if (goal) |text| try allocator.dupe(u8, text) else null;
    errdefer if (owned_goal) |text| allocator.free(text);
    return .{
        .session_id = owned_session_id,
        .goal = owned_goal,
        .recorded_unix_ms = now.unix_ms,
        .files = owned_files,
    };
}

fn appendSessionHistory(allocator: std.mem.Allocator, context: app_context.EditingContext, path: []const u8, record: SessionRecord) !void {
    const line = try recordJsonLine(allocator, record);
    defer allocator.free(line);
    const existing_result: ?ports.WorkspaceReadResult = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = history_max_bytes,
        .provenance = "patch_session_history_read",
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotFound => null,
        else => return err,
    };
    defer if (existing_result) |result| result.deinit(allocator);
    const existing = if (existing_result) |result| result.bytes else "";
    var bytes = std.ArrayList(u8).empty;
    try bytes.appendSlice(allocator, existing);
    if (bytes.items.len > 0 and bytes.items[bytes.items.len - 1] != '\n') try bytes.append(allocator, '\n');
    try bytes.appendSlice(allocator, line);
    try bytes.append(allocator, '\n');
    defer bytes.deinit(allocator);
    _ = try context.workspace_store.write(.{
        .path = path,
        .bytes = bytes.items,
        .provenance = "patch_session_history_append",
    });
}

fn loadSessionRecord(allocator: std.mem.Allocator, context: app_context.EditingContext, request: RevertRequest) !SessionRecord {
    var history_read: ?ports.WorkspaceReadResult = null;
    const text = request.history orelse blk: {
        const result = try context.workspace_store.read(allocator, .{
            .path = request.history_path,
            .max_bytes = history_max_bytes,
            .provenance = "patch_session_history_read",
        });
        history_read = result;
        break :blk result.bytes;
    };
    defer if (history_read) |result| result.deinit(allocator);
    return parseSessionRecord(allocator, text, request.session_id);
}

fn parseSessionRecord(allocator: std.mem.Allocator, text: []const u8, session_id: []const u8) !SessionRecord {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.SessionNotFound;
    if (trimmed[0] == '[') {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
        defer parsed.deinit();
        const array = parsed.value.array;
        for (array.items) |item| {
            if (try recordFromValueIfMatch(allocator, item, session_id)) |record| return record;
        }
        return error.SessionNotFound;
    }

    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (try recordFromValueIfMatch(allocator, parsed.value, session_id)) |record| return record;
    }
    return error.SessionNotFound;
}

fn recordFromValueIfMatch(allocator: std.mem.Allocator, value: std.json.Value, session_id: []const u8) !?SessionRecord {
    const obj = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const found = stringField(obj, "session_id") orelse return null;
    if (!std.mem.eql(u8, found, session_id)) return null;
    const files_value = switch (obj.get("files") orelse .null) {
        .array => |array| array,
        else => return error.InvalidArguments,
    };
    var files = std.ArrayList(HistoryFileRecord).empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }
    for (files_value.items) |item| {
        var file = try historyFileFromValue(allocator, item);
        var file_owned = false;
        errdefer if (!file_owned) file.deinit(allocator);
        try files.append(allocator, file);
        file_owned = true;
    }
    const owned_files = try files.toOwnedSlice(allocator);
    errdefer {
        for (owned_files) |*file| file.deinit(allocator);
        allocator.free(owned_files);
    }
    const owned_session_id = try allocator.dupe(u8, found);
    errdefer allocator.free(owned_session_id);
    const owned_goal = if (stringField(obj, "goal")) |goal| try allocator.dupe(u8, goal) else null;
    return .{
        .session_id = owned_session_id,
        .goal = owned_goal,
        .recorded_unix_ms = integerField(obj, "recorded_unix_ms") orelse 0,
        .files = owned_files,
    };
}

fn historyFileFromValue(allocator: std.mem.Allocator, value: std.json.Value) !HistoryFileRecord {
    const obj = switch (value) {
        .object => |object| object,
        else => return error.InvalidArguments,
    };
    const file = try allocator.dupe(u8, stringField(obj, "file") orelse return error.InvalidArguments);
    errdefer allocator.free(file);
    var preimage_identity = try identityFromValue(allocator, obj.get("preimage_identity") orelse .null);
    errdefer preimage_identity.deinit(allocator);
    var updated_identity = try identityFromValue(allocator, obj.get("updated_identity") orelse .null);
    errdefer updated_identity.deinit(allocator);
    const preimage_content_path = if (stringField(obj, "preimage_content_path")) |path| try allocator.dupe(u8, path) else null;
    errdefer if (preimage_content_path) |path| allocator.free(path);
    return .{
        .file = file,
        .preimage_identity = preimage_identity,
        .updated_identity = updated_identity,
        .preimage_content_path = preimage_content_path,
    };
}

fn identityFromValue(allocator: std.mem.Allocator, value: std.json.Value) !Identity {
    const obj = switch (value) {
        .object => |object| object,
        else => return error.InvalidArguments,
    };
    const exists = boolField(obj, "exists") orelse false;
    return .{
        .exists = exists,
        .bytes = @intCast(integerField(obj, "bytes") orelse 0),
        .sha256 = if (stringField(obj, "sha256")) |hash| try allocator.dupe(u8, hash) else null,
    };
}

fn revertFilePreview(allocator: std.mem.Allocator, context: app_context.EditingContext, record_file: HistoryFileRecord) !RevertFile {
    var snapshot = try readSnapshot(allocator, context, record_file.file);
    defer snapshot.deinit(allocator);
    var current_identity = try session_domain.identityFromBytes(allocator, snapshot.exists, snapshot.bytes);
    errdefer current_identity.deinit(allocator);
    const current_matches = snapshot.exists and record_file.updated_identity.matches(current_identity);

    var preimage_result: ?ports.WorkspaceReadResult = null;
    const preimage_bytes = if (record_file.preimage_identity.exists and record_file.preimage_content_path != null) blk: {
        const result = try context.workspace_store.read(allocator, .{
            .path = record_file.preimage_content_path.?,
            .max_bytes = max_session_file_bytes,
            .provenance = "patch_session_revert_preimage",
        });
        preimage_result = result;
        break :blk result.bytes;
    } else "";
    defer if (preimage_result) |result| result.deinit(allocator);

    const diff = try session_domain.unifiedDiff(allocator, snapshot.file, snapshot.bytes, preimage_bytes);
    errdefer allocator.free(diff);
    return .{
        .file = try allocator.dupe(u8, snapshot.file),
        .safe_to_revert = current_matches,
        .current_matches_session_output = current_matches,
        .current_identity = current_identity,
        .target_preimage_identity = try record_file.preimage_identity.clone(allocator),
        .preimage_content_path = if (record_file.preimage_content_path) |path| try allocator.dupe(u8, path) else null,
        .would_delete = !record_file.preimage_identity.exists,
        .diff = diff,
    };
}

fn applyRevertFile(allocator: std.mem.Allocator, context: app_context.EditingContext, record_file: HistoryFileRecord) !void {
    if (!record_file.preimage_identity.exists) {
        _ = try context.workspace_store.delete(.{
            .path = record_file.file,
            .missing_ok = true,
            .provenance = "patch_session_revert_delete",
        });
        return;
    }
    const preimage_path = record_file.preimage_content_path orelse return error.InvalidArguments;
    const bytes = try context.workspace_store.read(allocator, .{
        .path = preimage_path,
        .max_bytes = max_session_file_bytes,
        .provenance = "patch_session_revert_preimage",
    });
    defer bytes.deinit(allocator);
    _ = try context.workspace_store.write(.{
        .path = record_file.file,
        .bytes = bytes.bytes,
        .provenance = "patch_session_revert",
    });
}

fn recordJsonLine(allocator: std.mem.Allocator, record: SessionRecord) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        "{{\"kind\":\"zigar_patch_session_record\",\"schema_version\":{d},\"session_id\":",
        .{schema_version},
    );
    try writeJsonString(&out, record.session_id);
    try out.writer.writeAll(",\"goal\":");
    if (record.goal) |goal| {
        try writeJsonString(&out, goal);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.print(",\"recorded_unix_ms\":{d},\"files\":[", .{record.recorded_unix_ms});
    for (record.files, 0..) |file, index| {
        if (index > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"file\":");
        try writeJsonString(&out, file.file);
        try out.writer.writeAll(",\"preimage_identity\":");
        try writeIdentityJson(&out, file.preimage_identity);
        try out.writer.writeAll(",\"updated_identity\":");
        try writeIdentityJson(&out, file.updated_identity);
        try out.writer.writeAll(",\"preimage_content_path\":");
        if (file.preimage_content_path) |path| {
            try writeJsonString(&out, path);
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}");
    return try out.toOwnedSlice();
}

fn writeIdentityJson(out: *std.Io.Writer.Allocating, identity: Identity) !void {
    try out.writer.print("{{\"exists\":{},\"bytes\":{d},\"sha256\":", .{ identity.exists, identity.bytes });
    if (identity.sha256) |hash| {
        try writeJsonString(out, hash);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll("}");
}

fn writeJsonString(out: *std.Io.Writer.Allocating, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, &out.writer);
}

fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, field: []const u8) ?bool {
    return switch (obj.get(field) orelse .null) {
        .bool => |b| b,
        else => null,
    };
}

fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (obj.get(field) orelse .null) {
        .integer => |value| value,
        else => null,
    };
}
