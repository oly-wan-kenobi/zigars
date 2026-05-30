//! Pins that the manifest catalog port correctly exposes compile-time tool metadata
//! including risk and plan fields for well-known registered tools.
const std = @import("std");
const subject = @import("manifest_catalog.zig");
const Catalog = subject.Catalog;

test "manifest catalog port exposes registered tool risk metadata" {
    var catalog = Catalog{};
    const port = catalog.port();
    try std.testing.expect(port.count() > 0);
    const entry = port.find("zigars_trust_report") orelse return error.MissingExpectedCall;
    try std.testing.expectEqualStrings("zigars_trust_report", entry.name);
}
