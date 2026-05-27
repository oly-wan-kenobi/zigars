const std = @import("std");
const config_mod = @import("config.zig");
const App = @import("runtime_state.zig").App;
const LspClient = @import("../infra/zls/client.zig").LspClient;
const DocumentState = @import("../infra/zls/documents.zig").DocumentState;
const ZlsProcess = @import("../infra/zls/process.zig").ZlsProcess;

test "bootstrap runtime wires runtime lifecycle types" {
    try std.testing.expect(@sizeOf(App) > 0);
    try std.testing.expect(@sizeOf(LspClient) > 0);
    try std.testing.expect(@sizeOf(DocumentState) > 0);
    try std.testing.expect(@sizeOf(ZlsProcess) > 0);
    try std.testing.expect(std.mem.indexOf(u8, config_mod.usage(), "zigars") != null);
}
