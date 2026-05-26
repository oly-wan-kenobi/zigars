pub fn run(client: anytype) !void {
    const pack = try client.callTool("zigar_adoption_pack", "{\"client\":\"codex\",\"backend\":\"zflame\"}");
    defer client.allocator.free(pack);
    try client.expectPathString(pack, "kind", "zigar_adoption_pack");
    try client.expectPathString(pack, "client_identity.client", "codex");
    try client.expectPathString(pack, "backend_setup_status.0.backend", "zflame");

    const config = try client.callTool("zigar_client_config_generate", "{\"client\":\"codex\",\"kind\":\"codex-toml\",\"output\":\".zigar-cache/adoption/stdio-codex.toml\",\"apply\":false}");
    defer client.allocator.free(config);
    try client.expectPathString(config, "kind", "zigar_client_config_generate");
    try client.expectPathJson(config, "applied", .{ .bool = false });
    try client.expectPathString(config, "artifact_identity.path", ".zigar-cache/adoption/stdio-codex.toml");

    const smoke = try client.callTool("zigar_smoke_plan", "{\"backend\":\"zflame\",\"platform\":\"linux\",\"timeout_ms\":1000}");
    defer client.allocator.free(smoke);
    try client.expectPathString(smoke, "kind", "zigar_smoke_plan");
    try client.expectPathString(smoke, "scenarios.8.id", "backend_verify");

    const report = try client.callTool("zigar_conformance_report", "{\"content\":\"{\\\"kind\\\":\\\"zigar_backend_conformance_report\\\",\\\"compatibility_matrix\\\":[{\\\"backend\\\":\\\"zflame\\\",\\\"status\\\":\\\"passed\\\"}]}\"}");
    defer client.allocator.free(report);
    try client.expectPathString(report, "kind", "zigar_conformance_report");
    try client.expectPathJson(report, "report.source.available", .{ .bool = true });
    try client.expectPathJson(report, "report.backend_support_claims.4.claim_allowed", .{ .bool = true });
}

test "stdio adoption fixture exposes run entrypoint" {
    try @import("std").testing.expect(@hasDecl(@This(), "run"));
}
