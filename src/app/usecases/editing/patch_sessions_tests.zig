const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const fakes = @import("../../../testing/fakes/root.zig");
const patch_sessions = @import("patch_sessions.zig");
const session_domain = @import("../../../domain/editing/patch_session.zig");
const validation = @import("../validation/workflows.zig");

/// Carries editing ports data across use case and port boundaries.
const EditingPorts = struct {
    workspace: *fakes.FakeWorkspaceStore,
    clock: *fakes.FakeClockAndIds,

    /// Returns a typed context backed by this fixture or runtime state.
    fn context(self: EditingPorts) app_context.EditingContext {
        return .{
            .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
            .workspace_store = self.workspace.port(),
            .clock_and_ids = self.clock.port(),
        };
    }
};

/// Carries validation ports data across use case and port boundaries.
const ValidationPorts = struct {
    command: *fakes.FakeCommandRunner,
    workspace: *fakes.FakeWorkspaceStore,
    clock: *fakes.FakeClockAndIds,

    /// Returns a typed context backed by this fixture or runtime state.
    fn context(self: ValidationPorts) app_context.ValidationContext {
        return .{
            .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
            .tool_paths = .{ .zig = "zig" },
            .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
            .command_runner = self.command.port(),
            .workspace_store = self.workspace.port(),
            .clock_and_ids = self.clock.port(),
        };
    }
};

test "patch session preview is apply gated and performs no writes" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, "const value = 1;\n");

    var result = try patch_sessions.replacementSession(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .operation = .preview,
        .session_id = "session-preview",
        .replacements = &.{.{ .file = "src/main.zig", .content = "const value = 2;\n" }},
        .apply = false,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.applied);
    try std.testing.expect(result.requires_apply);
    try std.testing.expect(result.safe_to_apply);
    try std.testing.expectEqual(@as(usize, 1), result.changed_file_count);
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expect(std.mem.indexOf(u8, result.files[0].diff, "-const value = 1;") != null);
    try std.testing.expectEqual(@as(usize, 0), workspace.writeCalls().len);
    try workspace.verify();
    try clock.verify();
}

test "patch session apply rejects stale expected preimages before writes" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    var old_identity = try session_domain.identityFromBytes(std.testing.allocator, true, "const value = 1;\n");
    defer old_identity.deinit(std.testing.allocator);
    const expected = [_]patch_sessions.ExpectedPreimage{.{ .file = "src/main.zig", .identity = old_identity }};

    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, "const value = 99;\n");

    var result = try patch_sessions.replacementSession(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .operation = .apply,
        .session_id = "session-stale",
        .replacements = &.{.{ .file = "src/main.zig", .content = "const value = 2;\n" }},
        .expected_preimages = &expected,
        .apply = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.applied);
    try std.testing.expect(!result.safe_to_apply);
    try std.testing.expect(result.blocked);
    try std.testing.expect(!result.files[0].expected_preimage_matched);
    try std.testing.expectEqual(@as(usize, 0), workspace.writeCalls().len);
    try workspace.verify();
    try clock.verify();
}

test "patch session blocks generated and vendor paths by policy" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    try workspace.expectReadError(.{
        .path = "docs/tool-index.generated.md",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, error.FileNotFound);
    try workspace.expectRead(.{
        .path = "third_party/lib.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, "const upstream = true;\n");

    var result = try patch_sessions.create(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .session_id = "session-policy",
        .paths = &.{ "docs/tool-index.generated.md", "third_party/lib.zig" },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.safe_to_edit);
    try std.testing.expectEqualStrings("generated", result.files[0].ok.policy.classification);
    try std.testing.expectEqualStrings("vendor", result.files[1].ok.policy.classification);
    try workspace.verify();
    try clock.verify();
}

test "patch session apply records rollback history and revert restores own change" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    const before = "pub fn main() void {}\n";
    const after = "pub fn main() void {\n    _ = 1;\n}\n";
    var before_identity = try session_domain.identityFromBytes(std.testing.allocator, true, before);
    defer before_identity.deinit(std.testing.allocator);
    var after_identity = try session_domain.identityFromBytes(std.testing.allocator, true, after);
    defer after_identity.deinit(std.testing.allocator);
    const expected = [_]patch_sessions.ExpectedPreimage{.{ .file = "src/main.zig", .identity = before_identity }};
    const expected_history = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"kind\":\"zigar_patch_session_record\",\"schema_version\":1,\"session_id\":\"session-apply\",\"goal\":\"test rollback\",\"recorded_unix_ms\":1700000000010,\"files\":[{{\"file\":\"src/main.zig\",\"preimage_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"updated_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"preimage_content_path\":\".zigar-cache/patch-sessions/session-apply/0-src_main.zig.preimage\"}}]}}\n",
        .{ before.len, before_identity.sha256.?, after.len, after_identity.sha256.? },
    );
    defer std.testing.allocator.free(expected_history);

    try clock.pushInstant(.{ .unix_ms = 1_700_000_000_010, .monotonic_ms = 1 });
    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, before);
    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, before);
    try workspace.expectWrite(.{
        .path = ".zigar-cache/patch-sessions/session-apply/0-src_main.zig.preimage",
        .bytes = before,
        .provenance = "patch_session_preimage",
    }, .{ .bytes_written = before.len });
    try workspace.expectWrite(.{
        .path = "src/main.zig",
        .bytes = after,
        .provenance = "patch_session_apply",
    }, .{ .bytes_written = after.len });
    try workspace.expectReadError(.{
        .path = patch_sessions.history_path_default,
        .max_bytes = patch_sessions.history_max_bytes,
        .provenance = "patch_session_history_read",
    }, error.FileNotFound);
    try workspace.expectWrite(.{
        .path = patch_sessions.history_path_default,
        .bytes = expected_history,
        .provenance = "patch_session_history_append",
    }, .{ .bytes_written = expected_history.len });

    var apply_result = try patch_sessions.replacementSession(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .operation = .apply,
        .session_id = "session-apply",
        .goal = "test rollback",
        .replacements = &.{.{ .file = "src/main.zig", .content = after }},
        .expected_preimages = &expected,
        .apply = true,
    });
    defer apply_result.deinit(std.testing.allocator);

    try std.testing.expect(apply_result.applied);
    try std.testing.expectEqual(@as(usize, 3), workspace.writeCalls().len);
    const history_line = workspace.writeCalls()[2].bytes;
    try std.testing.expect(std.mem.indexOf(u8, history_line, "\"kind\":\"zigar_patch_session_record\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, history_line, "\"recorded_unix_ms\":1700000000010") != null);

    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, after);
    try workspace.expectRead(.{
        .path = ".zigar-cache/patch-sessions/session-apply/0-src_main.zig.preimage",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_revert_preimage",
    }, before);
    try workspace.expectRead(.{
        .path = ".zigar-cache/patch-sessions/session-apply/0-src_main.zig.preimage",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_revert_preimage",
    }, before);
    try workspace.expectWrite(.{
        .path = "src/main.zig",
        .bytes = before,
        .provenance = "patch_session_revert",
    }, .{ .bytes_written = before.len });

    var revert_outcome = try patch_sessions.revert(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .session_id = "session-apply",
        .apply = true,
        .history = history_line,
    });
    defer revert_outcome.deinit(std.testing.allocator);
    const revert_result = revert_outcome.ok;
    try std.testing.expect(revert_result.applied);
    try std.testing.expect(revert_result.safe_to_revert);
    try std.testing.expectEqual(@as(usize, 1), revert_result.files.len);
    try std.testing.expect(std.mem.indexOf(u8, revert_result.files[0].diff, "-    _ = 1;") != null);
    try workspace.verify();
    try clock.verify();
}

test "patch session apply records unchanged and created file identity shapes" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    const same = "const same = true;\n";
    const created = "const created = true;\n";
    var same_identity = try session_domain.identityFromBytes(std.testing.allocator, true, same);
    defer same_identity.deinit(std.testing.allocator);
    var missing_identity = try session_domain.identityFromBytes(std.testing.allocator, false, "");
    defer missing_identity.deinit(std.testing.allocator);
    var created_identity = try session_domain.identityFromBytes(std.testing.allocator, true, created);
    defer created_identity.deinit(std.testing.allocator);
    const expected = [_]patch_sessions.ExpectedPreimage{
        .{ .file = "src/same.zig", .identity = same_identity },
        .{ .file = "src/new.zig", .identity = missing_identity },
    };
    const expected_history = try std.fmt.allocPrint(
        std.testing.allocator,
        "prior\n{{\"kind\":\"zigar_patch_session_record\",\"schema_version\":1,\"session_id\":\"session-shapes\",\"goal\":null,\"recorded_unix_ms\":1700000000030,\"files\":[{{\"file\":\"src/same.zig\",\"preimage_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"updated_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"preimage_content_path\":null}},{{\"file\":\"src/new.zig\",\"preimage_identity\":{{\"exists\":false,\"bytes\":0,\"sha256\":null}},\"updated_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"preimage_content_path\":\".zigar-cache/patch-sessions/session-shapes/1-src_new.zig.preimage\"}}]}}\n",
        .{ same.len, same_identity.sha256.?, same.len, same_identity.sha256.?, created.len, created_identity.sha256.? },
    );
    defer std.testing.allocator.free(expected_history);

    try clock.pushInstant(.{ .unix_ms = 1_700_000_000_030, .monotonic_ms = 1 });
    try workspace.expectRead(.{
        .path = "src/same.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, same);
    try workspace.expectReadError(.{
        .path = "src/new.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, error.FileNotFound);
    try workspace.expectRead(.{
        .path = "src/same.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, same);
    try workspace.expectReadError(.{
        .path = "src/new.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, error.FileNotFound);
    try workspace.expectWrite(.{
        .path = ".zigar-cache/patch-sessions/session-shapes/1-src_new.zig.preimage",
        .bytes = "",
        .provenance = "patch_session_preimage",
    }, .{ .bytes_written = 0 });
    try workspace.expectWrite(.{
        .path = "src/new.zig",
        .bytes = created,
        .provenance = "patch_session_apply",
    }, .{ .bytes_written = created.len });
    try workspace.expectRead(.{
        .path = patch_sessions.history_path_default,
        .max_bytes = patch_sessions.history_max_bytes,
        .provenance = "patch_session_history_read",
    }, "prior");
    try workspace.expectWrite(.{
        .path = patch_sessions.history_path_default,
        .bytes = expected_history,
        .provenance = "patch_session_history_append",
    }, .{ .bytes_written = expected_history.len });

    var result = try patch_sessions.replacementSession(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .operation = .apply,
        .session_id = "session-shapes",
        .replacements = &.{
            .{ .file = "src/same.zig", .content = same },
            .{ .file = "src/new.zig", .content = created },
        },
        .expected_preimages = &expected,
        .apply = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.applied);
    try std.testing.expectEqual(@as(usize, 1), result.changed_file_count);
    try std.testing.expect(!result.files[0].changed);
    try std.testing.expect(result.files[1].changed);
    try workspace.verify();
    try clock.verify();
}

test "patch session apply propagates history read failures after staged writes" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    const before = "const value = 1;\n";
    const after = "const value = 2;\n";
    var before_identity = try session_domain.identityFromBytes(std.testing.allocator, true, before);
    defer before_identity.deinit(std.testing.allocator);
    const expected = [_]patch_sessions.ExpectedPreimage{.{ .file = "src/main.zig", .identity = before_identity }};

    try clock.pushInstant(.{ .unix_ms = 1_700_000_000_040, .monotonic_ms = 1 });
    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, before);
    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, before);
    try workspace.expectWrite(.{
        .path = ".zigar-cache/patch-sessions/session-history-error/0-src_main.zig.preimage",
        .bytes = before,
        .provenance = "patch_session_preimage",
    }, .{ .bytes_written = before.len });
    try workspace.expectWrite(.{
        .path = "src/main.zig",
        .bytes = after,
        .provenance = "patch_session_apply",
    }, .{ .bytes_written = after.len });
    try workspace.expectReadError(.{
        .path = patch_sessions.history_path_default,
        .max_bytes = patch_sessions.history_max_bytes,
        .provenance = "patch_session_history_read",
    }, error.AccessDenied);

    try std.testing.expectError(error.AccessDenied, patch_sessions.replacementSession(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .operation = .apply,
        .session_id = "session-history-error",
        .replacements = &.{.{ .file = "src/main.zig", .content = after }},
        .expected_preimages = &expected,
        .apply = true,
    }));

    try workspace.verify();
    try clock.verify();
}

test "patch session revert deletes files created by the session" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    const created = "const created = true;\n";
    var created_identity = try session_domain.identityFromBytes(std.testing.allocator, true, created);
    defer created_identity.deinit(std.testing.allocator);
    const history = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"kind\":\"zigar_patch_session_record\",\"schema_version\":1,\"session_id\":\"session-created\",\"goal\":null,\"recorded_unix_ms\":1,\"files\":[{{\"file\":\"src/new.zig\",\"preimage_identity\":{{\"exists\":false,\"bytes\":0,\"sha256\":null}},\"updated_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"preimage_content_path\":\".zigar-cache/patch-sessions/session-created/0-src_new.zig.preimage\"}}]}}\n",
        .{ created.len, created_identity.sha256.? },
    );
    defer std.testing.allocator.free(history);

    try workspace.expectRead(.{
        .path = "src/new.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, created);
    try workspace.expectDelete(.{
        .path = "src/new.zig",
        .missing_ok = true,
        .provenance = "patch_session_revert_delete",
    }, .{ .deleted = true });

    var outcome = try patch_sessions.revert(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .session_id = "session-created",
        .apply = true,
        .history = history,
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome.ok.applied);
    try std.testing.expect(outcome.ok.files[0].would_delete);
    try std.testing.expectEqual(@as(usize, 1), workspace.deleteCalls().len);
    try workspace.verify();
    try clock.verify();
}

test "patch session revert reads array history and reports missing jsonl sessions" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    const created = "const created = true;\n";
    var created_identity = try session_domain.identityFromBytes(std.testing.allocator, true, created);
    defer created_identity.deinit(std.testing.allocator);
    const array_history = try std.fmt.allocPrint(
        std.testing.allocator,
        "[{{\"kind\":\"zigar_patch_session_record\",\"schema_version\":1,\"session_id\":\"other\",\"goal\":null,\"recorded_unix_ms\":1,\"files\":[]}},{{\"kind\":\"zigar_patch_session_record\",\"schema_version\":1,\"session_id\":\"array-session\",\"goal\":null,\"recorded_unix_ms\":2,\"files\":[{{\"file\":\"src/new.zig\",\"preimage_identity\":{{\"exists\":false,\"bytes\":0,\"sha256\":null}},\"updated_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"preimage_content_path\":\".zigar-cache/patch-sessions/array-session/0-src_new.zig.preimage\"}}]}}]",
        .{ created.len, created_identity.sha256.? },
    );
    defer std.testing.allocator.free(array_history);

    try workspace.expectRead(.{
        .path = "src/new.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, created);

    var outcome = try patch_sessions.revert(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .session_id = "array-session",
        .history = array_history,
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome.ok.safe_to_revert);
    try std.testing.expect(outcome.ok.requires_apply);

    var missing = try patch_sessions.revert(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .session_id = "missing-session",
        .history = "{\"kind\":\"zigar_patch_session_record\",\"schema_version\":1,\"session_id\":\"other\",\"goal\":null,\"recorded_unix_ms\":1,\"files\":[]}\n",
    });
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(patch_sessions.RevertFailure.not_found, missing.err);
    try workspace.verify();
    try clock.verify();
}

test "patch session revert cleans parsed records on malformed history files" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    const valid_identity = try session_domain.identityFromBytes(std.testing.allocator, false, "");
    var updated_identity = try session_domain.identityFromBytes(std.testing.allocator, true, "const ok = true;\n");
    defer updated_identity.deinit(std.testing.allocator);
    const bad_history = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"kind\":\"zigar_patch_session_record\",\"schema_version\":1,\"session_id\":\"bad-history\",\"goal\":null,\"recorded_unix_ms\":1,\"files\":[{{\"file\":\"src/ok.zig\",\"preimage_identity\":{{\"exists\":false,\"bytes\":0,\"sha256\":null}},\"updated_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"preimage_content_path\":null}},{{\"file\":\"src/bad.zig\",\"preimage_identity\":null,\"updated_identity\":{{\"exists\":true,\"bytes\":0,\"sha256\":null}},\"preimage_content_path\":null}}]}}\n",
        .{ updated_identity.bytes, updated_identity.sha256.? },
    );
    defer std.testing.allocator.free(bad_history);
    var owned_valid_identity = valid_identity;
    owned_valid_identity.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidArguments, patch_sessions.revert(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .session_id = "bad-history",
        .history = bad_history,
    }));
    try workspace.verify();
    try clock.verify();
}

test "patch session revert releases previews when later preimage reads fail" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    const before = "const value = 1;\n";
    const after = "const value = 2;\n";
    var before_identity = try session_domain.identityFromBytes(std.testing.allocator, true, before);
    defer before_identity.deinit(std.testing.allocator);
    var after_identity = try session_domain.identityFromBytes(std.testing.allocator, true, after);
    defer after_identity.deinit(std.testing.allocator);
    const history = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"kind\":\"zigar_patch_session_record\",\"schema_version\":1,\"session_id\":\"revert-read-error\",\"goal\":null,\"recorded_unix_ms\":1,\"files\":[{{\"file\":\"src/a.zig\",\"preimage_identity\":{{\"exists\":false,\"bytes\":0,\"sha256\":null}},\"updated_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"preimage_content_path\":null}},{{\"file\":\"src/b.zig\",\"preimage_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"updated_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"preimage_content_path\":\".zigar-cache/patch-sessions/revert-read-error/1-src_b.zig.preimage\"}}]}}\n",
        .{ after.len, after_identity.sha256.?, before.len, before_identity.sha256.?, after.len, after_identity.sha256.? },
    );
    defer std.testing.allocator.free(history);

    try workspace.expectRead(.{
        .path = "src/a.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, after);
    try workspace.expectRead(.{
        .path = "src/b.zig",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_snapshot",
    }, after);
    try workspace.expectReadError(.{
        .path = ".zigar-cache/patch-sessions/revert-read-error/1-src_b.zig.preimage",
        .max_bytes = patch_sessions.max_session_file_bytes,
        .provenance = "patch_session_revert_preimage",
    }, error.AccessDenied);

    try std.testing.expectError(error.AccessDenied, patch_sessions.revert(std.testing.allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
        .session_id = "revert-read-error",
        .history = history,
    }));
    try workspace.verify();
    try clock.verify();
}

test "patch session validate composes typed validation result" {
    var command = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    try clock.pushInstant(.{ .unix_ms = 1_700_000_000_020, .monotonic_ms = 1 });
    try workspace.expectReadError(.{
        .path = validation.history_path_default,
        .max_bytes = validation.history_max_bytes,
        .provenance = "zigar_validation_run history preimage",
    }, error.FileNotFound);

    var outcome = try patch_sessions.validate(std.testing.allocator, (ValidationPorts{ .command = &command, .workspace = &workspace, .clock = &clock }).context(), .{
        .plan = .{ .mode = "quick", .changed_paths = &.{"notes.txt"} },
        .apply = false,
    });
    defer outcome.deinit(std.testing.allocator);
    const report = outcome.ok;

    try std.testing.expect(report.ok);
    try std.testing.expect(!report.history_applied);
    try std.testing.expect(report.requires_apply_for_history);
    try std.testing.expect(report.skipped_phases.len >= 1);
    try workspace.verify();
    try command.verify();
    try clock.verify();
}

test "patch session create and replacement paths tolerate allocation failures" {
    var fail_index: usize = 0;
    while (fail_index < 512) : (fail_index += 1) {
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
            defer clock.deinit();

            try workspace.expectReadError(.{
                .path = "src/missing.zig",
                .max_bytes = patch_sessions.max_session_file_bytes,
                .provenance = "patch_session_snapshot",
            }, error.AccessDenied);
            try workspace.expectRead(.{
                .path = "src/a.zig",
                .max_bytes = patch_sessions.max_session_file_bytes,
                .provenance = "patch_session_snapshot",
            }, "const a = 1;\n");

            if (patch_sessions.create(allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
                .session_id = "oom-create",
                .goal = "capture",
                .paths = &.{ "src/missing.zig", "src/a.zig" },
            })) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
        }

        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
            defer clock.deinit();

            const before = "const before = 1;\n";
            const after = "const before = 2;\n";
            var before_identity = try session_domain.identityFromBytes(std.testing.allocator, true, before);
            defer before_identity.deinit(std.testing.allocator);
            var after_identity = try session_domain.identityFromBytes(std.testing.allocator, true, after);
            defer after_identity.deinit(std.testing.allocator);
            const expected = [_]patch_sessions.ExpectedPreimage{.{ .file = "src/main.zig", .identity = before_identity }};
            const expected_history = try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"kind\":\"zigar_patch_session_record\",\"schema_version\":1,\"session_id\":\"oom-replace\",\"goal\":\"replace\",\"recorded_unix_ms\":1700000000050,\"files\":[{{\"file\":\"src/main.zig\",\"preimage_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"updated_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"preimage_content_path\":\".zigar-cache/patch-sessions/oom-replace/0-src_main.zig.preimage\"}}]}}\n",
                .{ before.len, before_identity.sha256.?, after.len, after_identity.sha256.? },
            );
            defer std.testing.allocator.free(expected_history);

            try clock.pushInstant(.{ .unix_ms = 1_700_000_000_050, .monotonic_ms = 1 });
            try workspace.expectRead(.{
                .path = "src/main.zig",
                .max_bytes = patch_sessions.max_session_file_bytes,
                .provenance = "patch_session_snapshot",
            }, before);
            try workspace.expectRead(.{
                .path = "src/main.zig",
                .max_bytes = patch_sessions.max_session_file_bytes,
                .provenance = "patch_session_snapshot",
            }, before);
            try workspace.expectWrite(.{
                .path = ".zigar-cache/patch-sessions/oom-replace/0-src_main.zig.preimage",
                .bytes = before,
                .provenance = "patch_session_preimage",
            }, .{ .bytes_written = before.len });
            try workspace.expectWrite(.{
                .path = "src/main.zig",
                .bytes = after,
                .provenance = "patch_session_apply",
            }, .{ .bytes_written = after.len });
            try workspace.expectReadError(.{
                .path = patch_sessions.history_path_default,
                .max_bytes = patch_sessions.history_max_bytes,
                .provenance = "patch_session_history_read",
            }, error.FileNotFound);
            try workspace.expectWrite(.{
                .path = patch_sessions.history_path_default,
                .bytes = expected_history,
                .provenance = "patch_session_history_append",
            }, .{ .bytes_written = expected_history.len });

            if (patch_sessions.replacementSession(allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
                .operation = .apply,
                .session_id = "oom-replace",
                .goal = "replace",
                .replacements = &.{.{ .file = "src/main.zig", .content = after }},
                .expected_preimages = &expected,
                .apply = true,
            })) |result| {
                var owned = result;
                owned.deinit(allocator);
            } else |err| try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
        }
    }
}

test "patch session revert tolerates allocation failures" {
    var fail_index: usize = 0;
    while (fail_index < 512) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
        defer workspace.deinit();
        var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
        defer clock.deinit();

        const before = "const value = 1;\n";
        const after = "const value = 2;\n";
        var before_identity = try session_domain.identityFromBytes(std.testing.allocator, true, before);
        defer before_identity.deinit(std.testing.allocator);
        var after_identity = try session_domain.identityFromBytes(std.testing.allocator, true, after);
        defer after_identity.deinit(std.testing.allocator);
        const history = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"kind\":\"zigar_patch_session_record\",\"schema_version\":1,\"session_id\":\"oom-revert\",\"goal\":\"revert\",\"recorded_unix_ms\":1,\"files\":[{{\"file\":\"src/main.zig\",\"preimage_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"updated_identity\":{{\"exists\":true,\"bytes\":{d},\"sha256\":\"{s}\"}},\"preimage_content_path\":\".zigar-cache/patch-sessions/oom-revert/0-src_main.zig.preimage\"}}]}}\n",
            .{ before.len, before_identity.sha256.?, after.len, after_identity.sha256.? },
        );
        defer std.testing.allocator.free(history);

        try workspace.expectRead(.{
            .path = "src/main.zig",
            .max_bytes = patch_sessions.max_session_file_bytes,
            .provenance = "patch_session_snapshot",
        }, after);
        try workspace.expectRead(.{
            .path = ".zigar-cache/patch-sessions/oom-revert/0-src_main.zig.preimage",
            .max_bytes = patch_sessions.max_session_file_bytes,
            .provenance = "patch_session_revert_preimage",
        }, before);

        if (patch_sessions.revert(allocator, (EditingPorts{ .workspace = &workspace, .clock = &clock }).context(), .{
            .session_id = "oom-revert",
            .history = history,
        })) |outcome| {
            var owned = outcome;
            owned.deinit(allocator);
        } else |err| try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
    }
}
