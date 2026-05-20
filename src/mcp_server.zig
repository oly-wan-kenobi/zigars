//! First-party MCP server adapter for zigar.
//!
//! zigar imports protocol data structures, JSON-RPC helpers, content types, and
//! transports from the pinned upstream MCP dependency. This module owns the
//! server-side routing boundary and the lifetime of zigar-owned results.
//! Tool/resource/prompt results stay alive until after the JSON-RPC response is
//! serialized, then registered deinitializers release owned allocations.

const std = @import("std");
const http = std.http;
const mcp = @import("mcp");

const jsonrpc = mcp.jsonrpc;
const protocol = mcp.protocol;
const types = mcp.types;
const transport_mod = mcp.transport;
const prompts_mod = mcp.prompts;
const resources_mod = mcp.resources;

pub const ToolResultDeinit = *const fn (allocator: std.mem.Allocator, result: mcp.tools.ToolResult) void;
pub const ResourceContentDeinit = *const fn (allocator: std.mem.Allocator, content: mcp.resources.ResourceContent) void;
pub const PromptMessagesDeinit = *const fn (allocator: std.mem.Allocator, messages: []const mcp.prompts.PromptMessage) void;

pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    title: ?[]const u8 = null,
    inputSchema: ?types.InputSchema = null,
    outputSchema: ?types.OutputSchema = null,
    execution: ?types.ToolExecution = null,
    icons: ?[]const types.Icon = null,
    annotations: ?mcp.tools.ToolAnnotations = null,
    handler: *const fn (user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, arguments: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult,
    deinit_result: ?ToolResultDeinit = null,
    user_data: ?*anyopaque = null,
};

const HttpRequestTransport = struct {
    response_message: ?[]const u8 = null,
    is_closed: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.response_message) |msg| {
            allocator.free(msg);
            self.response_message = null;
        }
    }

    pub fn send(self: *Self, _: std.Io, allocator: std.mem.Allocator, message: []const u8) transport_mod.Transport.SendError!void {
        if (self.is_closed) return transport_mod.Transport.SendError.ConnectionClosed;

        const owned = allocator.dupe(u8, message) catch return transport_mod.Transport.SendError.OutOfMemory;
        if (self.response_message) |old| {
            allocator.free(old);
        }
        self.response_message = owned;
    }

    pub fn receive(self: *Self, _: std.Io, _: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        if (self.is_closed) return transport_mod.Transport.ReceiveError.ConnectionClosed;
        return null;
    }

    pub fn close(self: *Self) void {
        self.is_closed = true;
    }

    pub fn transport(self: *Self) transport_mod.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
            },
        };
    }

    fn sendVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) transport_mod.Transport.SendError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.send(io, allocator, message);
    }

    fn receiveVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receive(io, allocator);
    }

    fn closeVtable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// Configuration for an MCP Server
pub const ServerConfig = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    icons: ?[]const types.Icon = null,
    websiteUrl: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
};

/// Current state of the server
pub const ServerState = enum {
    uninitialized,
    initializing,
    ready,
    shutting_down,
    stopped,
};

/// MCP Server that handles client connections and routes requests
pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    state: ServerState = .uninitialized,
    tools: std.StringHashMap(Tool),
    resources: std.StringHashMap(resources_mod.Resource),
    resource_content_deinits: std.StringHashMap(ResourceContentDeinit),
    resource_templates: std.StringHashMap(resources_mod.ResourceTemplate),
    prompts: std.StringHashMap(prompts_mod.Prompt),
    prompt_message_deinits: std.StringHashMap(PromptMessagesDeinit),
    capabilities: types.ServerCapabilities = .{},
    client_info: ?types.Implementation = null,
    client_capabilities: ?types.ClientCapabilities = null,
    transport: ?transport_mod.Transport = null,
    stdio_transport: ?*transport_mod.StdioTransport = null,
    next_request_id: i64 = 1,
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    log_level: protocol.LogLevel = .info,
    pub const max_http_body_size: usize = 4 * 1024 * 1024;

    const Self = @This();

    pub const PendingRequest = struct {
        method: []const u8,
        timestamp: i64,
    };

    /// Initialize a new MCP Server
    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .tools = .init(allocator),
            .resources = .init(allocator),
            .resource_content_deinits = .init(allocator),
            .resource_templates = .init(allocator),
            .prompts = .init(allocator),
            .prompt_message_deinits = .init(allocator),
            .pending_requests = .init(allocator),
        };
    }

    /// Clean up server resources
    pub fn deinit(self: *Self) void {
        if (self.stdio_transport) |stdio| {
            stdio.deinit(self.allocator);
            self.allocator.destroy(stdio);
            self.stdio_transport = null;
        }
        self.tools.deinit();
        self.resources.deinit();
        self.resource_content_deinits.deinit();
        self.resource_templates.deinit();
        self.prompts.deinit();
        self.prompt_message_deinits.deinit();
        self.pending_requests.deinit();
    }

    /// Add a tool to the server
    pub fn addTool(self: *Self, tool: Tool) !void {
        try self.tools.put(tool.name, tool);
        self.capabilities.tools = .{ .listChanged = true };
    }

    /// Add a resource to the server
    pub fn addResource(self: *Self, resource: resources_mod.Resource) !void {
        try self.resources.put(resource.uri, resource);
        self.capabilities.resources = .{ .listChanged = true, .subscribe = false };
    }

    /// Add a resource whose returned content follows a zigar-owned cleanup contract.
    pub fn addResourceWithDeinit(self: *Self, resource: resources_mod.Resource, deinit_content: ResourceContentDeinit) !void {
        errdefer _ = self.resources.remove(resource.uri);
        try self.addResource(resource);
        try self.resource_content_deinits.put(resource.uri, deinit_content);
    }

    /// Add a resource template to the server
    pub fn addResourceTemplate(self: *Self, template: resources_mod.ResourceTemplate) !void {
        try self.resource_templates.put(template.name, template);
        if (self.capabilities.resources == null) {
            self.capabilities.resources = .{};
        }
    }

    /// Add a prompt to the server
    pub fn addPrompt(self: *Self, prompt: prompts_mod.Prompt) !void {
        try self.prompts.put(prompt.name, prompt);
        self.capabilities.prompts = .{ .listChanged = true };
    }

    /// Add a prompt whose returned messages follow a zigar-owned cleanup contract.
    pub fn addPromptWithDeinit(self: *Self, prompt: prompts_mod.Prompt, deinit_messages: PromptMessagesDeinit) !void {
        errdefer _ = self.prompts.remove(prompt.name);
        try self.addPrompt(prompt);
        try self.prompt_message_deinits.put(prompt.name, deinit_messages);
    }

    /// Enable logging capability
    pub fn enableLogging(self: *Self) void {
        self.capabilities.logging = .{};
    }

    /// Enable completion capability
    pub fn enableCompletions(self: *Self) void {
        self.capabilities.completions = .{};
    }

    /// Options for running the server
    pub const HttpRunConfig = struct {
        port: u16 = 8080,
        host: []const u8 = "localhost",
    };

    pub const RunOptions = union(enum) {
        stdio: void,
        http: HttpRunConfig,
    };

    /// Run the server with the specified transport
    pub fn run(self: *Self, io: std.Io, allocator: std.mem.Allocator, options: RunOptions) !void {
        switch (options) {
            .stdio => {
                self.log(io, "Server listening on STDIO");
                const stdio = try allocator.create(transport_mod.StdioTransport);
                stdio.* = .{};
                self.stdio_transport = stdio;
                self.transport = stdio.transport();
                try self.messageLoop(io, allocator);
            },
            .http => |config| {
                try self.runHttp(io, allocator, config);
            },
        }
    }

    fn runHttp(self: *Self, io: std.Io, allocator: std.mem.Allocator, config: HttpRunConfig) !void {
        const bind_host = if (std.mem.eql(u8, config.host, "localhost")) "127.0.0.1" else config.host;

        const address = std.Io.net.IpAddress.resolve(io, bind_host, config.port) catch {
            return error.AddressResolutionError;
        };

        var listener = try std.Io.net.IpAddress.listen(&address, io, .{});
        defer listener.deinit(io);

        while (self.state != .stopped and self.state != .shutting_down) {
            const stream = listener.accept(io) catch |err| {
                std.log.err("HTTP accept failed: {s}", .{@errorName(err)});
                continue;
            };

            self.serveHttpConnection(io, allocator, stream) catch |err| {
                std.log.err("HTTP connection error: {s}", .{@errorName(err)});
            };
        }
    }

    fn serveHttpConnection(self: *Self, io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream) !void {
        defer stream.close(io);

        var send_buffer: [4096]u8 = undefined;
        var recv_buffer: [4096]u8 = undefined;
        var connection_reader = stream.reader(io, &recv_buffer);
        var connection_writer = stream.writer(io, &send_buffer);
        var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };

        if (request.head.method != .POST) {
            try request.respond("Method Not Allowed", .{
                .status = .method_not_allowed,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        try self.handleHttpJsonRpcRequest(io, allocator, &request);
    }

    fn handleHttpJsonRpcRequest(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: *http.Server.Request) !void {
        const content_length = request.head.content_length orelse {
            try request.respond("Content-Length required", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };

        if (content_length == 0) {
            try request.respond("Empty JSON-RPC payload", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        if (content_length > max_http_body_size) {
            try request.respond("Request body too large", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        var read_buffer: [2048]u8 = undefined;
        var body_reader = request.readerExpectContinue(&read_buffer) catch {
            try request.respond("Invalid request body", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };

        const read_len = std.math.cast(usize, content_length) orelse {
            try request.respond("Request body too large", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };

        const body_items = body_reader.readAlloc(allocator, read_len) catch {
            try request.respond("Failed to read request body", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };
        defer allocator.free(body_items);

        var request_transport: HttpRequestTransport = .{};
        defer request_transport.deinit(allocator);

        const previous_transport = self.transport;
        self.transport = request_transport.transport();
        defer self.transport = previous_transport;

        self.handleMessage(io, allocator, body_items) catch {
            const internal_error = jsonrpc.createParseError(.{ .string = "Internal server error" });
            const json = jsonrpc.serializeMessage(allocator, .{ .error_response = internal_error }) catch {
                try request.respond("Internal server error", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                });
                return;
            };
            defer allocator.free(json);

            try request.respond(json, .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
            return;
        };

        if (request_transport.response_message) |response_json| {
            try request.respond(response_json, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
            return;
        }

        try request.respond("", .{ .status = .no_content });
    }

    /// Run the server with a custom transport
    pub fn runWithTransport(self: *Self, io: std.Io, allocator: std.mem.Allocator, t: transport_mod.Transport) !void {
        self.transport = t;
        try self.messageLoop(io, allocator);
    }

    /// Main message processing loop
    fn messageLoop(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        while (self.state != .stopped and self.state != .shutting_down) {
            const message_data = self.transport.?.receive(io, allocator) catch |err| {
                switch (err) {
                    error.EndOfStream => {
                        self.state = .shutting_down;
                        break;
                    },
                    else => {
                        self.logError(io, "Transport receive error");
                        continue;
                    },
                }
            };

            if (message_data) |data| {
                try self.handleMessage(io, allocator, data);
            }
        }

        self.state = .stopped;
    }

    /// Handle an incoming message
    fn handleMessage(self: *Self, io: std.Io, allocator: std.mem.Allocator, data: []const u8) !void {
        const parsed_message = jsonrpc.parseMessage(allocator, data) catch {
            const error_response = jsonrpc.createParseError(null);
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        };
        defer parsed_message.deinit();

        switch (parsed_message.message) {
            .request => |req| try self.handleRequest(io, allocator, req),
            .notification => |notif| try self.handleNotification(io, notif),
            .response => |resp| self.handleResponse(resp),
            .error_response => |err| self.handleErrorResponse(io, err),
        }
    }

    /// Handle an incoming request
    fn handleRequest(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "Received request: {s}", .{request.method})) |msg| {
            self.log(io, msg);
        } else |_| {}

        if (self.state == .uninitialized and !std.mem.eql(u8, request.method, "initialize")) {
            const error_response = jsonrpc.createErrorResponse(
                request.id,
                jsonrpc.ErrorCode.SERVER_NOT_INITIALIZED,
                "Server not initialized",
                null,
            );
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        }

        if (std.mem.eql(u8, request.method, "initialize")) {
            try self.handleInitialize(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "ping")) {
            try self.handlePing(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tools/list")) {
            try self.handleToolsList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tools/call")) {
            try self.handleToolsCall(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/list")) {
            try self.handleResourcesList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/read")) {
            try self.handleResourcesRead(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/templates/list")) {
            try self.handleResourceTemplatesList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/subscribe")) {
            try self.handleSubscribe(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/unsubscribe")) {
            try self.handleUnsubscribe(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "prompts/list")) {
            try self.handlePromptsList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "prompts/get")) {
            try self.handlePromptsGet(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "logging/setLevel")) {
            try self.handleSetLogLevel(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "completion/complete")) {
            try self.handleCompletion(io, allocator, request);
        } else {
            const error_response = jsonrpc.createMethodNotFound(request.id, request.method);
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    fn handleInitialize(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        self.state = .initializing;
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        if (request.params) |params| {
            if (params == .object) {
                const obj = params.object;

                if (obj.get("clientInfo")) |client_info_val| {
                    if (client_info_val == .object) {
                        const ci = client_info_val.object;
                        self.client_info = .{
                            .name = if (ci.get("name")) |n| if (n == .string) n.string else "unknown" else "unknown",
                            .version = if (ci.get("version")) |v| if (v == .string) v.string else "0.0.0" else "0.0.0",
                        };
                    }
                }
            }
        }

        // use client's requested version if supported
        var negotiated_version: []const u8 = protocol.VERSION;
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("protocolVersion")) |pv| {
                    if (pv == .string) {
                        for (protocol.SUPPORTED_VERSIONS) |sv| {
                            if (std.mem.eql(u8, pv.string, sv)) {
                                negotiated_version = sv;
                                break;
                            }
                        }
                    }
                }
            }
        }

        var result: std.json.ObjectMap = .empty;

        try result.put(response_allocator, "protocolVersion", .{ .string = negotiated_version });

        var caps: std.json.ObjectMap = .empty;
        if (self.capabilities.tools) |t| {
            var tools_cap: std.json.ObjectMap = .empty;
            try tools_cap.put(response_allocator, "listChanged", .{ .bool = t.listChanged });
            try caps.put(response_allocator, "tools", .{ .object = tools_cap });
        }
        if (self.capabilities.resources) |r| {
            var res_cap: std.json.ObjectMap = .empty;
            try res_cap.put(response_allocator, "listChanged", .{ .bool = r.listChanged });
            try res_cap.put(response_allocator, "subscribe", .{ .bool = r.subscribe });
            try caps.put(response_allocator, "resources", .{ .object = res_cap });
        }
        if (self.capabilities.prompts) |p| {
            var prompts_cap: std.json.ObjectMap = .empty;
            try prompts_cap.put(response_allocator, "listChanged", .{ .bool = p.listChanged });
            try caps.put(response_allocator, "prompts", .{ .object = prompts_cap });
        }
        if (self.capabilities.logging != null) {
            try caps.put(response_allocator, "logging", .{ .object = .empty });
        }
        if (self.capabilities.completions != null) {
            try caps.put(response_allocator, "completions", .{ .object = .empty });
        }
        try result.put(response_allocator, "capabilities", .{ .object = caps });

        var server_info: std.json.ObjectMap = .empty;
        try server_info.put(response_allocator, "name", .{ .string = self.config.name });
        try server_info.put(response_allocator, "version", .{ .string = self.config.version });
        if (self.config.title) |t| {
            try server_info.put(response_allocator, "title", .{ .string = t });
        }
        if (self.config.description) |d| {
            try server_info.put(response_allocator, "description", .{ .string = d });
        }
        if (self.config.websiteUrl) |u| {
            try server_info.put(response_allocator, "websiteUrl", .{ .string = u });
        }
        try result.put(response_allocator, "serverInfo", .{ .object = server_info });

        if (self.config.instructions) |inst| {
            try result.put(response_allocator, "instructions", .{ .string = inst });
        }

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handlePing(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handleToolsList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var tools_array: std.json.Array = .init(response_allocator);

        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            var tool_obj: std.json.ObjectMap = .empty;
            try tool_obj.put(response_allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.description) |desc| {
                try tool_obj.put(response_allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.title) |t| {
                try tool_obj.put(response_allocator, "title", .{ .string = t });
            }

            var input_schema: std.json.ObjectMap = .empty;
            if (entry.value_ptr.inputSchema) |schema| {
                try input_schema.put(response_allocator, "type", .{ .string = schema.type });

                if (schema.@"$schema") |s| try input_schema.put(response_allocator, "$schema", .{ .string = s });
                if (schema.description) |d| try input_schema.put(response_allocator, "description", .{ .string = d });
                if (schema.properties) |p| try input_schema.put(response_allocator, "properties", p);

                if (schema.required) |req| {
                    var arr: std.json.Array = .init(response_allocator);
                    for (req) |name| try arr.append(.{ .string = name });
                    try input_schema.put(response_allocator, "required", .{ .array = arr });
                }
            } else {
                try input_schema.put(response_allocator, "type", .{ .string = "object" });
            }
            try tool_obj.put(response_allocator, "inputSchema", .{ .object = input_schema });

            if (entry.value_ptr.annotations) |ann| {
                var ann_obj: std.json.ObjectMap = .empty;
                if (ann.title) |t| try ann_obj.put(response_allocator, "title", .{ .string = t });
                try ann_obj.put(response_allocator, "readOnlyHint", .{ .bool = ann.readOnlyHint });
                try ann_obj.put(response_allocator, "destructiveHint", .{ .bool = ann.destructiveHint });
                try ann_obj.put(response_allocator, "idempotentHint", .{ .bool = ann.idempotentHint });
                try ann_obj.put(response_allocator, "openWorldHint", .{ .bool = ann.openWorldHint });
                try tool_obj.put(response_allocator, "annotations", .{ .object = ann_obj });
            }

            if (entry.value_ptr.execution) |exec| {
                var exec_obj: std.json.ObjectMap = .empty;
                if (exec.taskSupport) |ts| {
                    try exec_obj.put(response_allocator, "taskSupport", .{ .string = ts });
                }
                try tool_obj.put(response_allocator, "execution", .{ .object = exec_obj });
            }

            try tools_array.append(.{ .object = tool_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(response_allocator, "tools", .{ .array = tools_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handleToolsCall(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var tool_name: []const u8 = "";
        var arguments: ?std.json.Value = null;

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("name")) |name_val| {
                    if (name_val == .string) {
                        tool_name = name_val.string;
                    }
                }
                arguments = params.object.get("arguments");
            }
        }

        if (self.tools.get(tool_name)) |tool| {
            const tool_result = tool.handler(tool.user_data, io, allocator, arguments) catch |err| {
                var content_array: std.json.Array = .init(allocator);
                var content_array_in_result = false;
                defer if (!content_array_in_result) deinitBorrowedJsonContainers(allocator, .{ .array = content_array });
                try appendToolContentValue(allocator, &content_array, .{ .text = .{ .text = @errorName(err) } });

                var result: std.json.ObjectMap = .empty;
                defer deinitToolCallResponseObject(allocator, &result);
                try result.put(allocator, "content", .{ .array = content_array });
                content_array_in_result = true;
                try result.put(allocator, "isError", .{ .bool = true });

                const response = jsonrpc.createResponse(request.id, .{ .object = result });
                try self.sendResponse(io, allocator, .{ .response = response });
                return;
            };
            defer if (tool.deinit_result) |deinit_result| deinit_result(allocator, tool_result);

            var content_array: std.json.Array = .init(allocator);
            var content_array_in_result = false;
            defer if (!content_array_in_result) deinitBorrowedJsonContainers(allocator, .{ .array = content_array });
            for (tool_result.content) |content_item| {
                try appendToolContentValue(allocator, &content_array, content_item);
            }

            var result: std.json.ObjectMap = .empty;
            defer deinitToolCallResponseObject(allocator, &result);
            try result.put(allocator, "content", .{ .array = content_array });
            content_array_in_result = true;
            try result.put(allocator, "isError", .{ .bool = tool_result.is_error });
            if (tool_result.structuredContent) |sc| {
                try result.put(allocator, "structuredContent", sc);
            }

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Tool not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    fn appendToolContentValue(allocator: std.mem.Allocator, content_array: *std.json.Array, content_item: types.ContentBlock) !void {
        var item_obj: std.json.ObjectMap = .empty;
        var item_obj_in_array = false;
        errdefer if (!item_obj_in_array) deinitBorrowedJsonContainers(allocator, .{ .object = item_obj });

        switch (content_item) {
            .text => |text| {
                try item_obj.put(allocator, "type", .{ .string = "text" });
                try item_obj.put(allocator, "text", .{ .string = text.text });
            },
            .image => |img| {
                try item_obj.put(allocator, "type", .{ .string = "image" });
                try item_obj.put(allocator, "data", .{ .string = img.data });
                try item_obj.put(allocator, "mimeType", .{ .string = img.mimeType });
            },
            .audio => |aud| {
                try item_obj.put(allocator, "type", .{ .string = "audio" });
                try item_obj.put(allocator, "data", .{ .string = aud.data });
                try item_obj.put(allocator, "mimeType", .{ .string = aud.mimeType });
            },
            .resource_link => |link| {
                try item_obj.put(allocator, "type", .{ .string = "resource_link" });
                try item_obj.put(allocator, "uri", .{ .string = link.uri });
                try item_obj.put(allocator, "name", .{ .string = link.name });
                if (link.title) |t| try item_obj.put(allocator, "title", .{ .string = t });
                if (link.description) |d| try item_obj.put(allocator, "description", .{ .string = d });
                if (link.mimeType) |m| try item_obj.put(allocator, "mimeType", .{ .string = m });
            },
            .resource => |res| {
                try item_obj.put(allocator, "type", .{ .string = "resource" });
                var res_obj: std.json.ObjectMap = .empty;
                var res_obj_in_item = false;
                errdefer if (!res_obj_in_item) res_obj.deinit(allocator);
                try res_obj.put(allocator, "uri", .{ .string = res.resource.uri });
                if (res.resource.text) |text| try res_obj.put(allocator, "text", .{ .string = text });
                if (res.resource.mimeType) |mime| try res_obj.put(allocator, "mimeType", .{ .string = mime });
                try item_obj.put(allocator, "resource", .{ .object = res_obj });
                res_obj_in_item = true;
            },
        }

        try content_array.append(.{ .object = item_obj });
        item_obj_in_array = true;
    }

    fn deinitToolCallResponseObject(allocator: std.mem.Allocator, result: *std.json.ObjectMap) void {
        var it = result.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "structuredContent")) continue;
            deinitBorrowedJsonContainers(allocator, entry.value_ptr.*);
        }
        result.deinit(allocator);
    }

    fn deinitBorrowedJsonContainers(allocator: std.mem.Allocator, value: std.json.Value) void {
        switch (value) {
            .array => |array| {
                var mutable = array;
                for (mutable.items) |item| deinitBorrowedJsonContainers(allocator, item);
                mutable.deinit();
            },
            .object => |object| {
                var mutable = object;
                var it = mutable.iterator();
                while (it.next()) |entry| deinitBorrowedJsonContainers(allocator, entry.value_ptr.*);
                mutable.deinit(allocator);
            },
            else => {},
        }
    }

    fn handleResourcesList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var resources_array: std.json.Array = .init(response_allocator);

        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            var resource_obj: std.json.ObjectMap = .empty;
            try resource_obj.put(response_allocator, "uri", .{ .string = entry.value_ptr.uri });
            try resource_obj.put(response_allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.title) |t| {
                try resource_obj.put(response_allocator, "title", .{ .string = t });
            }
            if (entry.value_ptr.description) |desc| {
                try resource_obj.put(response_allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.mimeType) |mime| {
                try resource_obj.put(response_allocator, "mimeType", .{ .string = mime });
            }
            if (entry.value_ptr.size) |s| {
                try resource_obj.put(response_allocator, "size", .{ .integer = @intCast(s) });
            }
            try resources_array.append(.{ .object = resource_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(response_allocator, "resources", .{ .array = resources_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handleResourcesRead(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var uri: []const u8 = "";

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("uri")) |uri_val| {
                    if (uri_val == .string) {
                        uri = uri_val.string;
                    }
                }
            }
        }

        if (self.resources.get(uri)) |resource| {
            const content = resource.handler(resource.user_data, io, allocator, uri) catch |err| {
                const error_response = jsonrpc.createInternalError(request.id, .{ .string = @errorName(err) });
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            };
            defer if (self.resource_content_deinits.get(uri)) |deinit_content| deinit_content(allocator, content);

            var contents_array: std.json.Array = .init(allocator);
            var contents_array_in_result = false;
            defer if (!contents_array_in_result) deinitBorrowedJsonContainers(allocator, .{ .array = contents_array });
            var content_obj: std.json.ObjectMap = .empty;
            var content_obj_in_array = false;
            errdefer if (!content_obj_in_array) deinitBorrowedJsonContainers(allocator, .{ .object = content_obj });
            try content_obj.put(allocator, "uri", .{ .string = uri });
            if (content.text) |text| {
                try content_obj.put(allocator, "text", .{ .string = text });
            }
            if (content.blob) |blob| {
                try content_obj.put(allocator, "blob", .{ .string = blob });
            }
            if (content.mimeType) |mime| {
                try content_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            try contents_array.append(.{ .object = content_obj });
            content_obj_in_array = true;

            var result: std.json.ObjectMap = .empty;
            defer deinitBorrowedJsonContainers(allocator, .{ .object = result });
            try result.put(allocator, "contents", .{ .array = contents_array });
            contents_array_in_result = true;

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Resource not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    fn handleResourceTemplatesList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var templates_array: std.json.Array = .init(response_allocator);

        var iter = self.resource_templates.iterator();
        while (iter.next()) |entry| {
            var template_obj: std.json.ObjectMap = .empty;
            try template_obj.put(response_allocator, "uriTemplate", .{ .string = entry.value_ptr.uriTemplate });
            try template_obj.put(response_allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.title) |t| {
                try template_obj.put(response_allocator, "title", .{ .string = t });
            }
            if (entry.value_ptr.description) |desc| {
                try template_obj.put(response_allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.mimeType) |mime| {
                try template_obj.put(response_allocator, "mimeType", .{ .string = mime });
            }
            try templates_array.append(.{ .object = template_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(response_allocator, "resourceTemplates", .{ .array = templates_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handleSubscribe(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        _ = request.params;
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handleUnsubscribe(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        _ = request.params;
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handlePromptsList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var prompts_array: std.json.Array = .init(response_allocator);

        var iter = self.prompts.iterator();
        while (iter.next()) |entry| {
            var prompt_obj: std.json.ObjectMap = .empty;
            try prompt_obj.put(response_allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.description) |desc| {
                try prompt_obj.put(response_allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.title) |t| {
                try prompt_obj.put(response_allocator, "title", .{ .string = t });
            }

            if (entry.value_ptr.arguments) |args| {
                var args_array: std.json.Array = .init(response_allocator);
                for (args) |arg| {
                    var arg_obj: std.json.ObjectMap = .empty;
                    try arg_obj.put(response_allocator, "name", .{ .string = arg.name });
                    if (arg.title) |t| {
                        try arg_obj.put(response_allocator, "title", .{ .string = t });
                    }
                    if (arg.description) |d| {
                        try arg_obj.put(response_allocator, "description", .{ .string = d });
                    }
                    try arg_obj.put(response_allocator, "required", .{ .bool = arg.required });
                    try args_array.append(.{ .object = arg_obj });
                }
                try prompt_obj.put(response_allocator, "arguments", .{ .array = args_array });
            }

            try prompts_array.append(.{ .object = prompt_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(response_allocator, "prompts", .{ .array = prompts_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handlePromptsGet(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var prompt_name: []const u8 = "";
        var arguments: ?std.json.Value = null;

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("name")) |name_val| {
                    if (name_val == .string) {
                        prompt_name = name_val.string;
                    }
                }
                arguments = params.object.get("arguments");
            }
        }

        if (self.prompts.get(prompt_name)) |prompt| {
            const messages = prompt.handler(prompt.user_data, io, allocator, arguments) catch |err| {
                const error_response = jsonrpc.createInternalError(request.id, .{ .string = @errorName(err) });
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            };
            defer if (self.prompt_message_deinits.get(prompt_name)) |deinit_messages| deinit_messages(allocator, messages);

            var messages_array: std.json.Array = .init(allocator);
            var messages_array_in_result = false;
            defer if (!messages_array_in_result) deinitBorrowedJsonContainers(allocator, .{ .array = messages_array });
            for (messages) |msg| {
                var msg_obj: std.json.ObjectMap = .empty;
                var msg_obj_in_array = false;
                errdefer if (!msg_obj_in_array) deinitBorrowedJsonContainers(allocator, .{ .object = msg_obj });
                try msg_obj.put(allocator, "role", .{ .string = msg.role.toString() });
                var content_obj: std.json.ObjectMap = .empty;
                var content_obj_in_msg = false;
                errdefer if (!content_obj_in_msg) deinitBorrowedJsonContainers(allocator, .{ .object = content_obj });
                switch (msg.content) {
                    .text => |text| {
                        try content_obj.put(allocator, "type", .{ .string = "text" });
                        try content_obj.put(allocator, "text", .{ .string = text.text });
                    },
                    .image => |img| {
                        try content_obj.put(allocator, "type", .{ .string = "image" });
                        try content_obj.put(allocator, "data", .{ .string = img.data });
                        try content_obj.put(allocator, "mimeType", .{ .string = img.mimeType });
                    },
                    .audio => |aud| {
                        try content_obj.put(allocator, "type", .{ .string = "audio" });
                        try content_obj.put(allocator, "data", .{ .string = aud.data });
                        try content_obj.put(allocator, "mimeType", .{ .string = aud.mimeType });
                    },
                    .resource_link => |link| {
                        try content_obj.put(allocator, "type", .{ .string = "resource_link" });
                        try content_obj.put(allocator, "uri", .{ .string = link.uri });
                        try content_obj.put(allocator, "name", .{ .string = link.name });
                    },
                    .resource => |res| {
                        try content_obj.put(allocator, "type", .{ .string = "resource" });
                        var res_inner: std.json.ObjectMap = .empty;
                        var res_inner_in_content = false;
                        errdefer if (!res_inner_in_content) deinitBorrowedJsonContainers(allocator, .{ .object = res_inner });
                        try res_inner.put(allocator, "uri", .{ .string = res.resource.uri });
                        if (res.resource.text) |text| try res_inner.put(allocator, "text", .{ .string = text });
                        try content_obj.put(allocator, "resource", .{ .object = res_inner });
                        res_inner_in_content = true;
                    },
                }
                try msg_obj.put(allocator, "content", .{ .object = content_obj });
                content_obj_in_msg = true;
                try messages_array.append(.{ .object = msg_obj });
                msg_obj_in_array = true;
            }

            var result: std.json.ObjectMap = .empty;
            defer deinitBorrowedJsonContainers(allocator, .{ .object = result });
            try result.put(allocator, "messages", .{ .array = messages_array });
            messages_array_in_result = true;
            if (prompt.description) |desc| {
                try result.put(allocator, "description", .{ .string = desc });
            }

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Prompt not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    fn handleSetLogLevel(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("level")) |level_val| {
                    if (level_val == .string) {
                        const level_str = level_val.string;
                        if (std.mem.eql(u8, level_str, "debug")) {
                            self.log_level = .debug;
                        } else if (std.mem.eql(u8, level_str, "info")) {
                            self.log_level = .info;
                        } else if (std.mem.eql(u8, level_str, "notice")) {
                            self.log_level = .notice;
                        } else if (std.mem.eql(u8, level_str, "warning")) {
                            self.log_level = .warning;
                        } else if (std.mem.eql(u8, level_str, "error")) {
                            self.log_level = .@"error";
                        } else if (std.mem.eql(u8, level_str, "critical")) {
                            self.log_level = .critical;
                        } else if (std.mem.eql(u8, level_str, "alert")) {
                            self.log_level = .alert;
                        } else if (std.mem.eql(u8, level_str, "emergency")) {
                            self.log_level = .emergency;
                        }
                    }
                }
            }
        }

        const result: std.json.ObjectMap = .empty;
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handleCompletion(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var completion: std.json.ObjectMap = .empty;
        const values_array: std.json.Array = .init(response_allocator);
        try completion.put(response_allocator, "values", .{ .array = values_array });
        try completion.put(response_allocator, "hasMore", .{ .bool = false });

        var result: std.json.ObjectMap = .empty;
        try result.put(response_allocator, "completion", .{ .object = completion });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handleNotification(self: *Self, io: std.Io, notification: jsonrpc.Notification) !void {
        if (std.mem.eql(u8, notification.method, "notifications/initialized")) {
            self.state = .ready;
            self.log(io, "Server initialized and ready");
        } else if (std.mem.eql(u8, notification.method, "notifications/cancelled")) {
            if (notification.params) |params| {
                if (params == .object) {
                    if (params.object.get("requestId")) |req_id| {
                        _ = req_id;
                    }
                }
            }
        } else if (std.mem.eql(u8, notification.method, "notifications/roots/list_changed")) {
            self.log(io, "Roots list changed");
        }
    }

    fn handleResponse(self: *Self, response: jsonrpc.Response) void {
        const id = switch (response.id) {
            .integer => |i| i,
            .string => return,
        };
        _ = self.pending_requests.remove(id);
    }

    fn handleErrorResponse(self: *Self, io: std.Io, err: jsonrpc.ErrorResponse) void {
        if (err.id) |id| {
            const int_id = switch (id) {
                .integer => |i| i,
                .string => return,
            };
            _ = self.pending_requests.remove(int_id);
        }
        self.logError(io, err.@"error".message);
    }

    pub fn sendNotification(self: *Self, io: std.Io, allocator: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !void {
        const notification = jsonrpc.createNotification(method, params);
        try self.sendResponse(io, allocator, .{ .notification = notification });
    }

    pub fn sendLogMessage(self: *Self, io: std.Io, allocator: std.mem.Allocator, level: protocol.LogLevel, message: []const u8) !void {
        if (@intFromEnum(level) < @intFromEnum(self.log_level)) return;

        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var params: std.json.ObjectMap = .empty;
        try params.put(response_allocator, "level", .{ .string = level.toString() });
        try params.put(response_allocator, "data", .{ .string = message });

        try self.sendNotification(io, allocator, "notifications/message", .{ .object = params });
    }

    pub fn sendProgress(self: *Self, io: std.Io, allocator: std.mem.Allocator, token: std.json.Value, prog: f64, total: ?f64, message: ?[]const u8) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var params: std.json.ObjectMap = .empty;
        try params.put(response_allocator, "progressToken", token);
        try params.put(response_allocator, "progress", .{ .float = prog });
        if (total) |t| {
            try params.put(response_allocator, "total", .{ .float = t });
        }
        if (message) |m| {
            try params.put(response_allocator, "message", .{ .string = m });
        }
        try self.sendNotification(io, allocator, "notifications/progress", .{ .object = params });
    }

    pub fn notifyToolsChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/tools/list_changed", null);
    }

    pub fn notifyResourcesChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/resources/list_changed", null);
    }

    pub fn notifyResourceUpdated(self: *Self, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var params: std.json.ObjectMap = .empty;
        try params.put(response_allocator, "uri", .{ .string = uri });
        try self.sendNotification(io, allocator, "notifications/resources/updated", .{ .object = params });
    }

    pub fn notifyPromptsChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/prompts/list_changed", null);
    }

    fn sendResponse(self: *Self, io: std.Io, allocator: std.mem.Allocator, message: jsonrpc.Message) !void {
        if (self.transport) |t| {
            const json = jsonrpc.serializeMessage(allocator, message) catch {
                self.logError(io, "Failed to serialize response");
                return;
            };
            defer allocator.free(json);
            t.send(io, allocator, json) catch {
                self.logError(io, "Failed to send response");
                return;
            };
        }
    }

    fn log(self: *Self, io: std.Io, message: []const u8) void {
        if (self.stdio_transport) |t| {
            t.writeStderr(io, message);
        }
    }

    fn logError(self: *Self, io: std.Io, message: []const u8) void {
        if (self.stdio_transport) |t| {
            var buf: [512]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "ERROR: {s}", .{message}) catch message;
            t.writeStderr(io, formatted);
        }
    }
};
