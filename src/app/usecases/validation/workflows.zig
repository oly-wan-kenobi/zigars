//! Validation workflow state and history tracking around command/tool execution phases.
const std = @import("std");

const app_context = @import("../../context.zig");
const app_errors = @import("../../errors.zig");
const ports = @import("../../ports.zig");

pub const schema_version: i64 = 1;
pub const history_path_default = ".zigar-cache/validation/history.jsonl";
pub const history_max_bytes: usize = 8 * 1024 * 1024;
pub const command_output_limit: usize = 1024 * 1024;
const command_output_limit_mode = "truncate_on_limit";

pub const PhaseKind = enum {
    tool_only,
    command,

    pub fn name(self: PhaseKind) []const u8 {
        return switch (self) {
            .tool_only => "tool_only",
            .command => "command",
        };
    }
};

pub const OwnedStringList = struct {
    items: []const []const u8,

    pub fn deinit(self: *OwnedStringList, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const OwnedArgv = struct {
    items: []const []const u8,

    pub fn deinit(self: *OwnedArgv, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const Phase = struct {
    id: []const u8,
    kind: PhaseKind,
    tool: ?[]const u8 = null,
    argv: ?OwnedArgv = null,
    reason: []const u8,
    required: bool,
    risk: []const u8,

    pub fn deinit(self: *Phase, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.tool) |tool| allocator.free(tool);
        if (self.argv) |*argv| argv.deinit(allocator);
        allocator.free(self.reason);
        allocator.free(self.risk);
        self.* = undefined;
    }
};

pub const SkippedPhase = struct {
    name: []const u8,
    reason: []const u8,

    pub fn deinit(self: *SkippedPhase, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const Risk = struct {
    changed_file_count: usize,
    touches_zig_source: bool,
    touches_build_config: bool,
    touches_docs: bool,
    level: []const u8,
};

pub const PlanRequest = struct {
    mode: []const u8 = "standard",
    goal: ?[]const u8 = null,
    changed_paths: []const []const u8 = &.{},
    include_semantic: bool = true,
};

pub const PlanResult = struct {
    schema_version: i64 = 1,
    plan_id: []const u8,
    mode: []const u8,
    goal: ?[]const u8,
    facts: OwnedStringList,
    risk: Risk,
    phases: []Phase,
    skipped_phases: []SkippedPhase,
    unknowns: OwnedStringList,

    pub fn deinit(self: *PlanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.plan_id);
        allocator.free(self.mode);
        if (self.goal) |goal| allocator.free(goal);
        self.facts.deinit(allocator);
        for (self.phases) |*phase| phase.deinit(allocator);
        allocator.free(self.phases);
        for (self.skipped_phases) |*skipped| skipped.deinit(allocator);
        allocator.free(self.skipped_phases);
        self.unknowns.deinit(allocator);
        self.* = undefined;
    }
};

pub const RunRequest = struct {
    plan: PlanRequest,
    output: []const u8 = history_path_default,
    apply: bool = false,
    stop_on_failure: bool = false,
    timeout_ms: ?u64 = null,
};

pub const CommandOutcome = union(enum) {
    result: CommandResult,
    port_error: ports.PortError,
};

pub const CommandResult = struct {
    exit_code: i32,
    term: ports.CommandTerm,
    stdout: []const u8,
    stderr: []const u8,
    duration_ms: u64,
    timed_out: bool,
    stdout_truncated: bool,
    stderr_truncated: bool,

    pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const PhaseRun = struct {
    name: []const u8,
    ok: bool,
    argv: OwnedArgv,
    cwd: []const u8,
    timeout_ms: i64,
    outcome: CommandOutcome,

    pub fn deinit(self: *PhaseRun, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.argv.deinit(allocator);
        allocator.free(self.cwd);
        switch (self.outcome) {
            .result => |*result| result.deinit(allocator),
            .port_error => {},
        }
        self.* = undefined;
    }
};

pub const Preimage = struct {
    exists: bool,
    bytes: usize,
    sha256: ?[]const u8 = null,

    pub fn deinit(self: *Preimage, allocator: std.mem.Allocator) void {
        if (self.sha256) |hash| allocator.free(hash);
        self.* = undefined;
    }
};

pub const HistoryRecord = struct {
    recorded_unix_ms: i64,
    ok: bool,
    plan_id: []const u8,
    phase_count: usize,
    skipped_count: usize,
    failures: []FailureRecord,
    slow_phases: []SlowPhase,

    pub fn deinit(self: *HistoryRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.plan_id);
        for (self.failures) |*failure| failure.deinit(allocator);
        allocator.free(self.failures);
        for (self.slow_phases) |*slow| slow.deinit(allocator);
        allocator.free(self.slow_phases);
        self.* = undefined;
    }
};

pub const FailureRecord = struct {
    phase: []const u8,
    fingerprint: []const u8,

    pub fn deinit(self: *FailureRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.phase);
        allocator.free(self.fingerprint);
        self.* = undefined;
    }
};

pub const SlowPhase = struct {
    phase: []const u8,
    duration_ms: i64,

    pub fn deinit(self: *SlowPhase, allocator: std.mem.Allocator) void {
        allocator.free(self.phase);
        self.* = undefined;
    }
};

pub const RunReport = struct {
    schema_version: i64 = 1,
    ok: bool,
    plan: PlanResult,
    phases: []PhaseRun,
    skipped_phases: []SkippedPhase,
    history_record: HistoryRecord,
    history_path: []const u8,
    history_applied: bool,
    requires_apply_for_history: bool,
    preimage_identity: Preimage,

    pub fn deinit(self: *RunReport, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
        for (self.phases) |*phase| phase.deinit(allocator);
        allocator.free(self.phases);
        for (self.skipped_phases) |*skipped| skipped.deinit(allocator);
        allocator.free(self.skipped_phases);
        self.history_record.deinit(allocator);
        allocator.free(self.history_path);
        self.preimage_identity.deinit(allocator);
        self.* = undefined;
    }
};

pub const WorkspaceFailure = struct {
    error_info: app_errors.AppError,
    err: ports.PortError,
    path: []const u8,
};

pub const RunFailure = union(enum) {
    history_write_failed: WorkspaceFailure,
};

pub const RunOutcome = union(enum) {
    ok: RunReport,
    err: RunFailure,

    pub fn deinit(self: *RunOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*report| report.deinit(allocator),
            .err => {},
        }
        self.* = undefined;
    }
};

pub const HistoryView = enum {
    runs,
    flakes,
    failures,
};

pub const HistoryRequest = struct {
    view: HistoryView,
    history_text: ?[]const u8 = null,
    path: []const u8 = history_path_default,
    limit: usize = 50,
};

pub const HistoryRun = struct {
    raw_json: []const u8,
    ok: bool,
    failures: []HistoryFailure,

    pub fn deinit(self: *HistoryRun, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_json);
        for (self.failures) |*failure| failure.deinit(allocator);
        allocator.free(self.failures);
        self.* = undefined;
    }
};

pub const HistoryFailure = struct {
    fingerprint: []const u8,
    sample_json: []const u8,

    pub fn deinit(self: *HistoryFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
        allocator.free(self.sample_json);
        self.* = undefined;
    }
};

pub const FailureGroup = struct {
    fingerprint: []const u8,
    count: usize,
    sample_json: []const u8,

    pub fn deinit(self: *FailureGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
        allocator.free(self.sample_json);
        self.* = undefined;
    }
};

pub const HistoryResult = struct {
    schema_version: i64 = 1,
    view: HistoryView,
    history_available: bool,
    runs: []HistoryRun,
    last_run_index: ?usize = null,
    last_good_index: ?usize = null,
    failure_groups: []FailureGroup,

    pub fn deinit(self: *HistoryResult, allocator: std.mem.Allocator) void {
        for (self.runs) |*run_item| run_item.deinit(allocator);
        allocator.free(self.runs);
        for (self.failure_groups) |*group| group.deinit(allocator);
        allocator.free(self.failure_groups);
        self.* = undefined;
    }
};

pub const HistoryFailureResult = struct {
    error_info: app_errors.AppError,
    err: ports.PortError,
    path: []const u8,
};

pub const HistoryOutcome = union(enum) {
    ok: HistoryResult,
    err: HistoryFailureResult,

    pub fn deinit(self: *HistoryOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*result| result.deinit(allocator),
            .err => {},
        }
        self.* = undefined;
    }
};

pub fn plan(allocator: std.mem.Allocator, context: app_context.ValidationContext, request: PlanRequest) !PlanResult {
    var facts = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringItems(allocator, facts.items);
        facts.deinit(allocator);
    }
    var phases = std.ArrayList(Phase).empty;
    errdefer {
        for (phases.items) |*item| item.deinit(allocator);
        phases.deinit(allocator);
    }
    var skipped = std.ArrayList(SkippedPhase).empty;
    errdefer {
        for (skipped.items) |*item| item.deinit(allocator);
        skipped.deinit(allocator);
    }
    var unknowns = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringItems(allocator, unknowns.items);
        unknowns.deinit(allocator);
    }

    var saw_zig = false;
    var saw_build = false;
    var saw_docs = false;
    for (request.changed_paths) |path| {
        if (std.mem.endsWith(u8, path, ".zig")) saw_zig = true;
        if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) saw_build = true;
        if (std.mem.endsWith(u8, path, ".md")) saw_docs = true;
        try appendOwnedString(allocator, &facts, path);
    }

    if (request.include_semantic) try appendPhase(allocator, &phases, .{
        .id = "semantic_impact",
        .kind = .tool_only,
        .tool = "zig_impact_semantic",
        .reason = "Map touched files and symbols to importers, declarations, tests, and public API.",
        .required = true,
        .risk = "none",
    });
    if (request.changed_paths.len > 0) try appendPhase(allocator, &phases, .{
        .id = "patch_guard",
        .kind = .tool_only,
        .tool = "zigar_patch_guard",
        .reason = "Check workspace boundaries and generated-path policy before validating edits.",
        .required = true,
        .risk = "none",
    });
    if (saw_zig) {
        for (request.changed_paths) |path| {
            if (!std.mem.endsWith(u8, path, ".zig")) continue;
            if (!workspacePathExists(allocator, context, path)) continue;
            try appendPhase(allocator, &phases, .{
                .id = "format_check",
                .kind = .command,
                .argv = &.{ context.tool_paths.zig, "fmt", "--check", path },
                .reason = "Touched Zig source requires formatting verification.",
                .required = true,
                .risk = "project_code",
            });
            try appendPhase(allocator, &phases, .{
                .id = "ast_check",
                .kind = .command,
                .argv = &.{ context.tool_paths.zig, "ast-check", path },
                .reason = "Touched Zig source requires compiler syntax validation.",
                .required = true,
                .risk = "project_code",
            });
        }
        try appendPhase(allocator, &phases, .{
            .id = "semantic_test_select",
            .kind = .tool_only,
            .tool = "zig_test_select_semantic",
            .reason = "Select focused tests from semantic index evidence.",
            .required = true,
            .risk = "none",
        });
    } else {
        try appendSkipped(allocator, &skipped, "source_file_checks", "No changed Zig source files were supplied.");
    }
    if (!std.mem.eql(u8, request.mode, "quick") or saw_build or request.changed_paths.len == 0) {
        try appendPhase(allocator, &phases, .{
            .id = "build_test",
            .kind = .command,
            .argv = &.{ context.tool_paths.zig, "build", "test" },
            .reason = if (saw_build) "Build configuration changed." else "Standard/full validation includes the project build test gate.",
            .required = true,
            .risk = "project_code",
        });
    } else {
        try appendSkipped(allocator, &skipped, "build_test", "quick mode skipped the project build test; do not treat this as pass evidence.");
    }
    if (saw_docs) try appendPhase(allocator, &phases, .{
        .id = "docs_check",
        .kind = .command,
        .argv = &.{ context.tool_paths.zig, "build", "docs-check" },
        .reason = "Product documentation changed.",
        .required = true,
        .risk = "project_code",
    });
    if (request.changed_paths.len == 0) try appendOwnedString(allocator, &unknowns, "No changed_files or diff were supplied; plan uses workspace-level fallback checks.");

    const facts_items = try facts.toOwnedSlice(allocator);
    errdefer {
        freeStringItems(allocator, facts_items);
        allocator.free(facts_items);
    }
    const phase_items = try phases.toOwnedSlice(allocator);
    errdefer {
        for (phase_items) |*phase| phase.deinit(allocator);
        allocator.free(phase_items);
    }
    const skipped_items = try skipped.toOwnedSlice(allocator);
    errdefer {
        for (skipped_items) |*item| item.deinit(allocator);
        allocator.free(skipped_items);
    }
    const unknown_items = try unknowns.toOwnedSlice(allocator);
    errdefer {
        freeStringItems(allocator, unknown_items);
        allocator.free(unknown_items);
    }
    const mode = try allocator.dupe(u8, request.mode);
    errdefer allocator.free(mode);
    const goal = if (request.goal) |goal_value| try allocator.dupe(u8, goal_value) else null;
    errdefer if (goal) |goal_value| allocator.free(goal_value);
    const plan_id = try planId(allocator, request.changed_paths, request.mode);

    return .{
        .plan_id = plan_id,
        .mode = mode,
        .goal = goal,
        .facts = .{ .items = facts_items },
        .risk = .{
            .changed_file_count = request.changed_paths.len,
            .touches_zig_source = saw_zig,
            .touches_build_config = saw_build,
            .touches_docs = saw_docs,
            .level = if (saw_build) "high" else if (saw_zig) "medium" else "low",
        },
        .phases = phase_items,
        .skipped_phases = skipped_items,
        .unknowns = .{ .items = unknown_items },
    };
}

pub fn run(allocator: std.mem.Allocator, context: app_context.ValidationContext, request: RunRequest) !RunOutcome {
    var planned = try plan(allocator, context, request.plan);
    errdefer planned.deinit(allocator);

    var phases = std.ArrayList(PhaseRun).empty;
    errdefer {
        for (phases.items) |*item| item.deinit(allocator);
        phases.deinit(allocator);
    }
    var skipped = std.ArrayList(SkippedPhase).empty;
    errdefer {
        for (skipped.items) |*item| item.deinit(allocator);
        skipped.deinit(allocator);
    }

    var ok = true;
    var executed_count: usize = 0;
    const timeout_ms = request.timeout_ms orelse normalizedTimeout(context.timeouts.command_ms);
    for (planned.phases) |phase_item| {
        if (phase_item.kind == .tool_only) {
            try appendSkipped(allocator, &skipped, phase_item.id, "Validation runner executes command phases only; call the named tool separately for read-only evidence.");
            continue;
        }
        const argv = phase_item.argv.?.items;
        executed_count += 1;
        var phase_run = try runPhase(allocator, context, phase_item.id, argv, timeout_ms);
        errdefer phase_run.deinit(allocator);
        if (!phase_run.ok) ok = false;
        try phases.append(allocator, phase_run);
        if (!phase_run.ok and request.stop_on_failure) break;
    }
    if (executed_count == 0) {
        try appendSkipped(allocator, &skipped, "commands", "No command phases were selected by the validation plan.");
    }

    const instant = try context.clock_and_ids.now();
    var history_record = try buildHistoryRecord(allocator, instant.unix_ms, planned.plan_id, ok, phases.items, skipped.items);
    errdefer history_record.deinit(allocator);
    var preimage = try preimageForPath(allocator, context, request.output);
    errdefer preimage.deinit(allocator);

    if (request.apply) {
        const line = try historyLineForRun(allocator, history_record, phases.items, skipped.items);
        defer allocator.free(line);
        const existing = existingHistoryBytes(allocator, context, request.output);
        defer if (existing) |bytes| allocator.free(bytes);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        if (existing) |old| {
            try bytes.appendSlice(allocator, old);
            if (old.len > 0 and old[old.len - 1] != '\n') try bytes.append(allocator, '\n');
        }
        try bytes.appendSlice(allocator, line);
        try bytes.append(allocator, '\n');
        _ = context.workspace_store.write(.{
            .path = request.output,
            .bytes = bytes.items,
            .create_parent_dirs = true,
            .replace_existing = true,
            .provenance = "zigar_validation_run history",
        }) catch |err| {
            const failure = WorkspaceFailure{
                .error_info = app_errors.toolFailure(
                    "validation_workflow",
                    "write_history",
                    "validation_history_write_failed",
                    @errorName(err),
                    "Choose a writable validation history path inside the workspace or run with apply=false.",
                ),
                .err = err,
                .path = request.output,
            };
            preimage.deinit(allocator);
            history_record.deinit(allocator);
            for (phases.items) |*item| item.deinit(allocator);
            phases.deinit(allocator);
            for (skipped.items) |*item| item.deinit(allocator);
            skipped.deinit(allocator);
            planned.deinit(allocator);
            return .{ .err = .{ .history_write_failed = failure } };
        };
    }

    const phase_runs = try phases.toOwnedSlice(allocator);
    errdefer {
        for (phase_runs) |*phase| phase.deinit(allocator);
        allocator.free(phase_runs);
    }
    const skipped_runs = try skipped.toOwnedSlice(allocator);
    errdefer {
        for (skipped_runs) |*item| item.deinit(allocator);
        allocator.free(skipped_runs);
    }
    const history_path = try allocator.dupe(u8, request.output);
    errdefer allocator.free(history_path);

    return .{ .ok = .{
        .ok = ok,
        .plan = planned,
        .phases = phase_runs,
        .skipped_phases = skipped_runs,
        .history_record = history_record,
        .history_path = history_path,
        .history_applied = request.apply,
        .requires_apply_for_history = !request.apply,
        .preimage_identity = preimage,
    } };
}

pub fn history(allocator: std.mem.Allocator, context: app_context.ValidationContext, request: HistoryRequest) !HistoryOutcome {
    const limit = @max(@as(usize, 1), request.limit);
    var text: ?[]const u8 = request.history_text;
    var owned_text: ?[]const u8 = null;
    defer if (owned_text) |bytes| allocator.free(bytes);

    var unavailable = false;
    if (text == null) {
        const read_result = context.workspace_store.read(allocator, .{
            .path = request.path,
            .max_bytes = history_max_bytes,
            .provenance = "zigar_validation_history read",
        }) catch |err| {
            switch (err) {
                error.FileNotFound, error.NotFound => {
                    unavailable = true;
                    text = "";
                },
                else => return .{ .err = .{
                    .error_info = app_errors.toolFailure(
                        "validation_workflow",
                        "read_history",
                        "validation_history_read_failed",
                        @errorName(err),
                        "Pass inline history records or choose a readable validation history path.",
                    ),
                    .err = err,
                    .path = request.path,
                } },
            }
            return .{ .ok = .{
                .view = request.view,
                .history_available = !unavailable,
                .runs = try allocator.alloc(HistoryRun, 0),
                .last_run_index = null,
                .last_good_index = null,
                .failure_groups = try allocator.alloc(FailureGroup, 0),
            } };
        };
        if (read_result.owns_bytes) {
            owned_text = read_result.bytes;
            text = read_result.bytes;
        } else {
            owned_text = try allocator.dupe(u8, read_result.bytes);
            text = owned_text;
        }
    }

    const runs = try parseHistoryRuns(allocator, text orelse "", limit);
    errdefer deinitHistoryRuns(allocator, runs);
    const groups = try buildFailureGroups(allocator, runs);
    errdefer deinitFailureGroups(allocator, groups);
    return .{ .ok = .{
        .view = request.view,
        .history_available = !unavailable,
        .runs = runs,
        .last_run_index = if (runs.len == 0) null else runs.len - 1,
        .last_good_index = lastGoodIndex(runs),
        .failure_groups = groups,
    } };
}

const PhaseSpec = struct {
    id: []const u8,
    kind: PhaseKind,
    tool: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
    reason: []const u8,
    required: bool,
    risk: []const u8,
};

fn appendPhase(allocator: std.mem.Allocator, phases: *std.ArrayList(Phase), spec: PhaseSpec) !void {
    const id = try allocator.dupe(u8, spec.id);
    errdefer allocator.free(id);
    const tool = if (spec.tool) |tool_value| try allocator.dupe(u8, tool_value) else null;
    errdefer if (tool) |tool_value| allocator.free(tool_value);
    var argv = if (spec.argv) |argv_value| try cloneArgv(allocator, argv_value) else null;
    errdefer if (argv) |*argv_value| argv_value.deinit(allocator);
    const reason = try allocator.dupe(u8, spec.reason);
    errdefer allocator.free(reason);
    const risk = try allocator.dupe(u8, spec.risk);
    errdefer allocator.free(risk);

    const phase_item = Phase{
        .id = id,
        .kind = spec.kind,
        .tool = tool,
        .argv = argv,
        .reason = reason,
        .required = spec.required,
        .risk = risk,
    };
    try phases.append(allocator, phase_item);
}

fn appendSkipped(allocator: std.mem.Allocator, skipped: *std.ArrayList(SkippedPhase), name: []const u8, reason: []const u8) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_reason = try allocator.dupe(u8, reason);
    errdefer allocator.free(owned_reason);
    const item = SkippedPhase{
        .name = owned_name,
        .reason = owned_reason,
    };
    try skipped.append(allocator, item);
}

fn appendOwnedString(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try values.append(allocator, owned);
}

fn runPhase(allocator: std.mem.Allocator, context: app_context.ValidationContext, name: []const u8, argv: []const []const u8, timeout_ms: u64) !PhaseRun {
    var owned_argv = try cloneArgv(allocator, argv);
    errdefer owned_argv.deinit(allocator);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const cwd = try allocator.dupe(u8, context.workspace.root);
    errdefer allocator.free(cwd);

    var result = context.command_runner.run(allocator, .{
        .argv = argv,
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .max_stdout_bytes = command_output_limit,
        .max_stderr_bytes = command_output_limit,
        .provenance = "zigar_validation_run phase",
    }) catch |err| return .{
        .name = owned_name,
        .ok = false,
        .argv = owned_argv,
        .cwd = cwd,
        .timeout_ms = saturatingI64(timeout_ms),
        .outcome = .{ .port_error = err },
    };
    defer result.deinit(allocator);

    const stdout = try allocator.dupe(u8, result.stdout);
    errdefer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, result.stderr);
    errdefer allocator.free(stderr);
    const term = result.effectiveTerm();
    return .{
        .name = owned_name,
        .ok = !term.failed() and !result.timed_out,
        .argv = owned_argv,
        .cwd = cwd,
        .timeout_ms = saturatingI64(timeout_ms),
        .outcome = .{ .result = .{
            .exit_code = result.exit_code,
            .term = term,
            .stdout = stdout,
            .stderr = stderr,
            .duration_ms = result.duration_ms,
            .timed_out = result.timed_out,
            .stdout_truncated = result.stdout_truncated,
            .stderr_truncated = result.stderr_truncated,
        } },
    };
}

fn buildHistoryRecord(
    allocator: std.mem.Allocator,
    recorded_unix_ms: i64,
    plan_id_value: []const u8,
    ok: bool,
    phases: []const PhaseRun,
    skipped: []const SkippedPhase,
) !HistoryRecord {
    var failures = std.ArrayList(FailureRecord).empty;
    errdefer {
        for (failures.items) |*failure| failure.deinit(allocator);
        failures.deinit(allocator);
    }
    var slow = std.ArrayList(SlowPhase).empty;
    errdefer {
        for (slow.items) |*slow_item| slow_item.deinit(allocator);
        slow.deinit(allocator);
    }
    for (phases) |phase_item| {
        if (!phase_item.ok) {
            const phase = try allocator.dupe(u8, phase_item.name);
            errdefer allocator.free(phase);
            const fingerprint = try std.fmt.allocPrint(allocator, "phase:{s}", .{phase_item.name});
            errdefer allocator.free(fingerprint);
            const failure = FailureRecord{
                .phase = phase,
                .fingerprint = fingerprint,
            };
            try failures.append(allocator, failure);
        }
        const duration_ms = phaseDurationMs(phase_item);
        if (duration_ms > 1000) {
            const phase = try allocator.dupe(u8, phase_item.name);
            errdefer allocator.free(phase);
            const item = SlowPhase{
                .phase = phase,
                .duration_ms = duration_ms,
            };
            try slow.append(allocator, item);
        }
    }
    const failure_items = try failures.toOwnedSlice(allocator);
    errdefer deinitFailureRecords(allocator, failure_items);
    const slow_items = try slow.toOwnedSlice(allocator);
    errdefer deinitSlowPhases(allocator, slow_items);
    const owned_plan_id = try allocator.dupe(u8, plan_id_value);
    errdefer allocator.free(owned_plan_id);
    return .{
        .recorded_unix_ms = recorded_unix_ms,
        .ok = ok,
        .plan_id = owned_plan_id,
        .phase_count = phases.len,
        .skipped_count = skipped.len,
        .failures = failure_items,
        .slow_phases = slow_items,
    };
}

fn preimageForPath(allocator: std.mem.Allocator, context: app_context.ValidationContext, path: []const u8) !Preimage {
    const read_result = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = history_max_bytes,
        .provenance = "zigar_validation_run history preimage",
    }) catch return .{ .exists = false, .bytes = 0, .sha256 = null };
    defer read_result.deinit(allocator);
    return .{
        .exists = true,
        .bytes = read_result.bytes.len,
        .sha256 = try sha256Hex(allocator, read_result.bytes),
    };
}

fn existingHistoryBytes(allocator: std.mem.Allocator, context: app_context.ValidationContext, path: []const u8) ?[]const u8 {
    const read_result = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = history_max_bytes,
        .provenance = "zigar_validation_run history append",
    }) catch return null;
    if (!read_result.owns_bytes) return allocator.dupe(u8, read_result.bytes) catch null;
    return read_result.bytes;
}

fn workspacePathExists(allocator: std.mem.Allocator, context: app_context.ValidationContext, path: []const u8) bool {
    const result = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = 0,
        .provenance = "zigar_validation_plan path probe",
    }) catch return false;
    result.deinit(allocator);
    return true;
}

fn parseHistoryRuns(allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]HistoryRun {
    var out = std.ArrayList(HistoryRun).empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return out.toOwnedSlice(allocator);
    if (trimmed[0] == '[') {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
        defer parsed.deinit();
        const array = switch (parsed.value) {
            .array => |items| items,
            else => return out.toOwnedSlice(allocator),
        };
        for (array.items) |item| {
            if (out.items.len >= limit) break;
            var run_item = try historyRunFromValue(allocator, item);
            errdefer run_item.deinit(allocator);
            try out.append(allocator, run_item);
        }
        return out.toOwnedSlice(allocator);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (out.items.len >= limit) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        var run_item = try historyRunFromValue(allocator, parsed.value);
        errdefer run_item.deinit(allocator);
        allocator.free(run_item.raw_json);
        run_item.raw_json = try allocator.dupe(u8, line);
        try out.append(allocator, run_item);
    }
    return out.toOwnedSlice(allocator);
}

fn historyRunFromValue(allocator: std.mem.Allocator, value: std.json.Value) !HistoryRun {
    const raw_json = try serializeJsonValueAlloc(allocator, value);
    errdefer allocator.free(raw_json);
    const obj = switch (value) {
        .object => |object| object,
        else => return .{
            .raw_json = raw_json,
            .ok = false,
            .failures = try allocator.alloc(HistoryFailure, 0),
        },
    };
    const failures_value = obj.get("failures") orelse .null;
    const failures_array = switch (failures_value) {
        .array => |array| array,
        else => std.json.Array.init(allocator),
    };
    var failures = std.ArrayList(HistoryFailure).empty;
    errdefer {
        for (failures.items) |*failure| failure.deinit(allocator);
        failures.deinit(allocator);
    }
    for (failures_array.items) |failure_value| {
        const failure_obj = switch (failure_value) {
            .object => |failure_object| failure_object,
            else => continue,
        };
        const fingerprint = stringField(failure_obj, "fingerprint") orelse stringField(failure_obj, "phase") orelse "unknown";
        const owned_fingerprint = try allocator.dupe(u8, fingerprint);
        errdefer allocator.free(owned_fingerprint);
        const sample_json = try serializeJsonValueAlloc(allocator, failure_value);
        errdefer allocator.free(sample_json);
        const item = HistoryFailure{
            .fingerprint = owned_fingerprint,
            .sample_json = sample_json,
        };
        try failures.append(allocator, item);
    }
    return .{
        .raw_json = raw_json,
        .ok = boolField(obj, "ok") orelse false,
        .failures = try failures.toOwnedSlice(allocator),
    };
}

fn buildFailureGroups(allocator: std.mem.Allocator, runs: []const HistoryRun) ![]FailureGroup {
    var groups = std.ArrayList(FailureGroup).empty;
    errdefer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }
    for (runs) |run_item| {
        for (run_item.failures) |failure| {
            var found = false;
            for (groups.items) |*group| {
                if (!std.mem.eql(u8, group.fingerprint, failure.fingerprint)) continue;
                group.count += 1;
                found = true;
                break;
            }
            if (found) continue;
            const fingerprint = try allocator.dupe(u8, failure.fingerprint);
            errdefer allocator.free(fingerprint);
            const sample_json = try allocator.dupe(u8, failure.sample_json);
            errdefer allocator.free(sample_json);
            const group = FailureGroup{
                .fingerprint = fingerprint,
                .count = 1,
                .sample_json = sample_json,
            };
            try groups.append(allocator, group);
        }
    }
    return groups.toOwnedSlice(allocator);
}

fn historyLineForRun(allocator: std.mem.Allocator, record: HistoryRecord, phases: []const PhaseRun, skipped: []const SkippedPhase) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    try jsonFieldInt(allocator, &out, "schema_version", schema_version, true);
    try jsonFieldInt(allocator, &out, "recorded_unix_ms", record.recorded_unix_ms, false);
    try jsonFieldBool(allocator, &out, "ok", record.ok, false);
    try jsonFieldString(allocator, &out, "plan_id", record.plan_id, false);
    try jsonFieldInt(allocator, &out, "phase_count", @intCast(record.phase_count), false);
    try jsonFieldInt(allocator, &out, "skipped_count", @intCast(record.skipped_count), false);
    try out.appendSlice(allocator, ",\"failures\":[");
    for (record.failures, 0..) |failure, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.append(allocator, '{');
        try jsonFieldString(allocator, &out, "phase", failure.phase, true);
        try jsonFieldString(allocator, &out, "fingerprint", failure.fingerprint, false);
        if (phaseByName(phases, failure.phase)) |phase_item| {
            try out.append(allocator, ',');
            try serializeJsonString(allocator, &out, "command");
            try out.append(allocator, ':');
            try writeCommandObject(allocator, &out, phase_item);
        }
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"slow_phases\":[");
    for (record.slow_phases, 0..) |slow, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.append(allocator, '{');
        try jsonFieldString(allocator, &out, "phase", slow.phase, true);
        try jsonFieldInt(allocator, &out, "duration_ms", slow.duration_ms, false);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"phases\":[");
    for (phases, 0..) |*phase_item, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.append(allocator, '{');
        try jsonFieldString(allocator, &out, "name", phase_item.name, true);
        try jsonFieldBool(allocator, &out, "ok", phase_item.ok, false);
        try out.append(allocator, ',');
        try serializeJsonString(allocator, &out, "command");
        try out.append(allocator, ':');
        try writeCommandObject(allocator, &out, phase_item);
        try out.append(allocator, ',');
        try serializeJsonString(allocator, &out, "events");
        try out.append(allocator, ':');
        try writeEventsObject(allocator, &out, phase_item);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"skipped_phases\":[");
    for (skipped, 0..) |skipped_item, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.append(allocator, '{');
        try jsonFieldString(allocator, &out, "name", skipped_item.name, true);
        try jsonFieldString(allocator, &out, "reason", skipped_item.reason, false);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn writeCommandObject(allocator: std.mem.Allocator, out: *std.ArrayList(u8), phase_item: *const PhaseRun) !void {
    try out.append(allocator, '{');
    switch (phase_item.outcome) {
        .result => |result| {
            try jsonFieldString(allocator, out, "kind", "command", true);
            try jsonFieldString(allocator, out, "title", phase_item.name, false);
            try jsonFieldBool(allocator, out, "ok", phase_item.ok, false);
            try jsonFieldString(allocator, out, "cwd", phase_item.cwd, false);
            try jsonFieldStringArray(allocator, out, "argv", phase_item.argv.items, false);
            try jsonFieldInt(allocator, out, "timeout_ms", phase_item.timeout_ms, false);
            try jsonFieldInt(allocator, out, "duration_ms", @intCast(result.duration_ms), false);
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "term");
            try out.append(allocator, ':');
            try writeCommandTerm(allocator, out, result.term);
            try jsonStreamFields(allocator, out, "stdout", result.stdout, false);
            try jsonStreamFields(allocator, out, "stderr", result.stderr, false);
            try jsonFieldBool(allocator, out, "stdout_truncated", result.stdout_truncated, false);
            try jsonFieldBool(allocator, out, "stderr_truncated", result.stderr_truncated, false);
            try jsonFieldInt(allocator, out, "stdout_limit", @intCast(command_output_limit), false);
            try jsonFieldInt(allocator, out, "stderr_limit", @intCast(command_output_limit), false);
            try jsonFieldString(allocator, out, "output_limit_mode", command_output_limit_mode, false);
            try jsonFieldBool(allocator, out, "output_limit_exceeded", result.stdout_truncated or result.stderr_truncated, false);
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "failure_summary");
            try out.appendSlice(allocator, ":{");
            try jsonFieldBool(allocator, out, "ok", phase_item.ok, true);
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "primary");
            try out.appendSlice(allocator, ":null");
            try jsonFieldString(allocator, out, "error_class", if (phase_item.ok) "none" else "workspace_or_build", false);
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "rerun_command");
            try out.append(allocator, ':');
            try writeCommandString(allocator, out, phase_item.argv.items);
            try jsonFieldStringArray(allocator, out, "suggested_tools", if (phase_item.ok) &.{} else &.{ "zigar_failure_fusion", "zigar_impact" }, false);
            try jsonFieldString(allocator, out, "likely_scope", if (phase_item.ok) "none" else "workspace_or_build", false);
            try out.append(allocator, '}');
        },
        .port_error => |err| {
            const error_kind = commandErrorKind(err);
            try jsonFieldString(allocator, out, "kind", "command_error", true);
            try jsonFieldString(allocator, out, "title", phase_item.name, false);
            try jsonFieldBool(allocator, out, "ok", false, false);
            try jsonFieldString(allocator, out, "cwd", phase_item.cwd, false);
            try jsonFieldStringArray(allocator, out, "argv", phase_item.argv.items, false);
            try jsonFieldInt(allocator, out, "timeout_ms", phase_item.timeout_ms, false);
            try jsonFieldString(allocator, out, "error", @errorName(err), false);
            try jsonFieldString(allocator, out, "error_kind", error_kind, false);
            try jsonFieldInt(allocator, out, "stdout_limit", @intCast(command_output_limit), false);
            try jsonFieldInt(allocator, out, "stderr_limit", @intCast(command_output_limit), false);
            try jsonFieldString(allocator, out, "output_limit_mode", command_output_limit_mode, false);
            try jsonFieldBool(allocator, out, "output_limit_exceeded", isOutputLimitError(err), false);
            try jsonFieldBool(allocator, out, "stdout_truncated", false, false);
            try jsonFieldBool(allocator, out, "stderr_truncated", false, false);
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "failure_summary");
            try out.appendSlice(allocator, ":{");
            try jsonFieldBool(allocator, out, "ok", false, true);
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "primary");
            try out.appendSlice(allocator, ":null");
            try jsonFieldString(allocator, out, "error_class", error_kind, false);
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "rerun_command");
            try out.append(allocator, ':');
            try writeCommandString(allocator, out, phase_item.argv.items);
            try jsonFieldStringArray(allocator, out, "suggested_tools", &.{ "zigar_doctor", "zigar_context_pack" }, false);
            try jsonFieldString(allocator, out, "likely_scope", if (isTimeoutError(err)) "command_timeout" else "tool_or_backend_configuration", false);
            try out.append(allocator, '}');
        },
    }
    try out.append(allocator, '}');
}

fn writeEventsObject(allocator: std.mem.Allocator, out: *std.ArrayList(u8), phase_item: *const PhaseRun) !void {
    try out.append(allocator, '{');
    try jsonFieldString(allocator, out, "kind", "validation_phase", true);
    try jsonFieldInt(allocator, out, "schema_version", schema_version, false);
    try jsonFieldBool(allocator, out, "ok", phase_item.ok, false);
    switch (phase_item.outcome) {
        .result => |result| {
            try jsonFieldStringArray(allocator, out, "argv", phase_item.argv.items, false);
            try jsonFieldString(allocator, out, "parsing_basis", "executed_command", false);
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "events");
            try out.append(allocator, ':');
            var counts = EventCounts{};
            try writeLineEventsArray(allocator, out, result.stderr, result.stdout, &counts);
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "compiler");
            try out.append(allocator, ':');
            try writeCompilerSummary(allocator, out, counts);
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "tests");
            try out.append(allocator, ':');
            try writeTestSummary(allocator, out, counts);
            try out.appendSlice(allocator, ",\"timings\":[]");
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "summary");
            try out.appendSlice(allocator, ":{");
            try jsonFieldInt(allocator, out, "event_count", counts.event_count, true);
            try jsonFieldInt(allocator, out, "compiler_error_count", counts.compiler_error_count, false);
            try jsonFieldInt(allocator, out, "test_failure_count", counts.test_failure_count, false);
            try jsonFieldInt(allocator, out, "timing_count", 0, false);
            try out.append(allocator, '}');
            try jsonFieldString(allocator, out, "confidence", "high", false);
            try jsonFieldString(allocator, out, "limitations", "Event parsing is best-effort over Zig stdout/stderr; raw command output remains the audit source.", false);
        },
        .port_error => |err| {
            try out.append(allocator, ',');
            try serializeJsonString(allocator, out, "command");
            try out.append(allocator, ':');
            try writeCommandObject(allocator, out, phase_item);
            try out.appendSlice(allocator, ",\"events\":[]");
            try jsonFieldString(allocator, out, "error_kind", commandErrorKind(err), false);
            try jsonFieldString(allocator, out, "resolution", "Confirm the configured Zig executable and workspace command can run, or pass captured output as text.", false);
        },
    }
    try out.append(allocator, '}');
}

fn writeCommandTerm(allocator: std.mem.Allocator, out: *std.ArrayList(u8), term: ports.CommandTerm) !void {
    try out.append(allocator, '{');
    try jsonFieldString(allocator, out, "kind", term.name(), true);
    if (term.exitCode()) |code| try jsonFieldInt(allocator, out, "code", code, false);
    try out.append(allocator, '}');
}

fn writeCommandString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), argv: []const []const u8) !void {
    var command = std.ArrayList(u8).empty;
    defer command.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try command.append(allocator, ' ');
        try command.appendSlice(allocator, arg);
    }
    try serializeJsonString(allocator, out, command.items);
}

fn jsonFieldStringArray(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, values: []const []const u8, first: bool) !void {
    if (!first) try out.append(allocator, ',');
    try serializeJsonString(allocator, out, key);
    try out.append(allocator, ':');
    try out.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index > 0) try out.append(allocator, ',');
        try serializeJsonString(allocator, out, value);
    }
    try out.append(allocator, ']');
}

fn jsonStreamFields(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, bytes: []const u8, first: bool) !void {
    var safe = try safeTextAlloc(allocator, bytes);
    defer safe.deinit(allocator);
    try jsonFieldString(allocator, out, name, safe.text, first);
    try out.append(allocator, ',');
    try writeStreamKey(allocator, out, name, "invalid_utf8");
    try out.appendSlice(allocator, if (safe.invalid_utf8) "true" else "false");
    try out.append(allocator, ',');
    try writeStreamKey(allocator, out, name, "encoding");
    try serializeJsonString(allocator, out, safe.encoding);
    try out.append(allocator, ',');
    try writeStreamKey(allocator, out, name, "byte_count");
    try out.print(allocator, "{d}", .{safe.byte_count});
}

fn writeStreamKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, suffix: []const u8) !void {
    try out.append(allocator, '"');
    try out.appendSlice(allocator, name);
    try out.append(allocator, '_');
    try out.appendSlice(allocator, suffix);
    try out.appendSlice(allocator, "\":");
}

const SafeText = struct {
    text: []const u8,
    invalid_utf8: bool,
    encoding: []const u8,
    byte_count: usize,

    fn deinit(self: *SafeText, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

fn safeTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) !SafeText {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return .{
            .text = try allocator.dupe(u8, bytes),
            .invalid_utf8 = false,
            .encoding = "utf-8",
            .byte_count = bytes.len,
        };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
            continue;
        };
        if (index + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[index .. index + len])) {
            try out.appendSlice(allocator, bytes[index .. index + len]);
            index += len;
        } else {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
        }
    }
    return .{
        .text = try out.toOwnedSlice(allocator),
        .invalid_utf8 = true,
        .encoding = "utf-8-lossy",
        .byte_count = bytes.len,
    };
}

const EventCounts = struct {
    event_count: i64 = 0,
    compiler_error_count: i64 = 0,
    compiler_warning_count: i64 = 0,
    test_failure_count: i64 = 0,
};

fn writeLineEventsArray(allocator: std.mem.Allocator, out: *std.ArrayList(u8), stderr: []const u8, stdout: []const u8, counts: *EventCounts) !void {
    try out.append(allocator, '[');
    var first = true;
    try writeLineEvents(allocator, out, stderr, "stderr", &first, counts);
    try writeLineEvents(allocator, out, stdout, "stdout", &first, counts);
    try out.append(allocator, ']');
}

fn writeLineEvents(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, stream: []const u8, first: *bool, counts: *EventCounts) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 1;
    while (lines.next()) |raw| : (line_no += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const event_type = classifyEventLine(line);
        if (std.mem.eql(u8, event_type, "output")) continue;
        if (!first.*) try out.append(allocator, ',');
        first.* = false;
        try out.append(allocator, '{');
        try jsonFieldInt(allocator, out, "line", @intCast(line_no), true);
        try jsonFieldString(allocator, out, "stream", stream, false);
        try jsonFieldString(allocator, out, "event", event_type, false);
        try jsonFieldString(allocator, out, "message", line, false);
        try out.append(allocator, '}');
        counts.event_count += 1;
        if (std.mem.eql(u8, event_type, "compiler_error")) counts.compiler_error_count += 1;
        if (std.mem.eql(u8, event_type, "compiler_warning")) counts.compiler_warning_count += 1;
        if (std.mem.eql(u8, event_type, "test_failure")) counts.test_failure_count += 1;
    }
}

fn writeCompilerSummary(allocator: std.mem.Allocator, out: *std.ArrayList(u8), counts: EventCounts) !void {
    try out.append(allocator, '{');
    try jsonFieldInt(allocator, out, "finding_count", counts.compiler_error_count + counts.compiler_warning_count, true);
    try jsonFieldInt(allocator, out, "error_count", counts.compiler_error_count, false);
    try jsonFieldInt(allocator, out, "warning_count", counts.compiler_warning_count, false);
    try jsonFieldInt(allocator, out, "note_count", 0, false);
    try out.appendSlice(allocator, ",\"findings\":[]");
    try out.appendSlice(allocator, ",\"primary\":null");
    try jsonFieldString(allocator, out, "category", if (counts.compiler_error_count > 0) "compile_error" else "none", false);
    try out.appendSlice(allocator, ",\"next_command\":null,\"next_actions\":[]");
    try out.append(allocator, '}');
}

fn writeTestSummary(allocator: std.mem.Allocator, out: *std.ArrayList(u8), counts: EventCounts) !void {
    try out.append(allocator, '{');
    try jsonFieldInt(allocator, out, "failure_count", counts.test_failure_count, true);
    try out.appendSlice(allocator, ",\"failures\":[]");
    try out.append(allocator, '}');
}

fn classifyEventLine(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, ": error: ") != null or std.mem.startsWith(u8, line, "error: ")) return "compiler_error";
    if (std.mem.indexOf(u8, line, ": warning: ") != null or std.mem.startsWith(u8, line, "warning: ")) return "compiler_warning";
    if (std.mem.indexOf(u8, line, "FAIL") != null or std.mem.indexOf(u8, line, "failed") != null) return "test_failure";
    if (std.mem.indexOf(u8, line, "PASS") != null or std.mem.indexOf(u8, line, "passed") != null) return "test_pass";
    if (std.mem.indexOf(u8, line, "Step ") != null) return "build_step";
    return "output";
}

fn commandErrorKind(err: ports.PortError) []const u8 {
    return switch (err) {
        error.Timeout, error.RequestTimeout => "timeout",
        error.StreamTooLong, error.OutputLimitExceeded => "output_limit",
        error.FileNotFound, error.NotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        else => "execution",
    };
}

fn isOutputLimitError(err: ports.PortError) bool {
    return err == error.StreamTooLong or err == error.OutputLimitExceeded;
}

fn isTimeoutError(err: ports.PortError) bool {
    return err == error.Timeout or err == error.RequestTimeout;
}

fn jsonFieldString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try out.append(allocator, ',');
    try serializeJsonString(allocator, out, key);
    try out.append(allocator, ':');
    try serializeJsonString(allocator, out, value);
}

fn jsonFieldBool(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: bool, first: bool) !void {
    if (!first) try out.append(allocator, ',');
    try serializeJsonString(allocator, out, key);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, if (value) "true" else "false");
}

fn jsonFieldInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: i64, first: bool) !void {
    if (!first) try out.append(allocator, ',');
    try serializeJsonString(allocator, out, key);
    try out.append(allocator, ':');
    try out.print(allocator, "{d}", .{value});
}

fn serializeJsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try serializeJsonValue(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

fn serializeJsonValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| try out.print(allocator, "{d}", .{i}),
        .float => |f| try out.print(allocator, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try serializeJsonString(allocator, out, s),
        .array => |array| {
            try out.append(allocator, '[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try out.append(allocator, ',');
                try serializeJsonValue(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |object| {
            try out.append(allocator, '{');
            var it = object.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.append(allocator, ',');
                first = false;
                try serializeJsonString(allocator, out, entry.key_ptr.*);
                try out.append(allocator, ':');
                try serializeJsonValue(allocator, out, entry.value_ptr.*);
            }
            try out.append(allocator, '}');
        },
    }
}

fn serializeJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try out.appendSlice(allocator, "\\u00");
                try out.append(allocator, hex[c >> 4]);
                try out.append(allocator, hex[c & 0x0f]);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

fn phaseDurationMs(phase_item: PhaseRun) i64 {
    return switch (phase_item.outcome) {
        .result => |result| @intCast(result.duration_ms),
        .port_error => 0,
    };
}

fn phaseByName(phases: []const PhaseRun, name: []const u8) ?*const PhaseRun {
    for (phases) |*phase_item| {
        if (std.mem.eql(u8, phase_item.name, name)) return phase_item;
    }
    return null;
}

fn lastGoodIndex(runs: []const HistoryRun) ?usize {
    var out: ?usize = null;
    for (runs, 0..) |run_item, index| {
        if (run_item.ok) out = index;
    }
    return out;
}

fn normalizedTimeout(timeout_ms: i64) u64 {
    if (timeout_ms <= 0) return 1;
    return @intCast(timeout_ms);
}

fn saturatingI64(value: u64) i64 {
    const max_i64: u64 = @intCast(std.math.maxInt(i64));
    if (value > max_i64) return std.math.maxInt(i64);
    return @intCast(value);
}

fn cloneArgv(allocator: std.mem.Allocator, argv: []const []const u8) !OwnedArgv {
    const items = try allocator.alloc([]const u8, argv.len);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |item| allocator.free(item);
        allocator.free(items);
    }
    for (argv, 0..) |arg, index| {
        items[index] = try allocator.dupe(u8, arg);
        filled += 1;
    }
    return .{ .items = items };
}

fn freeStringList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn deinitFailureRecords(allocator: std.mem.Allocator, items: []FailureRecord) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitSlowPhases(allocator: std.mem.Allocator, items: []SlowPhase) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitHistoryRuns(allocator: std.mem.Allocator, items: []HistoryRun) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitFailureGroups(allocator: std.mem.Allocator, items: []FailureGroup) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn freeStringItems(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
}

fn boolField(obj: std.json.ObjectMap, field: []const u8) ?bool {
    return switch (obj.get(field) orelse .null) {
        .bool => |b| b,
        else => null,
    };
}

fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

fn planId(allocator: std.mem.Allocator, files: []const []const u8, mode: []const u8) ![]const u8 {
    var hasher = std.hash.Wyhash.init(4);
    hasher.update(mode);
    for (files) |file| hasher.update(file);
    return std.fmt.allocPrint(allocator, "validation-{x}", .{hasher.final()});
}

fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

test "validation workflow private classifiers serializers and cleanup helpers cover edge cases" {
    const allocator = std.testing.allocator;

    const invalid_single = [_]u8{ 0xff, 'x' };
    var lossy_single = try safeTextAlloc(allocator, invalid_single[0..]);
    defer lossy_single.deinit(allocator);
    try std.testing.expect(lossy_single.invalid_utf8);
    try std.testing.expectEqualStrings("utf-8-lossy", lossy_single.encoding);

    const invalid_truncated = [_]u8{ 0xe2, 0x82 };
    var lossy_truncated = try safeTextAlloc(allocator, invalid_truncated[0..]);
    defer lossy_truncated.deinit(allocator);
    try std.testing.expect(lossy_truncated.invalid_utf8);
    try std.testing.expect(std.mem.indexOf(u8, lossy_truncated.text, &std.unicode.replacement_character_utf8) != null);

    try std.testing.expectEqualStrings("compiler_error", classifyEventLine("error: root cause"));
    try std.testing.expectEqualStrings("compiler_warning", classifyEventLine("src/main.zig:2:1: warning: style"));
    try std.testing.expectEqualStrings("test_failure", classifyEventLine("FAIL test.case"));
    try std.testing.expectEqualStrings("test_pass", classifyEventLine("passed 12 tests"));
    try std.testing.expectEqualStrings("build_step", classifyEventLine("Step 1/2"));
    try std.testing.expectEqualStrings("output", classifyEventLine("plain output"));

    try std.testing.expectEqualStrings("timeout", commandErrorKind(error.RequestTimeout));
    try std.testing.expectEqualStrings("output_limit", commandErrorKind(error.OutputLimitExceeded));
    try std.testing.expectEqualStrings("executable_not_found", commandErrorKind(error.NotFound));
    try std.testing.expectEqualStrings("permission", commandErrorKind(error.AccessDenied));
    try std.testing.expectEqualStrings("execution", commandErrorKind(error.UnexpectedCall));
    try std.testing.expect(isOutputLimitError(error.StreamTooLong));
    try std.testing.expect(isTimeoutError(error.Timeout));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), saturatingI64(std.math.maxInt(u64)));
    try std.testing.expect(phaseByName(&.{}, "missing") == null);

    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);
    try serializeJsonString(allocator, &escaped, "\"\\\n\r\t\x08\x0c\x01");
    try std.testing.expectEqualStrings("\"\\\"\\\\\\n\\r\\t\\b\\f\\u0001\"", escaped.items);

    const number_json = try serializeJsonValueAlloc(allocator, .{ .number_string = "1e3" });
    defer allocator.free(number_json);
    try std.testing.expectEqualStrings("1e3", number_json);

    const float_json = try serializeJsonValueAlloc(allocator, .{ .float = 1.25 });
    defer allocator.free(float_json);
    try std.testing.expect(std.mem.startsWith(u8, float_json, "1.25"));

    const null_json = try serializeJsonValueAlloc(allocator, .null);
    defer allocator.free(null_json);
    try std.testing.expectEqualStrings("null", null_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":[null,true,1,\"x\"]}", .{});
    defer parsed.deinit();
    const object_json = try serializeJsonValueAlloc(allocator, parsed.value);
    defer allocator.free(object_json);
    try std.testing.expect(std.mem.indexOf(u8, object_json, "\"a\"") != null);

    var failure_records = try allocator.alloc(FailureRecord, 1);
    failure_records[0] = .{
        .phase = try allocator.dupe(u8, "fmt"),
        .fingerprint = try allocator.dupe(u8, "phase:fmt"),
    };
    deinitFailureRecords(allocator, failure_records);

    var slow_phases = try allocator.alloc(SlowPhase, 1);
    slow_phases[0] = .{
        .phase = try allocator.dupe(u8, "build"),
        .duration_ms = 1200,
    };
    deinitSlowPhases(allocator, slow_phases);

    var history_failures = try allocator.alloc(HistoryFailure, 1);
    history_failures[0] = .{
        .fingerprint = try allocator.dupe(u8, "fingerprint"),
        .sample_json = try allocator.dupe(u8, "{}"),
    };
    var history_runs = try allocator.alloc(HistoryRun, 1);
    history_runs[0] = .{
        .raw_json = try allocator.dupe(u8, "{}"),
        .ok = false,
        .failures = history_failures,
    };
    deinitHistoryRuns(allocator, history_runs);

    var groups = try allocator.alloc(FailureGroup, 1);
    groups[0] = .{
        .fingerprint = try allocator.dupe(u8, "group"),
        .count = 1,
        .sample_json = try allocator.dupe(u8, "{}"),
    };
    deinitFailureGroups(allocator, groups);

    const strings = try allocator.alloc([]const u8, 2);
    strings[0] = try allocator.dupe(u8, "one");
    strings[1] = try allocator.dupe(u8, "two");
    freeStringItems(allocator, strings);
    allocator.free(strings);
}

test "validation workflow consumes owned workspace reads" {
    const fakes = @import("../../../testing/fakes/root.zig");
    const allocator = std.testing.allocator;

    var command = fakes.FakeCommandRunner.init(allocator);
    defer command.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(allocator);
    defer clock.deinit();
    const context = app_context.ValidationContext{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
        .tool_paths = .{ .zig = "zig" },
        .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
        .command_runner = command.port(),
        .workspace_store = workspace.port(),
        .clock_and_ids = clock.port(),
    };

    try workspace.expectRead(.{
        .path = "history.jsonl",
        .max_bytes = history_max_bytes,
        .provenance = "zigar_validation_history read",
    }, "{\"ok\":true,\"failures\":[]}\n");
    var from_file = try history(allocator, context, .{ .view = .runs, .path = "history.jsonl" });
    defer from_file.deinit(allocator);
    try std.testing.expect(from_file.ok.history_available);
    try std.testing.expectEqual(@as(?usize, 0), from_file.ok.last_good_index);

    try workspace.expectRead(.{
        .path = "history.jsonl",
        .max_bytes = history_max_bytes,
        .provenance = "zigar_validation_run history append",
    }, "old\n");
    const existing = existingHistoryBytes(allocator, context, "history.jsonl").?;
    defer allocator.free(existing);
    try std.testing.expectEqualStrings("old\n", existing);

    try workspace.verify();
    try command.verify();
    try clock.verify();
}

test "validation workflow cleans partial allocations across planning running and history helpers" {
    const fakes = @import("../../../testing/fakes/root.zig");
    var fail_index: usize = 0;
    while (fail_index < 192) : (fail_index += 1) {
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var command = fakes.FakeCommandRunner.init(std.testing.allocator);
            defer command.deinit();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
            defer clock.deinit();
            try workspace.expectRead(.{
                .path = "src/main.zig",
                .max_bytes = 0,
                .provenance = "zigar_validation_plan path probe",
            }, "");
            const context = app_context.ValidationContext{
                .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
                .tool_paths = .{ .zig = "zig" },
                .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
                .command_runner = command.port(),
                .workspace_store = workspace.port(),
                .clock_and_ids = clock.port(),
            };
            if (plan(allocator, context, .{
                .mode = "standard",
                .goal = "release",
                .changed_paths = &.{ "src/main.zig", "build.zig.zon", "README.md" },
                .include_semantic = true,
            })) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var command = fakes.FakeCommandRunner.init(std.testing.allocator);
            defer command.deinit();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
            defer clock.deinit();
            const context = app_context.ValidationContext{
                .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
                .tool_paths = .{ .zig = "zig" },
                .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
                .command_runner = command.port(),
                .workspace_store = workspace.port(),
                .clock_and_ids = clock.port(),
            };
            if (history(allocator, context, .{
                .view = .runs,
                .history_text = "{\"ok\":false,\"failures\":[{\"fingerprint\":\"fmt\"}]}\n",
            })) |outcome| {
                var owned = outcome;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var command = fakes.FakeCommandRunner.init(std.testing.allocator);
            defer command.deinit();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
            defer clock.deinit();
            try clock.pushInstant(.{ .unix_ms = 1_700_000_001_000, .monotonic_ms = 10 });
            try workspace.expectRead(.{
                .path = "src/main.zig",
                .max_bytes = 0,
                .provenance = "zigar_validation_plan path probe",
            }, "");
            try workspace.expectRead(.{
                .path = "history.jsonl",
                .max_bytes = history_max_bytes,
                .provenance = "zigar_validation_run history preimage",
            }, "old\n");
            try command.expectRun(.{
                .argv = &.{ "zig", "fmt", "--check", "src/main.zig" },
                .cwd = "/repo",
                .timeout_ms = 10,
                .max_stdout_bytes = command_output_limit,
                .max_stderr_bytes = command_output_limit,
                .provenance = "zigar_validation_run phase",
            }, .{ .stdout = "PASS fmt\n", .stderr = "", .duration_ms = 2 });
            try command.expectRun(.{
                .argv = &.{ "zig", "ast-check", "src/main.zig" },
                .cwd = "/repo",
                .timeout_ms = 10,
                .max_stdout_bytes = command_output_limit,
                .max_stderr_bytes = command_output_limit,
                .provenance = "zigar_validation_run phase",
            }, .{ .stdout = "", .stderr = "src/main.zig:1:1: warning: note\n", .duration_ms = 1201 });
            const context = app_context.ValidationContext{
                .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
                .tool_paths = .{ .zig = "zig" },
                .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
                .command_runner = command.port(),
                .workspace_store = workspace.port(),
                .clock_and_ids = clock.port(),
            };
            if (run(allocator, context, .{
                .plan = .{ .mode = "quick", .changed_paths = &.{"src/main.zig"}, .include_semantic = false },
                .output = "history.jsonl",
                .apply = false,
                .timeout_ms = 10,
            })) |outcome| {
                var owned = outcome;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var phases = std.ArrayList(Phase).empty;
            defer {
                for (phases.items) |*phase| phase.deinit(allocator);
                phases.deinit(allocator);
            }
            if (appendPhase(allocator, &phases, .{
                .id = "phase",
                .kind = .command,
                .tool = "tool",
                .argv = &.{ "zig", "build", "test" },
                .reason = "reason",
                .required = true,
                .risk = "risk",
            })) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var skipped = std.ArrayList(SkippedPhase).empty;
            defer {
                for (skipped.items) |*item| item.deinit(allocator);
                skipped.deinit(allocator);
            }
            if (appendSkipped(allocator, &skipped, "phase", "reason")) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var values = std.ArrayList([]const u8).empty;
            defer {
                freeStringItems(allocator, values.items);
                values.deinit(allocator);
            }
            if (appendOwnedString(allocator, &values, "value")) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var command = fakes.FakeCommandRunner.init(std.testing.allocator);
            defer command.deinit();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
            defer clock.deinit();
            try command.expectRun(.{
                .argv = &.{ "zig", "build", "test" },
                .cwd = "/repo",
                .timeout_ms = 5,
                .max_stdout_bytes = command_output_limit,
                .max_stderr_bytes = command_output_limit,
                .provenance = "zigar_validation_run phase",
            }, .{ .stdout = "PASS\n", .stderr = "warning: x\n", .duration_ms = 1500 });
            const context = app_context.ValidationContext{
                .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
                .tool_paths = .{ .zig = "zig" },
                .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
                .command_runner = command.port(),
                .workspace_store = workspace.port(),
                .clock_and_ids = clock.port(),
            };
            if (runPhase(allocator, context, "build_test", &.{ "zig", "build", "test" }, 5)) |phase_run| {
                var owned = phase_run;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        const sample_phase = PhaseRun{
            .name = "fmt",
            .ok = false,
            .argv = .{ .items = &.{ "zig", "fmt" } },
            .cwd = "/repo",
            .timeout_ms = 10,
            .outcome = .{ .result = .{
                .exit_code = 1,
                .term = .{ .exited = 1 },
                .stdout = "FAIL case\n",
                .stderr = "src/main.zig:1:1: error: bad\n",
                .duration_ms = 1501,
                .timed_out = false,
                .stdout_truncated = false,
                .stderr_truncated = false,
            } },
        };
        const skipped_phase = SkippedPhase{ .name = "tool", .reason = "skip" };

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (buildHistoryRecord(allocator, 1, "plan", false, &.{sample_phase}, &.{skipped_phase})) |record| {
                var owned = record;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (parseHistoryRuns(allocator, "[{\"ok\":false,\"failures\":[{\"fingerprint\":\"a\"}]},{\"ok\":true,\"failures\":[]}]", 4)) |runs| {
                deinitHistoryRuns(allocator, runs);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (parseHistoryRuns(allocator,
                \\{"ok":false,"failures":[{"phase":"fmt"}]}
                \\{"ok":true,"failures":[]}
                \\
            , 4)) |runs| {
                deinitHistoryRuns(allocator, runs);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            const failure = HistoryFailure{ .fingerprint = "fmt", .sample_json = "{\"phase\":\"fmt\"}" };
            var failures = [_]HistoryFailure{failure};
            const run_item = HistoryRun{ .raw_json = "{}", .ok = false, .failures = failures[0..] };
            if (buildFailureGroups(allocator, &.{run_item})) |groups| {
                deinitFailureGroups(allocator, groups);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            const failure = FailureRecord{ .phase = "fmt", .fingerprint = "phase:fmt" };
            const slow = SlowPhase{ .phase = "fmt", .duration_ms = 1501 };
            var failures = [_]FailureRecord{failure};
            var slow_phases = [_]SlowPhase{slow};
            const record = HistoryRecord{
                .recorded_unix_ms = 1,
                .ok = false,
                .plan_id = "plan",
                .phase_count = 1,
                .skipped_count = 1,
                .failures = failures[0..],
                .slow_phases = slow_phases[0..],
            };
            if (historyLineForRun(allocator, record, &.{sample_phase}, &.{skipped_phase})) |line| {
                allocator.free(line);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (safeTextAlloc(allocator, &.{ 0xff, 0xe2, 0x82, 'x' })) |safe| {
                var owned = safe;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (serializeJsonValueAlloc(allocator, .{ .string = "value" })) |json| {
                allocator.free(json);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            if (cloneArgv(allocator, &.{ "zig", "build", "test" })) |argv| {
                var owned = argv;
                owned.deinit(allocator);
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
