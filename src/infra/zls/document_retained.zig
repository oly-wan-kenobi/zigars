//! Retained in-memory document byte accounting for the document lifecycle.
//!
//! These helpers track and bound the bytes held for unsaved (dirty) documents.
//! They live beside `documents.zig` so the retained-content policy can be
//! audited and tested on its own without enlarging the lifecycle module. They
//! operate on caller-supplied primitives (the retained-byte counter and raw
//! content slices) so this stays a leaf module with no dependency on the
//! lifecycle module's types; ownership and locking remain the caller's
//! responsibility.
const std = @import("std");

/// Calculates the byte length of cached document content.
pub fn contentLen(content: ?[]const u8) usize {
    return if (content) |bytes| bytes.len else 0;
}

/// Computes retained cache bytes after replacing one document body.
pub fn retainedBytesAfterReplace(retained: usize, old_len: usize, new_len: usize) ?usize {
    if (old_len > retained) return null;
    return std.math.add(usize, retained - old_len, new_len) catch null;
}

/// Subtracts retained document bytes, clamping at zero while the mutex is held.
/// Mirrors `diagnostics_cache.subtractBytesLocked` so an accounting desync can
/// never wrap to ~usize.MAX and spuriously trip RetainedContentLimitExceeded.
pub fn subtractRetainedBytesLocked(retained_content_bytes: *usize, bytes: usize) void {
    if (bytes <= retained_content_bytes.*) {
        retained_content_bytes.* -= bytes;
    } else {
        retained_content_bytes.* = 0;
    }
}
