const std = @import("std");

const runtime_mod = @import("../runtime.zig");
const uri_util = @import("../types/uri.zig");
const DocumentState = @import("../state/documents.zig").DocumentState;
const LspClient = @import("../lsp/client.zig").LspClient;
const ZlsProcess = @import("process.zig").ZlsProcess;

const App = runtime_mod.App;

pub fn clear(runtime: *App) void {
    runtime.zls_process = null;
    runtime.lsp_client = null;
    runtime.doc_state = null;
}

pub fn start(runtime: *App, proc_slot: *?ZlsProcess, client_slot: *?LspClient, docs_slot: *?DocumentState) !void {
    clear(runtime);
    proc_slot.* = ZlsProcess.init(runtime.allocator, runtime.io, runtime.workspace.root, runtime.config.zls_path);
    errdefer {
        if (proc_slot.*) |*proc| proc.deinit();
        proc_slot.* = null;
    }
    try proc_slot.*.?.spawn();

    const stdin = proc_slot.*.?.getStdin() orelse return error.ZlsPipeUnavailable;
    const stdout = proc_slot.*.?.getStdout() orelse return error.ZlsPipeUnavailable;
    const stderr = proc_slot.*.?.getStderr();

    client_slot.* = LspClient.initWithTimeout(runtime.allocator, runtime.io, runtime.config.zls_timeout_ms);
    client_slot.*.?.setLogger(runtime.logger);
    errdefer {
        if (client_slot.*) |*client| client.deinit();
        client_slot.* = null;
    }
    try client_slot.*.?.connect(stdin, stdout, stderr);
    proc_slot.*.?.detachPipes();

    const workspace_uri = try uri_util.pathToUri(runtime.allocator, runtime.workspace.root);
    defer runtime.allocator.free(workspace_uri);
    const response = try client_slot.*.?.initialize(runtime.allocator, workspace_uri);
    defer runtime.allocator.free(response);
    runtime.zls_initialize_response = try runtime.allocator.dupe(u8, response);

    const replay_existing_documents = docs_slot.* != null;
    if (docs_slot.* == null) {
        docs_slot.* = DocumentState.initWithIo(runtime.allocator, runtime.workspace.root, runtime.io);
    }
    docs_slot.*.?.setLogger(runtime.logger);

    runtime.zls_process = &(proc_slot.*.?);
    runtime.lsp_client = &(client_slot.*.?);
    runtime.doc_state = &(docs_slot.*.?);
    runtime.zls_status = "connected";

    if (replay_existing_documents) {
        _ = docs_slot.*.?.reopenAll(&(client_slot.*.?));
    }
}

pub fn restart(runtime: *App) !void {
    const proc_slot = runtime.zls_process_slot orelse return error.NotConnected;
    const client_slot = runtime.lsp_client_slot orelse return error.NotConnected;
    const docs_slot = runtime.doc_state_slot orelse return error.NotConnected;

    if (client_slot.*) |*client| client.deinit();
    client_slot.* = null;
    if (proc_slot.*) |*proc| proc.deinit();
    proc_slot.* = null;

    clear(runtime);
    runtime.zls_status = "restarting";
    runtime.zls_restart_attempts += 1;
    start(runtime, proc_slot, client_slot, docs_slot) catch |err| {
        runtime.zls_status = @errorName(err);
        runtime.zls_last_failure = @errorName(err);
        return err;
    };
}

pub fn ensureReady(runtime: *App) !void {
    if (runtime.lsp_client) |client| {
        if (client.isRunning()) return;
    }
    try restart(runtime);
}
