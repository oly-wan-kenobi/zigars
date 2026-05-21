//! First-party MCP server adapter for zigar.
//! Owns routing and zigar result lifetimes over the pinned upstream MCP dependency.

const std = @import("std");
const http = std.http;
const mcp = @import("mcp");

const jsonrpc = mcp.jsonrpc;
const protocol = mcp.protocol;
const types = mcp.types;
const transport_mod = mcp.transport;
const prompts_mod = mcp.prompts;
const resources_mod = mcp.resources;
const HttpRequestTransport = @import("mcp_server/http_transport.zig").HttpRequestTransport;
const completion_ext = @import("mcp_server/completion.zig");
const json_helpers = @import("mcp_server/json_helpers.zig");
const pagination = @import("mcp_server/pagination.zig");
const resource_subscriptions = @import("mcp_server/resource_subscriptions.zig");
const tasks_ext = @import("mcp_server/tasks.zig");
const runtime_ux = @import("runtime_ux.zig");
const tool_errors = @import("tool_errors.zig");

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

pub const DynamicResourceHandler = *const fn (user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent;

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
    tools: std.StringArrayHashMapUnmanaged(Tool),
    resources: std.StringArrayHashMapUnmanaged(resources_mod.Resource),
    resource_content_deinits: std.StringHashMap(ResourceContentDeinit),
    resource_templates: std.StringArrayHashMapUnmanaged(resources_mod.ResourceTemplate),
    prompts: std.StringArrayHashMapUnmanaged(prompts_mod.Prompt),
    prompt_message_deinits: std.StringHashMap(PromptMessagesDeinit),
    dynamic_resource_handler: ?DynamicResourceHandler = null,
    dynamic_resource_deinit: ?ResourceContentDeinit = null,
    dynamic_resource_user_data: ?*anyopaque = null,
    task_state: ?*runtime_ux.State = null,
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
            .tools = .empty,
            .resources = .empty,
            .resource_content_deinits = .init(allocator),
            .resource_templates = .empty,
            .prompts = .empty,
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
        self.tools.deinit(self.allocator);
        self.resources.deinit(self.allocator);
        self.resource_content_deinits.deinit();
        self.resource_templates.deinit(self.allocator);
        self.prompts.deinit(self.allocator);
        self.prompt_message_deinits.deinit();
        self.pending_requests.deinit();
    }

    /// Add a tool to the server
    pub fn addTool(self: *Self, tool: Tool) !void {
        try self.tools.put(self.allocator, tool.name, tool);
        self.capabilities.tools = .{ .listChanged = true };
    }

    /// Add a resource to the server
    pub fn addResource(self: *Self, resource: resources_mod.Resource) !void {
        try self.resources.put(self.allocator, resource.uri, resource);
        const subscribe = if (self.capabilities.resources) |cap| cap.subscribe else false;
        self.capabilities.resources = .{ .listChanged = true, .subscribe = subscribe };
    }

    /// Add a resource whose returned content follows a zigar-owned cleanup contract.
    pub fn addResourceWithDeinit(self: *Self, resource: resources_mod.Resource, deinit_content: ResourceContentDeinit) !void {
        try self.addResource(resource);
        errdefer _ = self.resources.orderedRemove(resource.uri);
        try self.resource_content_deinits.put(resource.uri, deinit_content);
    }

    /// Add a resource template to the server
    pub fn addResourceTemplate(self: *Self, template: resources_mod.ResourceTemplate) !void {
        try self.resource_templates.put(self.allocator, template.name, template);
        if (self.capabilities.resources == null) {
            self.capabilities.resources = .{ .listChanged = true };
        }
    }

    /// Add a prompt to the server
    pub fn addPrompt(self: *Self, prompt: prompts_mod.Prompt) !void {
        try self.prompts.put(self.allocator, prompt.name, prompt);
        self.capabilities.prompts = .{ .listChanged = true };
    }

    /// Add a prompt whose returned messages follow a zigar-owned cleanup contract.
    pub fn addPromptWithDeinit(self: *Self, prompt: prompts_mod.Prompt, deinit_messages: PromptMessagesDeinit) !void {
        try self.addPrompt(prompt);
        errdefer _ = self.prompts.orderedRemove(prompt.name);
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

    /// Enable resource subscription acknowledgement.
    pub fn enableResourceSubscriptions(self: *Self) void {
        const list_changed = if (self.capabilities.resources) |cap| cap.listChanged else false;
        self.capabilities.resources = .{ .listChanged = list_changed, .subscribe = true };
    }

    /// Enable task-augmented tools/call support backed by zigar runtime jobs.
    pub fn enableTasks(self: *Self, state: *runtime_ux.State) void {
        self.task_state = state;
        self.capabilities.tasks = .{
            .list = .{},
            .cancel = .{},
            .requests = .{
                .tools = .{ .call = .{} },
            },
        };
    }

    /// Register a fallback resource handler for template-backed dynamic URIs.
    pub fn setDynamicResourceHandler(self: *Self, handler: DynamicResourceHandler, user_data: ?*anyopaque, deinit_content: ?ResourceContentDeinit) void {
        self.dynamic_resource_handler = handler;
        self.dynamic_resource_user_data = user_data;
        self.dynamic_resource_deinit = deinit_content;
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
            try resource_subscriptions.handleSubscribe(self, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/unsubscribe")) {
            try resource_subscriptions.handleUnsubscribe(self, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "prompts/list")) {
            try self.handlePromptsList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "prompts/get")) {
            try self.handlePromptsGet(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "logging/setLevel")) {
            try self.handleSetLogLevel(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "completion/complete")) {
            try completion_ext.handle(self, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/get")) {
            try tasks_ext.handleGet(self, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/result")) {
            try tasks_ext.handleResult(self, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/list")) {
            try tasks_ext.handleList(self, io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/cancel")) {
            try tasks_ext.handleCancel(self, io, allocator, request);
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
        if (self.capabilities.tasks) |tasks| {
            var tasks_cap: std.json.ObjectMap = .empty;
            if (tasks.list != null) try tasks_cap.put(response_allocator, "list", .{ .object = .empty });
            if (tasks.cancel != null) try tasks_cap.put(response_allocator, "cancel", .{ .object = .empty });
            if (tasks.requests) |requests| {
                var requests_obj: std.json.ObjectMap = .empty;
                if (requests.tools) |tools| {
                    var tools_obj: std.json.ObjectMap = .empty;
                    if (tools.call != null) try tools_obj.put(response_allocator, "call", .{ .object = .empty });
                    try requests_obj.put(response_allocator, "tools", .{ .object = tools_obj });
                }
                try tasks_cap.put(response_allocator, "requests", .{ .object = requests_obj });
            }
            try caps.put(response_allocator, "tasks", .{ .object = tasks_cap });
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
        const page = pagination.fromParams(request.params);

        var tools_array: std.json.Array = .init(response_allocator);

        var iter = self.tools.iterator();
        var index: usize = 0;
        while (iter.next()) |entry| : (index += 1) {
            if (!pagination.shouldIncludeIndex(page, index)) continue;
            const tool = entry.value_ptr.*;
            var tool_obj: std.json.ObjectMap = .empty;
            try tool_obj.put(response_allocator, "name", .{ .string = tool.name });
            if (tool.description) |desc| {
                try tool_obj.put(response_allocator, "description", .{ .string = desc });
            }
            if (tool.title) |t| {
                try tool_obj.put(response_allocator, "title", .{ .string = t });
            }

            var input_schema: std.json.ObjectMap = .empty;
            if (tool.inputSchema) |schema| {
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

            if (tool.annotations) |ann| {
                var ann_obj: std.json.ObjectMap = .empty;
                if (ann.title) |t| try ann_obj.put(response_allocator, "title", .{ .string = t });
                try ann_obj.put(response_allocator, "readOnlyHint", .{ .bool = ann.readOnlyHint });
                try ann_obj.put(response_allocator, "destructiveHint", .{ .bool = ann.destructiveHint });
                try ann_obj.put(response_allocator, "idempotentHint", .{ .bool = ann.idempotentHint });
                try ann_obj.put(response_allocator, "openWorldHint", .{ .bool = ann.openWorldHint });
                try tool_obj.put(response_allocator, "annotations", .{ .object = ann_obj });
            }

            if (tool.execution) |exec| {
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
        try pagination.maybePutNextCursor(response_allocator, &result, page, self.tools.count());

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
            var tool_arena = std.heap.ArenaAllocator.init(allocator);
            defer tool_arena.deinit();
            const tool_allocator = tool_arena.allocator();
            const tool_result = tool.handler(tool.user_data, io, tool_allocator, arguments) catch |err| {
                try self.sendToolHandlerErrorResponse(io, allocator, request, tool_name, err);
                return;
            };
            defer if (tool.deinit_result) |deinit_result| deinit_result(tool_allocator, tool_result);

            var content_array: std.json.Array = .init(allocator);
            var content_array_in_result = false;
            defer if (!content_array_in_result) json_helpers.deinitBorrowedJsonContainers(allocator, .{ .array = content_array });
            for (tool_result.content) |content_item| {
                try json_helpers.appendToolContentValue(allocator, &content_array, content_item);
            }

            var result: std.json.ObjectMap = .empty;
            defer json_helpers.deinitToolCallResponseObject(allocator, &result);
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

    fn sendToolHandlerErrorResponse(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request, tool_name: []const u8, err: anyerror) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var content_array: std.json.Array = .init(response_allocator);
        try json_helpers.appendToolContentValue(response_allocator, &content_array, .{ .text = .{ .text = @errorName(err) } });

        var result: std.json.ObjectMap = .empty;
        try result.put(response_allocator, "content", .{ .array = content_array });
        try result.put(response_allocator, "isError", .{ .bool = true });
        try result.put(response_allocator, "structuredContent", try toolHandlerErrorValue(response_allocator, tool_name, err));

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn toolHandlerErrorValue(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) !std.json.Value {
        return tool_errors.valueFromError(allocator, .{
            .tool = tool_name,
            .operation = "dispatch_tool",
            .phase = "tool_handler",
            .code = "unexpected_tool_handler_error",
            .category = "server_state",
            .resolution = "Inspect zigar stderr logs, fix the tool handler failure, then retry. Expected user errors should return structured tool_error results before this fallback.",
        }, err);
    }

    fn handleResourcesList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();
        const page = pagination.fromParams(request.params);

        var resources_array: std.json.Array = .init(response_allocator);

        var iter = self.resources.iterator();
        var index: usize = 0;
        while (iter.next()) |entry| : (index += 1) {
            if (!pagination.shouldIncludeIndex(page, index)) continue;
            const resource = entry.value_ptr.*;
            var resource_obj: std.json.ObjectMap = .empty;
            try resource_obj.put(response_allocator, "uri", .{ .string = resource.uri });
            try resource_obj.put(response_allocator, "name", .{ .string = resource.name });
            if (resource.title) |t| {
                try resource_obj.put(response_allocator, "title", .{ .string = t });
            }
            if (resource.description) |desc| {
                try resource_obj.put(response_allocator, "description", .{ .string = desc });
            }
            if (resource.mimeType) |mime| {
                try resource_obj.put(response_allocator, "mimeType", .{ .string = mime });
            }
            if (resource.size) |s| {
                try resource_obj.put(response_allocator, "size", .{ .integer = @intCast(s) });
            }
            try resources_array.append(.{ .object = resource_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(response_allocator, "resources", .{ .array = resources_array });
        try pagination.maybePutNextCursor(response_allocator, &result, page, self.resources.count());

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
                var response_arena = std.heap.ArenaAllocator.init(allocator);
                defer response_arena.deinit();
                const error_response = jsonrpc.createInternalError(request.id, try resourceHandlerErrorValue(response_arena.allocator(), uri, err));
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            };
            defer if (self.resource_content_deinits.get(uri)) |deinit_content| deinit_content(allocator, content);

            var contents_array: std.json.Array = .init(allocator);
            var contents_array_in_result = false;
            defer if (!contents_array_in_result) json_helpers.deinitBorrowedJsonContainers(allocator, .{ .array = contents_array });
            var content_obj: std.json.ObjectMap = .empty;
            var content_obj_in_array = false;
            errdefer if (!content_obj_in_array) json_helpers.deinitBorrowedJsonContainers(allocator, .{ .object = content_obj });
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
            defer json_helpers.deinitBorrowedJsonContainers(allocator, .{ .object = result });
            try result.put(allocator, "contents", .{ .array = contents_array });
            contents_array_in_result = true;

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else if (self.dynamic_resource_handler) |handler| {
            const content = handler(self.dynamic_resource_user_data, io, allocator, uri) catch |err| {
                var response_arena = std.heap.ArenaAllocator.init(allocator);
                defer response_arena.deinit();
                _ = try resourceHandlerErrorValue(response_arena.allocator(), uri, err);
                const error_response = jsonrpc.createInvalidParams(request.id, "Dynamic resource not found or could not be read");
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            };
            defer if (self.dynamic_resource_deinit) |deinit_content| deinit_content(allocator, content);

            var contents_array: std.json.Array = .init(allocator);
            var contents_array_in_result = false;
            defer if (!contents_array_in_result) json_helpers.deinitBorrowedJsonContainers(allocator, .{ .array = contents_array });
            var content_obj: std.json.ObjectMap = .empty;
            var content_obj_in_array = false;
            errdefer if (!content_obj_in_array) json_helpers.deinitBorrowedJsonContainers(allocator, .{ .object = content_obj });
            try content_obj.put(allocator, "uri", .{ .string = uri });
            if (content.text) |text| try content_obj.put(allocator, "text", .{ .string = text });
            if (content.blob) |blob| try content_obj.put(allocator, "blob", .{ .string = blob });
            if (content.mimeType) |mime| try content_obj.put(allocator, "mimeType", .{ .string = mime });
            try contents_array.append(.{ .object = content_obj });
            content_obj_in_array = true;

            var result: std.json.ObjectMap = .empty;
            defer json_helpers.deinitBorrowedJsonContainers(allocator, .{ .object = result });
            try result.put(allocator, "contents", .{ .array = contents_array });
            contents_array_in_result = true;

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Resource not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    fn resourceHandlerErrorValue(allocator: std.mem.Allocator, uri: []const u8, err: anyerror) !std.json.Value {
        return tool_errors.valueFromError(allocator, .{
            .tool = "resources/read",
            .operation = "read_resource",
            .phase = "resource_handler",
            .code = "unexpected_resource_handler_error",
            .category = "server_state",
            .resolution = "Inspect zigar stderr logs, fix the resource handler failure, then retry.",
            .details = &.{.{ .key = "resource_uri", .value = .{ .string = uri } }},
        }, err);
    }

    fn handleResourceTemplatesList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();
        const page = pagination.fromParams(request.params);

        var templates_array: std.json.Array = .init(response_allocator);

        var iter = self.resource_templates.iterator();
        var index: usize = 0;
        while (iter.next()) |entry| : (index += 1) {
            if (!pagination.shouldIncludeIndex(page, index)) continue;
            const template = entry.value_ptr.*;
            var template_obj: std.json.ObjectMap = .empty;
            try template_obj.put(response_allocator, "uriTemplate", .{ .string = template.uriTemplate });
            try template_obj.put(response_allocator, "name", .{ .string = template.name });
            if (template.title) |t| {
                try template_obj.put(response_allocator, "title", .{ .string = t });
            }
            if (template.description) |desc| {
                try template_obj.put(response_allocator, "description", .{ .string = desc });
            }
            if (template.mimeType) |mime| {
                try template_obj.put(response_allocator, "mimeType", .{ .string = mime });
            }
            try templates_array.append(.{ .object = template_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(response_allocator, "resourceTemplates", .{ .array = templates_array });
        try pagination.maybePutNextCursor(response_allocator, &result, page, self.resource_templates.count());

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    fn handlePromptsList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();
        const page = pagination.fromParams(request.params);

        var prompts_array: std.json.Array = .init(response_allocator);

        var iter = self.prompts.iterator();
        var index: usize = 0;
        while (iter.next()) |entry| : (index += 1) {
            if (!pagination.shouldIncludeIndex(page, index)) continue;
            const prompt = entry.value_ptr.*;
            var prompt_obj: std.json.ObjectMap = .empty;
            try prompt_obj.put(response_allocator, "name", .{ .string = prompt.name });
            if (prompt.description) |desc| {
                try prompt_obj.put(response_allocator, "description", .{ .string = desc });
            }
            if (prompt.title) |t| {
                try prompt_obj.put(response_allocator, "title", .{ .string = t });
            }

            if (prompt.arguments) |args| {
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
        try pagination.maybePutNextCursor(response_allocator, &result, page, self.prompts.count());

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
                var response_arena = std.heap.ArenaAllocator.init(allocator);
                defer response_arena.deinit();
                const error_response = jsonrpc.createInternalError(request.id, try promptHandlerErrorValue(response_arena.allocator(), prompt_name, err));
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            };
            defer if (self.prompt_message_deinits.get(prompt_name)) |deinit_messages| deinit_messages(allocator, messages);

            var messages_array: std.json.Array = .init(allocator);
            var messages_array_in_result = false;
            defer if (!messages_array_in_result) json_helpers.deinitBorrowedJsonContainers(allocator, .{ .array = messages_array });
            for (messages) |msg| {
                var msg_obj: std.json.ObjectMap = .empty;
                var msg_obj_in_array = false;
                errdefer if (!msg_obj_in_array) json_helpers.deinitBorrowedJsonContainers(allocator, .{ .object = msg_obj });
                try msg_obj.put(allocator, "role", .{ .string = msg.role.toString() });
                var content_obj: std.json.ObjectMap = .empty;
                var content_obj_in_msg = false;
                errdefer if (!content_obj_in_msg) json_helpers.deinitBorrowedJsonContainers(allocator, .{ .object = content_obj });
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
                        errdefer if (!res_inner_in_content) json_helpers.deinitBorrowedJsonContainers(allocator, .{ .object = res_inner });
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
            defer json_helpers.deinitBorrowedJsonContainers(allocator, .{ .object = result });
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

    fn promptHandlerErrorValue(allocator: std.mem.Allocator, prompt_name: []const u8, err: anyerror) !std.json.Value {
        return tool_errors.valueFromError(allocator, .{
            .tool = "prompts/get",
            .operation = "get_prompt",
            .phase = "prompt_handler",
            .code = "unexpected_prompt_handler_error",
            .category = "server_state",
            .resolution = "Inspect zigar stderr logs, fix the prompt handler failure, then retry.",
            .details = &.{.{ .key = "prompt", .value = .{ .string = prompt_name } }},
        }, err);
    }

    fn handleSetLogLevel(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        const shape_error = "logging/setLevel requires params.level to be a string";
        const level_value = request.params orelse return self.sendInvalidParams(io, allocator, request.id, shape_error);
        if (level_value != .object) return self.sendInvalidParams(io, allocator, request.id, shape_error);
        const level_json = level_value.object.get("level") orelse return self.sendInvalidParams(io, allocator, request.id, shape_error);
        if (level_json != .string) {
            return self.sendInvalidParams(io, allocator, request.id, shape_error);
        }
        self.log_level = parseLogLevel(level_json.string) orelse {
            return self.sendInvalidParams(io, allocator, request.id, "Unsupported logging level");
        };

        const result: std.json.ObjectMap = .empty;
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    pub fn sendInvalidParams(self: *Self, io: std.Io, allocator: std.mem.Allocator, id: types.RequestId, message: []const u8) !void {
        const error_response = jsonrpc.createInvalidParams(id, message);
        try self.sendResponse(io, allocator, .{ .error_response = error_response });
    }

    fn parseLogLevel(level: []const u8) ?protocol.LogLevel {
        if (std.mem.eql(u8, level, "debug")) return .debug;
        if (std.mem.eql(u8, level, "info")) return .info;
        if (std.mem.eql(u8, level, "notice")) return .notice;
        if (std.mem.eql(u8, level, "warning")) return .warning;
        if (std.mem.eql(u8, level, "error")) return .@"error";
        if (std.mem.eql(u8, level, "critical")) return .critical;
        if (std.mem.eql(u8, level, "alert")) return .alert;
        if (std.mem.eql(u8, level, "emergency")) return .emergency;
        return null;
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

    pub fn sendResponse(self: *Self, io: std.Io, allocator: std.mem.Allocator, message: jsonrpc.Message) !void {
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
