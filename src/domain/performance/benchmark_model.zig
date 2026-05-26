const std = @import("std");

pub const BenchSample = struct {
    name: []const u8,
    ns_per_iter: f64,
};

pub const BenchSet = struct {
    samples: std.ArrayList(BenchSample) = .empty,
    source_kind: []const u8 = "content",

    pub fn deinit(self: *BenchSet, allocator: std.mem.Allocator) void {
        for (self.samples.items) |sample| allocator.free(sample.name);
        self.samples.deinit(allocator);
    }
};

pub const BenchDelta = struct {
    name: []const u8,
    baseline_ns_per_iter: f64,
    current_ns_per_iter: f64,
    delta_pct: f64,
};

pub const BenchComparison = struct {
    threshold_pct: i64,
    compared_count: usize,
    regressions: std.ArrayList(BenchDelta) = .empty,
    improvements: std.ArrayList(BenchDelta) = .empty,
    worst_regression_pct: f64 = 0,

    pub fn deinit(self: *BenchComparison, allocator: std.mem.Allocator) void {
        freeDeltas(allocator, self.regressions.items);
        self.regressions.deinit(allocator);
        freeDeltas(allocator, self.improvements.items);
        self.improvements.deinit(allocator);
    }

    pub fn passed(self: BenchComparison) bool {
        return self.regressions.items.len == 0;
    }
};

pub const CompareSummary = struct {
    regression_count: usize,
    worst_regression_pct: f64,
};

pub fn parseEvidence(allocator: std.mem.Allocator, bytes: []const u8, source_kind: []const u8) !BenchSet {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidBenchmarkEvidence;
    if (trimmed[0] == '{' or trimmed[0] == '[') return parseJson(allocator, trimmed, source_kind);
    return parseText(allocator, trimmed);
}

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

pub fn compare(allocator: std.mem.Allocator, current: BenchSet, baseline: BenchSet, threshold_pct: i64) !BenchComparison {
    var out = BenchComparison{ .threshold_pct = threshold_pct, .compared_count = 0 };
    errdefer out.deinit(allocator);
    for (current.samples.items) |sample| {
        const before = findSample(baseline, sample.name) orelse continue;
        out.compared_count += 1;
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

pub fn budgetPassed(summary: CompareSummary, max_regression_pct: f64) bool {
    return summary.regression_count == 0 or summary.worst_regression_pct <= max_regression_pct;
}

pub fn findSample(set: BenchSet, name: []const u8) ?BenchSample {
    for (set.samples.items) |sample| if (std.mem.eql(u8, sample.name, name)) return sample;
    return null;
}

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

fn benchRoot(value: std.json.Value) std.json.Value {
    if (value == .object) {
        if (value.object.get("benchmarks")) |benchmarks| return benchmarks;
        if (value.object.get("results")) |results| return benchRoot(results);
        if (value.object.get("baseline")) |baseline| return benchRoot(baseline);
    }
    return value;
}

const Timing = struct { name: []const u8, ns_per_iter: f64 };

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

fn delta(allocator: std.mem.Allocator, name: []const u8, baseline_ns: f64, current_ns: f64, pct: f64) !BenchDelta {
    return .{
        .name = try allocator.dupe(u8, name),
        .baseline_ns_per_iter = baseline_ns,
        .current_ns_per_iter = current_ns,
        .delta_pct = pct,
    };
}

fn freeDeltas(allocator: std.mem.Allocator, deltas: []BenchDelta) void {
    for (deltas) |item| allocator.free(item.name);
}

fn jsonArrayLength(value: std.json.Value) usize {
    return switch (value) {
        .array => |array| array.items.len,
        else => 0,
    };
}

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

fn floatField(obj: std.json.ObjectMap, name: []const u8) ?f64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

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
