//! Invariant tests for MCP handler registration.
//! Pins that every manifest entry resolves to a named handler, every declared
//! handler module owns at least one registered tool, and the document-change
//! handler name stays stable across refactors.

const std = @import("std");
const tool_manifest = @import("../../manifest/mod.zig");
const handler_refs = @import("../../adapters/mcp/handler_refs.zig");

test {
    _ = @import("../../manifest/invariants.zig");
}

test "manifest handler references stay resolvable by adapter compatibility modules" {
    for (tool_manifest.entries) |entry| {
        const handler_ref = handler_refs.handlerFor(entry.id);
        try std.testing.expect(handler_ref.name.len > 0);
        switch (handler_ref.module) {
            inline else => {},
        }
    }
}

test "each declared handler module owns at least one public tool" {
    const fields = @typeInfo(handler_refs.HandlerModule).@"enum".fields;
    inline for (fields) |field| {
        const module: handler_refs.HandlerModule = @enumFromInt(field.value);
        var found = false;
        for (tool_manifest.entries) |entry| {
            if (handler_refs.handlerFor(entry.id).module == module) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "document change resolves to the change handler" {
    try std.testing.expectEqualStrings("zigDocumentChange", handler_refs.handlerFor(.zig_document_change).name);
}
