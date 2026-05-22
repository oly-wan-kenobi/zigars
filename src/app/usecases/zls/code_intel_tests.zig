const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const fake_zls_mod = @import("../../../testing/fakes/zls_gateway.zig");
const code_intel = @import("code_intel.zig");

fn testContext(fake: *fake_zls_mod.FakeZlsGateway) app_context.ZlsContext {
    return .{
        .workspace = .{ .root = "/repo" },
        .tool_paths = .{ .zls = "/bin/zls" },
        .timeouts = .{ .zls_ms = 1000 },
        .zls_state = .{ .status = "connected" },
        .zls_gateway = fake.port(),
    };
}

test "hover use case syncs document and sends position request through ZLS gateway" {
    const allocator = std.testing.allocator;
    var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
    defer fake.deinit();

    try fake.expectCapability(.{ .capability = "hoverProvider" }, .{
        .capability = "hoverProvider",
        .supported = true,
        .basis = "initialize",
    });
    try fake.expectSync(.{ .file = "src/main.zig", .content = "const answer = 42;\n", .provenance = code_intel.provenance }, .{
        .uri = "file:///repo/src/main.zig",
        .basis = "didOpen",
    });
    try fake.expectRequest(.{
        .method = "textDocument/hover",
        .uri = "file:///repo/src/main.zig",
        .payload = "{\"textDocument\":{\"uri\":\"file:///repo/src/main.zig\"},\"position\":{\"line\":2,\"character\":4}}",
    }, .{
        .method = "textDocument/hover",
        .payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"contents\":\"answer\"}}",
    });

    var outcome = try code_intel.position(allocator, testContext(&fake), .{
        .method = "textDocument/hover",
        .file = "src/main.zig",
        .content = "const answer = 42;\n",
        .line = 2,
        .character = 4,
    });
    defer outcome.deinit(allocator);

    const response = outcome.ok;
    try std.testing.expectEqualStrings("textDocument/hover", response.method);
    try std.testing.expect(std.mem.indexOf(u8, response.payload, "\"contents\":\"answer\"") != null);
    try std.testing.expectEqual(@as(usize, 1), fake.syncCalls().len);
    try std.testing.expectEqual(@as(usize, 1), fake.requestCalls().len);
    try fake.verify();
}

test "hover use case reports unsupported capability before document sync" {
    const allocator = std.testing.allocator;
    var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
    defer fake.deinit();

    try fake.expectCapability(.{ .capability = "hoverProvider" }, .{
        .capability = "hoverProvider",
        .supported = false,
        .basis = "initialize",
    });

    const outcome = try code_intel.position(allocator, testContext(&fake), .{
        .method = "textDocument/hover",
        .file = "src/main.zig",
    });

    try std.testing.expectEqualStrings("hoverProvider", outcome.err.unsupported_capability);
    try std.testing.expectEqual(@as(usize, 0), fake.syncCalls().len);
    try fake.verify();
}

test "hover use case checks capability before reporting missing file" {
    const allocator = std.testing.allocator;
    {
        var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
        defer fake.deinit();
        try fake.expectCapabilityError(.{ .capability = "hoverProvider" }, error.Unavailable);

        const outcome = try code_intel.position(allocator, testContext(&fake), .{
            .method = "textDocument/hover",
        });

        try std.testing.expectEqualStrings("hoverProvider", outcome.err.unavailable);
        try std.testing.expectEqual(@as(usize, 0), fake.syncCalls().len);
        try fake.verify();
    }
    {
        var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
        defer fake.deinit();
        try fake.expectCapability(.{ .capability = "hoverProvider" }, .{
            .capability = "hoverProvider",
            .supported = true,
        });

        const outcome = try code_intel.position(allocator, testContext(&fake), .{
            .method = "textDocument/hover",
        });

        switch (outcome.err) {
            .missing_file => {},
            else => return error.UnexpectedFailure,
        }
        try std.testing.expectEqual(@as(usize, 0), fake.syncCalls().len);
        try fake.verify();
    }
}

test "hover use case maps gateway unavailable and document limits" {
    const allocator = std.testing.allocator;
    {
        var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
        defer fake.deinit();
        try fake.expectCapabilityError(.{ .capability = "hoverProvider" }, error.Unavailable);

        const outcome = try code_intel.position(allocator, testContext(&fake), .{
            .method = "textDocument/hover",
            .file = "src/main.zig",
        });
        try std.testing.expectEqualStrings("hoverProvider", outcome.err.unavailable);
        try fake.verify();
    }
    {
        var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
        defer fake.deinit();
        try fake.expectCapability(.{ .capability = "hoverProvider" }, .{
            .capability = "hoverProvider",
            .supported = true,
        });
        try fake.expectSyncError(.{ .file = "src/main.zig", .content = "large", .provenance = code_intel.provenance }, error.DocumentTooLarge);

        const outcome = try code_intel.position(allocator, testContext(&fake), .{
            .method = "textDocument/hover",
            .file = "src/main.zig",
            .content = "large",
        });
        try std.testing.expectEqual(error.DocumentTooLarge, outcome.err.sync_failed.err);
        try fake.verify();
    }
}

test "hover use case reports request timeout without changing public payload shape" {
    const allocator = std.testing.allocator;
    var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
    defer fake.deinit();

    try fake.expectCapability(.{ .capability = "hoverProvider" }, .{
        .capability = "hoverProvider",
        .supported = true,
    });
    try fake.expectSync(.{ .file = "src/main.zig", .provenance = code_intel.provenance }, .{
        .uri = "file:///repo/src/main.zig",
    });
    try fake.expectRequestError(.{
        .method = "textDocument/hover",
        .uri = "file:///repo/src/main.zig",
        .payload = "{\"textDocument\":{\"uri\":\"file:///repo/src/main.zig\"},\"position\":{\"line\":0,\"character\":0}}",
    }, error.RequestTimeout);

    const outcome = try code_intel.position(allocator, testContext(&fake), .{
        .method = "textDocument/hover",
        .file = "src/main.zig",
    });

    try std.testing.expectEqual(error.RequestTimeout, outcome.err.request_failed.err);
    try fake.verify();
}
