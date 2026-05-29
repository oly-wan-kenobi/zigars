const std = @import("std");
const documents = @import("documents.zig");
const document_retained = @import("document_retained.zig");

const DocumentState = documents.DocumentState;

test "DocumentState retained-byte subtraction clamps at zero on accounting desync" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();

    // Simulate a desync: a tracked document holds more bytes than the retained
    // counter believes. The pre-fix raw `-=` underflows (panic in safe builds /
    // wrap to ~usize.MAX) and would spuriously trip RetainedContentLimitExceeded.
    // This mirrors the rollback paths (removeReserved/restoreDoc) that subtract a
    // tracked body's `contentLen` from a counter that was under-counted.
    const uri = try alloc.dupe(u8, "file:///tmp/main.zig");
    const content = try alloc.dupe(u8, "12345678"); // 8 bytes
    try ds.open_docs.put(alloc, uri, .{ .version = 1, .content_hash = 1, .dirty = true, .content = content });
    ds.retained_content_bytes = 3; // under-counted vs the 8-byte body

    const info = ds.open_docs.get("file:///tmp/main.zig") orelse return error.TestUnexpectedResult;
    document_retained.subtractRetainedBytesLocked(&ds, document_retained.contentLen(info));

    try std.testing.expectEqual(@as(usize, 0), ds.retained_content_bytes);
}

test "DocumentState subtractRetainedBytesLocked never underflows" {
    const alloc = std.testing.allocator;
    var ds = DocumentState.init(alloc, "/tmp");
    defer ds.deinit();

    ds.retained_content_bytes = 10;
    document_retained.subtractRetainedBytesLocked(&ds, 4);
    try std.testing.expectEqual(@as(usize, 6), ds.retained_content_bytes);
    // Over-subtraction clamps to zero rather than wrapping.
    document_retained.subtractRetainedBytesLocked(&ds, 100);
    try std.testing.expectEqual(@as(usize, 0), ds.retained_content_bytes);
}

test "DocumentState retainedBytesAfterReplace rejects under-counted replacements" {
    // Replacing a body whose old length exceeds the tracked counter signals an
    // accounting desync (null) rather than wrapping; a valid replacement returns
    // the adjusted total.
    try std.testing.expectEqual(@as(?usize, null), document_retained.retainedBytesAfterReplace(3, 8, 4));
    try std.testing.expectEqual(@as(?usize, 6), document_retained.retainedBytesAfterReplace(5, 3, 4));
}
