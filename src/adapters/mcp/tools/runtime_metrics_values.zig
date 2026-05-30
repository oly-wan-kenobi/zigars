//! Shared JSON value builders for runtime metrics projections.
const std = @import("std");

const ports = @import("../../../app/ports.zig");
const read_model = @import("../../../app/usecases/observability/workflows.zig");

/// Returns allocator-owned JSON for tool stats.
pub fn toolStatsValue(allocator: std.mem.Allocator, stats: []const ports.ObservabilityToolStats) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (stats) |stat| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "name", .{ .string = stat.name });
        try obj.put(allocator, "calls", .{ .integer = @intCast(stat.calls) });
        try obj.put(allocator, "errors", .{ .integer = @intCast(stat.errors) });
        try obj.put(allocator, "error_rate_per_1000", .{ .integer = @intCast(ratePerThousand(stat.errors, stat.calls)) });
        try obj.put(allocator, "avg_latency_ms", .{ .integer = @intCast(if (stat.calls == 0) 0 else stat.total_latency_ms / stat.calls) });
        try obj.put(allocator, "max_latency_ms", .{ .integer = @intCast(stat.max_latency_ms) });
        try obj.put(allocator, "last_latency_ms", .{ .integer = @intCast(stat.last_latency_ms) });
        try obj.put(allocator, "last_error", .{ .bool = stat.last_error });
        try obj.put(allocator, "latency_samples_retained", .{ .integer = @intCast(retainedSampleCount(stat.latency_sample_count)) });
        try obj.put(allocator, "latency_percentiles", try latencyPercentilesValue(allocator, stat.latency_samples, stat.latency_sample_count));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Returns allocator-owned JSON for MCP method stats.
pub fn methodStatsValue(allocator: std.mem.Allocator, stats: []const ports.ObservabilityMethodStats) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (stats) |*stat| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "name", .{ .string = stat.nameSlice() });
        try obj.put(allocator, "name_truncated", .{ .bool = stat.name_truncated });
        try obj.put(allocator, "calls", .{ .integer = @intCast(stat.calls) });
        try obj.put(allocator, "errors", .{ .integer = @intCast(stat.errors) });
        try obj.put(allocator, "error_rate_per_1000", .{ .integer = @intCast(ratePerThousand(stat.errors, stat.calls)) });
        try obj.put(allocator, "avg_latency_ms", .{ .integer = @intCast(if (stat.calls == 0) 0 else stat.total_latency_ms / stat.calls) });
        try obj.put(allocator, "max_latency_ms", .{ .integer = @intCast(stat.max_latency_ms) });
        try obj.put(allocator, "last_latency_ms", .{ .integer = @intCast(stat.last_latency_ms) });
        try obj.put(allocator, "last_error", .{ .bool = stat.last_error });
        try obj.put(allocator, "latency_samples_retained", .{ .integer = @intCast(retainedSampleCount(stat.latency_sample_count)) });
        try obj.put(allocator, "latency_percentiles", try latencyPercentilesValue(allocator, stat.latency_samples, stat.latency_sample_count));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Returns percentile fields from a bounded latency sample ring.
///
/// `sample_count` is the total samples ever seen; `samples` is the ring that
/// only retains the most recent `max_observability_latency_samples`. Percentiles
/// are withheld (status `insufficient_samples`, null p50/p95/p99) until enough
/// samples are retained, so a brand-new process never reports misleading tail
/// latencies from one or two data points.
pub fn latencyPercentilesValue(allocator: std.mem.Allocator, samples: [ports.max_observability_latency_samples]u64, sample_count: u64) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const retained = retainedSampleCount(sample_count);
    try obj.put(allocator, "sample_capacity", .{ .integer = read_model.max_latency_samples });
    try obj.put(allocator, "samples_seen", .{ .integer = @intCast(sample_count) });
    try obj.put(allocator, "samples_retained", .{ .integer = @intCast(retained) });
    try obj.put(allocator, "minimum_samples", .{ .integer = read_model.min_percentile_samples });
    if (retained < read_model.min_percentile_samples) {
        try obj.put(allocator, "enough_samples", .{ .bool = false });
        try obj.put(allocator, "p50_ms", .null);
        try obj.put(allocator, "p95_ms", .null);
        try obj.put(allocator, "p99_ms", .null);
        try obj.put(allocator, "status", .{ .string = "insufficient_samples" });
        return .{ .object = obj };
    }

    // Replay only the still-retained sequence numbers back through the ring to
    // recover their slots, then sort that copy; the ring itself stays untouched
    // so concurrent counter updates are not disturbed by this read.
    var retained_samples: [ports.max_observability_latency_samples]u64 = undefined;
    const first = firstSampleSequence(sample_count);
    var sequence = first;
    var index: usize = 0;
    while (sequence <= sample_count) : (sequence += 1) {
        retained_samples[index] = samples[ringIndex(sequence, ports.max_observability_latency_samples)];
        index += 1;
    }
    std.mem.sort(u64, retained_samples[0..retained], {}, std.sort.asc(u64));

    try obj.put(allocator, "enough_samples", .{ .bool = true });
    try obj.put(allocator, "p50_ms", .{ .integer = @intCast(percentile(retained_samples[0..retained], 50)) });
    try obj.put(allocator, "p95_ms", .{ .integer = @intCast(percentile(retained_samples[0..retained], 95)) });
    try obj.put(allocator, "p99_ms", .{ .integer = @intCast(percentile(retained_samples[0..retained], 99)) });
    try obj.put(allocator, "status", .{ .string = "ok" });
    return .{ .object = obj };
}

/// Returns allocator-owned JSON for recent MCP tool-call correlations.
pub fn toolCallCorrelationsValue(allocator: std.mem.Allocator, correlations: []const ports.ObservabilityToolCallCorrelation) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (correlations) |*event| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "sequence", .{ .integer = @intCast(event.sequence) });
        try obj.put(allocator, "tool_name", .{ .string = event.tool_name });
        try obj.put(allocator, "is_error", .{ .bool = event.is_error });
        try obj.put(allocator, "mcp_request_id", try observedRequestIdValue(allocator, event));
        try obj.put(allocator, "trace_id", .{ .string = event.traceId() });
        try obj.put(allocator, "span_id", .{ .string = event.spanId() });
        try obj.put(allocator, "parent_span_id", if (event.parentSpanId()) |span| .{ .string = span } else .null);
        try obj.put(allocator, "tool_call_id", .{ .string = event.toolCallId() });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Computes a per-thousand rate, returning zero for an empty denominator.
pub fn ratePerThousand(numerator: u64, denominator: u64) u64 {
    if (denominator == 0) return 0;
    return numerator * 1000 / denominator;
}

/// Projects the originating MCP request id (type, value, truncated flag) so a
/// correlation row can be joined back to the JSON-RPC request that produced it.
fn observedRequestIdValue(allocator: std.mem.Allocator, event: *const ports.ObservabilityToolCallCorrelation) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "type", .{ .string = event.mcp_request_id_type });
    try obj.put(allocator, "value", if (event.requestIdValue()) |value| .{ .string = value } else .null);
    try obj.put(allocator, "truncated", .{ .bool = event.mcp_request_id_truncated });
    return .{ .object = obj };
}

/// Samples actually retained in the ring: the running total capped at capacity.
fn retainedSampleCount(sample_count: u64) usize {
    return @intCast(@min(sample_count, @as(u64, ports.max_observability_latency_samples)));
}

/// 1-based sequence number of the oldest sample still live in the ring. Once the
/// ring has wrapped, the earliest `sample_count - capacity` samples are gone.
fn firstSampleSequence(sample_count: u64) u64 {
    if (sample_count == 0) return 1;
    if (sample_count <= @as(u64, ports.max_observability_latency_samples)) return 1;
    return sample_count - @as(u64, ports.max_observability_latency_samples) + 1;
}

/// Maps a 1-based sample sequence number to its slot in the capacity-sized ring.
fn ringIndex(sequence: u64, comptime capacity: usize) usize {
    return @intCast((sequence - 1) % @as(u64, capacity));
}

/// Nearest-rank percentile over an ascending-sorted slice. `p` is a whole
/// percent (50/95/99); rank rounds up so p99 of a short slice lands on the top
/// element, and the result is clamped to the last index to stay in bounds.
fn percentile(sorted: []const u64, p: u64) u64 {
    if (sorted.len == 0) return 0;
    const rank = (p * sorted.len + 99) / 100;
    const index = @min(sorted.len - 1, @max(@as(usize, 1), @as(usize, @intCast(rank))) - 1);
    return sorted[index];
}

test "methodStatsValue serializes method names from retained stats" {
    var stats = [_]ports.ObservabilityMethodStats{ .{}, .{} };
    @memcpy(stats[0].name[0.."tools/call".len], "tools/call");
    stats[0].name_len = "tools/call".len;
    stats[0].calls = 1;
    @memcpy(stats[1].name[0.."initialize".len], "initialize");
    stats[1].name_len = "initialize".len;
    stats[1].calls = 1;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try methodStatsValue(arena.allocator(), stats[0..]);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    const json = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tools/call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"initialize\"") != null);
}
