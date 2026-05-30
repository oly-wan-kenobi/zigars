//! Public surface and test runner for the ZLS infrastructure subsystem.
//! Re-exports all production modules and pulls in their paired test files.
pub const client = @import("client.zig");
pub const diagnostics_cache = @import("diagnostics_cache.zig");
pub const documents = @import("documents.zig");
pub const document_retained = @import("document_retained.zig");
pub const gateway = @import("gateway.zig");
pub const json_rpc = @import("json_rpc.zig");
pub const process = @import("process.zig");
pub const session = @import("session.zig");
pub const transport = @import("transport.zig");
pub const types = @import("types.zig");
pub const uri = @import("uri.zig");

const diagnostics_cache_tests = @import("diagnostics_cache_tests.zig");
const client_internal_tests = @import("client_internal_tests.zig");
const gateway_tests = @import("gateway_tests.zig");
const json_rpc_tests = @import("json_rpc_tests.zig");
const process_tests = @import("process_tests.zig");
const session_tests = @import("session_tests.zig");
const transport_tests = @import("transport_tests.zig");
const types_tests = @import("types_tests.zig");
const uri_tests = @import("uri_tests.zig");

test {
    _ = client;
    _ = diagnostics_cache;
    _ = documents;
    _ = document_retained;
    _ = gateway;
    _ = json_rpc;
    _ = process;
    _ = session;
    _ = transport;
    _ = types;
    _ = uri;
    _ = client_internal_tests;
    _ = diagnostics_cache_tests;
    _ = gateway_tests;
    _ = json_rpc_tests;
    _ = process_tests;
    _ = session_tests;
    _ = transport_tests;
    _ = types_tests;
    _ = uri_tests;
}
