//! Retained in-memory document byte accounting for `DocumentState`.
//!
//! These helpers track and bound the bytes held for unsaved (dirty) documents.
//! They live beside the document lifecycle code in `documents.zig` so the
//! retained-content policy can be audited and tested on its own without
//! enlarging the lifecycle module. The functions operate on `DocumentState`
//! values supplied by the caller; ownership and locking remain the lifecycle
//! module's responsibility.
const std = @import("std");
const documents = @import("documents.zig");

const DocumentState = documents.DocumentState;
const DocInfo = DocumentState.DocInfo;

/// Calculates the byte length of cached document content.
pub fn contentLen(info: DocInfo) usize {
    return if (info.content) |content| content.len else 0;
}

/// Computes retained cache bytes after replacing one document body.
pub fn retainedBytesAfterReplace(retained: usize, old_len: usize, new_len: usize) ?usize {
    if (old_len > retained) return null;
    return std.math.add(usize, retained - old_len, new_len) catch null;
}

/// Subtracts retained document bytes, clamping at zero while the mutex is held.
/// Mirrors `diagnostics_cache.subtractBytesLocked` so an accounting desync can
/// never wrap to ~usize.MAX and spuriously trip RetainedContentLimitExceeded.
pub fn subtractRetainedBytesLocked(self: *DocumentState, bytes: usize) void {
    if (bytes <= self.retained_content_bytes) {
        self.retained_content_bytes -= bytes;
    } else {
        self.retained_content_bytes = 0;
    }
}
