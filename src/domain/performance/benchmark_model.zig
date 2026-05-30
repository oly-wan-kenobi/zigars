//! Benchmark evidence model: parsing, comparison, and budget evaluation.
//! All timing values are in nanoseconds per iteration. Callers own allocations
//! returned by parse and compare functions; deinit frees them.

const std = @import("std");

/// One normalized benchmark timing sample in nanoseconds per iteration.
pub const BenchSample = struct {
    name: []const u8,
    ns_per_iter: f64,
};

/// Owned benchmark sample collection parsed from text or JSON evidence.
pub const BenchSet = struct {
    samples: std.ArrayList(BenchSample) = .empty,
    source_kind: []const u8 = "content",

    /// Frees owned sample names and backing storage.
    pub fn deinit(self: *BenchSet, allocator: std.mem.Allocator) void {
        for (self.samples.items) |sample| allocator.free(sample.name);
        self.samples.deinit(allocator);
    }
};

/// One matched benchmark delta with an owned sample name.
pub const BenchDelta = struct {
    name: []const u8,
    baseline_ns_per_iter: f64,
    current_ns_per_iter: f64,
    delta_pct: f64,
};

/// Owned comparison result split into regressions and improvements.
pub const BenchComparison = struct {
    threshold_pct: i64,
    compared_count: usize,
    regressions: std.ArrayList(BenchDelta) = .empty,
    improvements: std.ArrayList(BenchDelta) = .empty,
    worst_regression_pct: f64 = 0,

    /// Frees owned delta names and backing lists.
    pub fn deinit(self: *BenchComparison, allocator: std.mem.Allocator) void {
        freeDeltas(allocator, self.regressions.items);
        self.regressions.deinit(allocator);
        freeDeltas(allocator, self.improvements.items);
        self.improvements.deinit(allocator);
    }

    /// Reports whether no regression exceeded the configured threshold.
    pub fn passed(self: BenchComparison) bool {
        return self.regressions.items.len == 0;
    }
};

/// Compact comparison summary accepted from prior JSON artifacts.
pub const CompareSummary = struct {
    regression_count: usize,
    worst_regression_pct: f64,
};

/// Parses benchmark evidence, auto-detecting JSON versus timing text.
pub fn parseEvidence(allocator: std.mem.Allocator, bytes: []const u8, source_kind: []const u8) !BenchSet {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidBenchmarkEvidence;
    if (trimmed[0] == '{' or trimmed[0] == '[') return parseJson(allocator, trimmed, source_kind);
    return parseText(allocator, trimmed);
}

/// Parses stdout-style timing lines into an owned benchmark set.
pub fn parseText(allocator: std.mem.Allocator, bytes: []const u8) !BenchSet {
    var set = BenchSet{ .source_kind = "stdout" };
    errdefer set.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (parseTimingLine(line)) |timing| {
            const name = try allocator.dupe(u8, timing.name);
            errdefer allocator.free(name);
            try set.samples.append(allocator, .{ .name = name, .ns_per_iter = timing.ns_per_iter });
        }
    }
    if (set.samples.items.len == 0) return error.InvalidBenchmarkEvidence;
    return set;
}

/// Compares current samples against matching baseline names.
/// Only samples whose name appears in both sets are counted; unmatched ones are
/// silently skipped. Samples with a zero or negative baseline are also skipped
/// to avoid division-by-zero and meaningless infinite-regression percentages.
/// threshold_pct is a signed integer; both regressions (positive) and
/// improvements (negative) use the same magnitude threshold.
pub fn compare(allocator: std.mem.Allocator, current: BenchSet, baseline: BenchSet, threshold_pct: i64) !BenchComparison {
    var out = BenchComparison{ .threshold_pct = threshold_pct, .compared_count = 0 };
    errdefer out.deinit(allocator);
    for (current.samples.items) |sample| {
        const before = findSample(baseline, sample.name) orelse continue;
        out.compared_count += 1;
        // Skip zero/negative baselines: delta percentage is undefined.
        if (before.ns_per_iter <= 0) continue;
        const pct = ((sample.ns_per_iter - before.ns_per_iter) / before.ns_per_iter) * 100.0;
        if (pct > @as(f64, @floatFromInt(threshold_pct))) {
            const item = try delta(allocator, sample.name, before.ns_per_iter, sample.ns_per_iter, pct);
            errdefer allocator.free(item.name);
            try out.regressions.append(allocator, item);
            out.worst_regression_pct = @max(out.worst_regression_pct, pct);
        } else if (pct < -@as(f64, @floatFromInt(threshold_pct))) {
            const item = try delta(allocator, sample.name, before.ns_per_iter, sample.ns_per_iter, pct);
            errdefer allocator.free(item.name);
            try out.improvements.append(allocator, item);
        }
    }
    return out;
}

/// Reads a compact regression summary from JSON report evidence.
/// Accepts two JSON shapes: a scalar regression_count field, or a regressions
/// array whose length is counted. Negative counts are clamped to zero.
/// Returns error.InvalidBenchmarkEvidence when the root is not a JSON object.
pub fn compareSummaryFromJson(allocator: std.mem.Allocator, bytes: []const u8) !CompareSummary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidBenchmarkEvidence;
    const count: usize = if (parsed.value.object.get("regression_count")) |value| @intCast(@max(0, switch (value) {
        .integer => |i| i,
        else => 0,
    })) else if (parsed.value.object.get("regressions")) |regressions| jsonArrayLength(regressions) else 0;
    const worst = if (parsed.value.object.get("worst_regression_pct")) |value| switch (value) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => 0,
    } else worstRegressionFromArray(parsed.value.object.get("regressions"));
    return .{ .regression_count = count, .worst_regression_pct = worst };
}

/// Evaluates a summary against an allowed worst-regression budget.
/// Returns true when there are no regressions, or when the worst regression
/// stays within max_regression_pct. Both conditions allow a non-zero count
/// paired with a small magnitude to pass CI gating.
pub fn budgetPassed(summary: CompareSummary, max_regression_pct: f64) bool {
    return summary.regression_count == 0 or summary.worst_regression_pct <= max_regression_pct;
}

/// Finds a sample by exact name without allocating.
pub fn findSample(set: BenchSet, name: []const u8) ?BenchSample {
    for (set.samples.items) |sample| if (std.mem.eql(u8, sample.name, name)) return sample;
    return null;
}

/// Parses JSON evidence into owned model data; invalid shape and allocation failures are returned.
fn parseJson(allocator: std.mem.Allocator, bytes: []const u8, source_kind: []const u8) !BenchSet {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = benchRoot(parsed.value);
    var set = BenchSet{ .source_kind = source_kind };
    errdefer set.deinit(allocator);
    if (root != .array) return error.InvalidBenchmarkEvidence;
    for (root.array.items) |item| {
        if (item != .object) continue;
        const name = stringField(item.object, "name") orelse stringField(item.object, "benchmark") orelse continue;
        const ns = floatField(item.object, "ns_per_iter") orelse floatField(item.object, "time_ns") orelse floatField(item.object, "mean_ns") orelse continue;
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try set.samples.append(allocator, .{ .name = owned_name, .ns_per_iter = ns });
    }
    if (set.samples.items.len == 0) return error.InvalidBenchmarkEvidence;
    return set;
}

/// Selects the benchmark array root from known JSON evidence shapes.
/// Handles {"benchmarks":[...]}, {"results":{...}}, and {"baseline":{...}}
/// wrappers by recursing until a non-object or an unrecognized key is found.
fn benchRoot(value: std.json.Value) std.json.Value {
    if (value == .object) {
        if (value.object.get("benchmarks")) |benchmarks| return benchmarks;
        if (value.object.get("results")) |results| return benchRoot(results);
        if (value.object.get("baseline")) |baseline| return benchRoot(baseline);
    }
    return value;
}

/// Borrowed benchmark timing parsed from one text output line.
const Timing = struct { name: []const u8, ns_per_iter: f64 };

/// Parses a text benchmark timing line into borrowed name and numeric timing fields.
/// Uses the last numeric token on the line as the timing value, so the benchmark
/// name may contain digits (e.g. "test_16kb: 4.5 ns" extracts 4.5).
/// Scales the value to nanoseconds based on the unit suffix that follows it.
/// Returns null for lines with no recognizable unit or an empty name.
fn parseTimingLine(line: []const u8) ?Timing {
    var last_number_start: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if ((line[i] >= '0' and line[i] <= '9') or line[i] == '.') {
            const start = i;
            while (i < line.len and ((line[i] >= '0' and line[i] <= '9') or line[i] == '.')) i += 1;
            last_number_start = start;
        }
    }
    const start = last_number_start orelse return null;
    var end = start;
    while (end < line.len and ((line[end] >= '0' and line[end] <= '9') or line[end] == '.')) end += 1;
    const value = std.fmt.parseFloat(f64, line[start..end]) catch return null;
    const unit = std.mem.trim(u8, line[end..], " \t:/");
    // Scale multipliers convert the unit suffix to nanoseconds.
    const scale: f64 = if (std.mem.startsWith(u8, unit, "ns"))
        1.0
    else if (std.mem.startsWith(u8, unit, "us") or std.mem.startsWith(u8, unit, "micro"))
        1000.0
    else if (std.mem.startsWith(u8, unit, "ms"))
        1_000_000.0
    else if (std.mem.startsWith(u8, unit, "s"))
        1_000_000_000.0
    else
        return null;
    const name = std.mem.trim(u8, line[0..start], " \t:-");
    if (name.len == 0) return null;
    return .{ .name = name, .ns_per_iter = value * scale };
}

/// Builds an owned benchmark delta, duplicating the benchmark name.
fn delta(allocator: std.mem.Allocator, name: []const u8, baseline_ns: f64, current_ns: f64, pct: f64) !BenchDelta {
    return .{
        .name = try allocator.dupe(u8, name),
        .baseline_ns_per_iter = baseline_ns,
        .current_ns_per_iter = current_ns,
        .delta_pct = pct,
    };
}

/// Frees owned benchmark delta names inside a delta slice.
fn freeDeltas(allocator: std.mem.Allocator, deltas: []BenchDelta) void {
    for (deltas) |item| allocator.free(item.name);
}

/// Returns the array length for JSON arrays and zero for other shapes.
fn jsonArrayLength(value: std.json.Value) usize {
    return switch (value) {
        .array => |array| array.items.len,
        else => 0,
    };
}

/// Extracts the worst regression percentage from a JSON delta array.
fn worstRegressionFromArray(value: ?std.json.Value) f64 {
    const regressions = value orelse return 0;
    if (regressions != .array) return 0;
    var worst: f64 = 0;
    for (regressions.array.items) |item| {
        if (item == .object) {
            const pct = floatField(item.object, "delta_pct") orelse 0;
            worst = @max(worst, pct);
        }
    }
    return worst;
}

/// Reads a numeric field from a JSON object as f64 when possible.
fn floatField(obj: std.json.ObjectMap, name: []const u8) ?f64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Reads a string field from a JSON object without taking ownership.
fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

test "benchmark float field accepts JSON number strings" {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(std.testing.allocator);

    try obj.put(std.testing.allocator, "mean_ns", .{ .number_string = "2.5" });
    try std.testing.expectEqual(@as(f64, 2.5), floatField(obj, "mean_ns").?);
}
