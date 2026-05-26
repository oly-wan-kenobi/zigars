//! Bridges compile-time manifest definitions into the app port shape consumed by adapters and use cases.
const std = @import("std");

const manifest = @import("../manifest/mod.zig");
const ports = @import("../app/ports.zig");

/// Read-only app port adapter over compile-time manifest entries.
pub const Catalog = struct {
    /// Exposes manifest metadata through an app-defined vtable to keep bootstrap->app dependency one-way.
    pub fn port(self: *Catalog) ports.ToolManifestCatalog {
        return .{
            .ptr = self,
            .vtable = &.{
                .count = count,
                .entry_at = entryAt,
                .find = find,
            },
        };
    }

    fn count(_: *anyopaque) usize {
        return manifest.entries.len;
    }

    fn entryAt(_: *anyopaque, index: usize) ?ports.ToolManifestEntry {
        if (index >= manifest.entries.len) return null;
        return mapEntry(manifest.entries[index]);
    }

    fn find(_: *anyopaque, name: []const u8) ?ports.ToolManifestEntry {
        const entry = manifest.findEntry(name) orelse return null;
        return mapEntry(entry);
    }
};

/// Narrows manifest internals to the stable tool-manifest contract used outside bootstrap.
fn mapEntry(entry: manifest.ToolEntry) ports.ToolManifestEntry {
    return .{
        .name = entry.name,
        .description = entry.meta.description,
        .group = manifest.groupName(entry.group),
        .read_only = entry.meta.read_only,
        .mcp_read_only_hint = manifest.readOnlyHintFor(entry.meta),
        .plan_kind = manifest.planKind(entry.plan),
        .plan = mapPlan(entry.plan),
        .risk = .{
            .writes_source = entry.risk.writes_source,
            .writes_artifacts = entry.risk.writes_artifacts,
            .writes_require_apply = entry.risk.writes_require_apply,
            .preview_by_default = entry.risk.preview_by_default,
            .mutates_lsp_state = entry.risk.mutates_lsp_state,
            .executes_project_code = entry.risk.executes_project_code,
            .executes_user_command = entry.risk.executes_user_command,
            .executes_backend = entry.risk.executes_backend,
        },
    };
}

fn mapPlan(plan: manifest.PlanPolicy) ports.PlanPolicy {
    return switch (plan) {
        .exact_command => |command| .{ .exact_command = mapCommandPlan(command) },
        .dynamic_command => |reason| .{ .dynamic_command = reason },
        .zls_request => |zls| .{ .zls_request = .{
            .method = zls.method,
            .requires_document_sync = zls.requires_document_sync,
            .mutates_document_state = zls.mutates_document_state,
            .required_capability = zls.required_capability,
        } },
        .apply_gated_mutation => |reason| .{ .apply_gated_mutation = reason },
        .workspace_artifact => |reason| .{ .workspace_artifact = reason },
        .pure_analysis => |reason| .{ .pure_analysis = reason },
        .not_plannable => |reason| .{ .not_plannable = reason },
    };
}

fn mapCommandPlan(plan: manifest.CommandPlan) ports.CommandPlan {
    return switch (plan) {
        .argv => |argv| .{ .argv = argv },
        .optional_file => |file_plan| .{ .optional_file = .{
            .file_args = file_plan.file_args,
            .fallback_args = file_plan.fallback_args,
        } },
        .required_file => |argv| .{ .required_file = argv },
        .required_path => |argv| .{ .required_path = argv },
    };
}
