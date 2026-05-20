const std = @import("std");

const common = @import("common.zig");

const App = common.App;
const LspClient = common.LspClient;
const argInt = common.argInt;
const lspDiagnosticsInsightsValue = common.lspDiagnosticsInsightsValue;

pub fn waitForDiagnostics(a: *App, client: *LspClient, file_uri: []const u8, wait_ms: i64) void {
    var elapsed: i64 = 0;
    while (elapsed <= wait_ms) : (elapsed += 50) {
        if (cachedDiagnosticsOrNull(a, a.allocator, client, file_uri, "wait_for_diagnostics")) |diagnostics| {
            a.allocator.free(diagnostics);
            return;
        }
        if (elapsed == wait_ms) return;
        const step_ms = @min(@as(i64, 50), wait_ms - elapsed);
        if (step_ms <= 0) return;
        std.Io.Timeout.sleep(.{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(step_ms), .clock = .awake } }, a.io) catch |err| {
            a.logger.debug("zls", "diagnostics wait sleep failed: {}", .{err});
            return;
        };
    }
}

pub fn diagnosticPullOrNull(a: *App, allocator: std.mem.Allocator, client: *LspClient, file_uri: []const u8, tool: []const u8) ?[]const u8 {
    const Params = struct { textDocument: struct { uri: []const u8 } };
    return client.sendRequest(allocator, "textDocument/diagnostic", Params{ .textDocument = .{ .uri = file_uri } }) catch |err| {
        a.logger.debug("zls", "{s}: textDocument/diagnostic unavailable for {s}: {}", .{ tool, file_uri, err });
        return null;
    };
}

pub fn cachedDiagnosticsOrNull(a: *App, allocator: std.mem.Allocator, client: *LspClient, file_uri: []const u8, tool: []const u8) ?[]const u8 {
    return client.getDiagnostics(allocator, file_uri) catch |err| {
        a.logger.debug("zls", "{s}: diagnostics cache unavailable for {s}: {}", .{ tool, file_uri, err });
        return null;
    };
}

pub fn diagnosticWaitMs(args: ?std.json.Value) i64 {
    return @max(0, @min(argInt(args, "wait_ms", 500), 5000));
}

pub fn diagnosticsStructuredValue(allocator: std.mem.Allocator, notification: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, notification, .{});
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "method", .{ .string = "textDocument/publishDiagnostics" });
    try obj.put(allocator, "ok", .{ .bool = true });

    const notification_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try obj.put(allocator, "raw", parsed.value);
            return .{ .object = obj };
        },
    };
    const params = notification_obj.get("params") orelse .null;
    try obj.put(allocator, "result", params);
    try obj.put(allocator, "diagnostics", try lspDiagnosticsInsightsValue(allocator, params));
    return .{ .object = obj };
}
