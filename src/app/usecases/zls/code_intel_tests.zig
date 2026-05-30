//! Pins ZLS code-intel handlers to their gateway contract: every request gates
//! on capability, syncs the document, then issues the LSP call with the exact
//! JSON payload shape clients depend on, and maps each port failure to a
//! distinct Failure variant.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const fake_zls_mod = @import("../../../testing/fakes/zls_gateway.zig");
const code_intel = @import("code_intel.zig");

/// Builds a ZlsContext backed by the caller-owned fake gateway.
fn testContext(fake: *fake_zls_mod.FakeZlsGateway) app_context.ZlsContext {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

        try std.testing.expectEqual(@as(std.meta.Tag(code_intel.Failure), .missing_file), std.meta.activeTag(outcome.err));
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

test "references use case includes declaration context in ZLS payload" {
    const allocator = std.testing.allocator;
    var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
    defer fake.deinit();

    try fake.expectCapability(.{ .capability = "referencesProvider" }, .{
        .capability = "referencesProvider",
        .supported = true,
    });
    try fake.expectSync(.{ .file = "src/main.zig", .provenance = code_intel.provenance }, .{
        .uri = "file:///repo/src/main.zig",
    });
    try fake.expectRequest(.{
        .method = "textDocument/references",
        .uri = "file:///repo/src/main.zig",
        .payload = "{\"textDocument\":{\"uri\":\"file:///repo/src/main.zig\"},\"position\":{\"line\":1,\"character\":2},\"context\":{\"includeDeclaration\":false}}",
    }, .{
        .method = "textDocument/references",
        .payload = "[]",
    });

    var outcome = try code_intel.position(allocator, testContext(&fake), .{
        .method = "textDocument/references",
        .file = "src/main.zig",
        .line = 1,
        .character = 2,
        .include_declaration = false,
    });
    defer outcome.deinit(allocator);
    try std.testing.expectEqualStrings("[]", outcome.ok.payload);
    try fake.verify();
}

test "rename use case sends newName in ZLS payload" {
    const allocator = std.testing.allocator;
    var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
    defer fake.deinit();

    try fake.expectCapability(.{ .capability = "renameProvider" }, .{
        .capability = "renameProvider",
        .supported = true,
    });
    try fake.expectSync(.{ .file = "src/main.zig", .content = "const old_name = 1;\n", .provenance = code_intel.provenance }, .{
        .uri = "file:///repo/src/main.zig",
    });
    try fake.expectRequest(.{
        .method = "textDocument/rename",
        .uri = "file:///repo/src/main.zig",
        .payload = "{\"textDocument\":{\"uri\":\"file:///repo/src/main.zig\"},\"position\":{\"line\":0,\"character\":6},\"newName\":\"new_name\"}",
    }, .{
        .method = "textDocument/rename",
        .payload = "{\"result\":{\"changes\":{}}}",
    });

    var outcome = try code_intel.rename(allocator, testContext(&fake), .{
        .file = "src/main.zig",
        .content = "const old_name = 1;\n",
        .line = 0,
        .character = 6,
        .new_name = "new_name",
    });
    defer outcome.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, outcome.ok.payload, "\"changes\"") != null);
    try fake.verify();
}

test "code actions use case sends range context and selection preview" {
    const allocator = std.testing.allocator;
    var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
    defer fake.deinit();

    const expected_payload = "{\"textDocument\":{\"uri\":\"file:///repo/src/main.zig\"},\"range\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":3,\"character\":4}},\"context\":{\"diagnostics\":[]}}";
    try fake.expectCapability(.{ .capability = "codeActionProvider" }, .{
        .capability = "codeActionProvider",
        .supported = true,
    });
    try fake.expectSync(.{ .file = "src/main.zig", .provenance = code_intel.provenance }, .{
        .uri = "file:///repo/src/main.zig",
    });
    try fake.expectRequest(.{
        .method = "textDocument/codeAction",
        .uri = "file:///repo/src/main.zig",
        .payload = expected_payload,
    }, .{
        .method = "textDocument/codeAction",
        .payload = "{\"result\":[{\"title\":\"first\"},{\"title\":\"second\",\"edit\":{\"changes\":{}}}]}",
    });

    var actions = try code_intel.range(allocator, testContext(&fake), .{
        .method = "textDocument/codeAction",
        .file = "src/main.zig",
        .start_line = 1,
        .start_character = 2,
        .end_line = 3,
        .end_character = 4,
    });
    defer actions.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, actions.ok.payload, "\"second\"") != null);
    try fake.verify();

    var selector_fake = fake_zls_mod.FakeZlsGateway.init(allocator);
    defer selector_fake.deinit();
    try selector_fake.expectCapability(.{ .capability = "codeActionProvider" }, .{
        .capability = "codeActionProvider",
        .supported = true,
    });
    try selector_fake.expectSync(.{ .file = "src/main.zig", .provenance = code_intel.provenance }, .{
        .uri = "file:///repo/src/main.zig",
    });
    try selector_fake.expectRequest(.{
        .method = "textDocument/codeAction",
        .uri = "file:///repo/src/main.zig",
        .payload = expected_payload,
    }, .{
        .method = "textDocument/codeAction",
        .payload = "{\"result\":[{\"title\":\"first\"},{\"title\":\"second\",\"edit\":{\"changes\":{}}}]}",
    });
    var selected = try code_intel.codeActionSelection(allocator, testContext(&selector_fake), .{
        .file = "src/main.zig",
        .start_line = 1,
        .start_character = 2,
        .end_line = 3,
        .end_character = 4,
        .action_index = 1,
    });
    defer selected.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, selected.ok.payload, "\"title\":\"second\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected.ok.payload, "\"title\":\"first\"") == null);
    try selector_fake.verify();
}

test "file-only and workspace symbol use cases send expected ZLS payloads" {
    const allocator = std.testing.allocator;
    var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
    defer fake.deinit();

    try fake.expectCapability(.{ .capability = "documentSymbolProvider" }, .{
        .capability = "documentSymbolProvider",
        .supported = true,
    });
    try fake.expectSync(.{ .file = "src/main.zig", .content = "const x = 1;\n", .provenance = code_intel.provenance }, .{
        .uri = "file:///repo/src/main.zig",
    });
    try fake.expectRequest(.{
        .method = "textDocument/documentSymbol",
        .uri = "file:///repo/src/main.zig",
        .payload = "{\"textDocument\":{\"uri\":\"file:///repo/src/main.zig\"}}",
    }, .{
        .method = "textDocument/documentSymbol",
        .payload = "[]",
    });
    try fake.expectCapability(.{ .capability = "workspaceSymbolProvider" }, .{
        .capability = "workspaceSymbolProvider",
        .supported = true,
    });
    try fake.expectRequest(.{
        .method = "workspace/symbol",
        .payload = "{\"query\":\"Thing\"}",
    }, .{
        .method = "workspace/symbol",
        .payload = "[{\"name\":\"Thing\"}]",
    });

    var file_outcome = try code_intel.fileOnly(allocator, testContext(&fake), .{
        .method = "textDocument/documentSymbol",
        .file = "src/main.zig",
        .content = "const x = 1;\n",
    });
    defer file_outcome.deinit(allocator);
    try std.testing.expectEqualStrings("[]", file_outcome.ok.payload);

    var workspace_outcome = try code_intel.workspaceSymbols(allocator, testContext(&fake), .{ .query = "Thing" });
    defer workspace_outcome.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, workspace_outcome.ok.payload, "Thing") != null);
    try fake.verify();
}

test "file-only use case propagates capability allocation failure" {
    const allocator = std.testing.allocator;
    var fake = fake_zls_mod.FakeZlsGateway.init(allocator);
    defer fake.deinit();
    try fake.expectCapabilityError(.{ .capability = "documentSymbolProvider" }, error.OutOfMemory);

    try std.testing.expectError(error.OutOfMemory, code_intel.fileOnly(allocator, testContext(&fake), .{
        .method = "textDocument/documentSymbol",
        .file = "src/main.zig",
    }));
    try fake.verify();
}
