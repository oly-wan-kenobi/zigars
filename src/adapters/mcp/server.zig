//! First-party MCP server adapter for zigars.
//! Owns routing and zigars result lifetimes over the pinned upstream MCP dependency.

const std = @import("std");
const mcp = @import("mcp");

const jsonrpc = mcp.jsonrpc;
const protocol = mcp.protocol;
const types = mcp.types;
const transport_mod = mcp.transport;
const prompts_mod = mcp.prompts;
const resources_mod = mcp.resources;
const completion_ext = @import("server/completion.zig");
const http_runner = @import("server/http_runner.zig");
const json_helpers = @import("server/json_helpers.zig");
const pagination = @import("server/pagination.zig");
const protocol_client = @import("server/protocol_client.zig");
const resource_subscriptions = @import("server/resource_subscriptions.zig");
const tasks_ext = @import("server/tasks.zig");
const app_ports = @import("../../app/ports.zig");
const audit = @import("../../infra/observability/audit.zig");
const cancellation = @import("cancellation");
const correlation = @import("correlation.zig");
const logging = @import("../../infra/observability/logging.zig");
const observability_mod = @import("../../infra/observability/state.zig");
const tool_errors = @import("errors.zig");

/// Deinitializer for tool results whose payload storage is owned by request allocators.
pub const ToolResultDeinit = *const fn (allocator: std.mem.Allocator, result: mcp.tools.ToolResult) void;
/// Deinitializer for resource contents whose optional fields may allocate per request.
pub const ResourceContentDeinit = *const fn (allocator: std.mem.Allocator, content: mcp.resources.ResourceContent) void;
/// Deinitializer for prompt message slices produced by prompt handlers.
pub const PromptMessagesDeinit = *const fn (allocator: std.mem.Allocator, messages: []const mcp.prompts.PromptMessage) void;

/// Registered MCP tool metadata plus zigars callback and cleanup contract.
pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    title: ?[]const u8 = null,
    inputSchema: ?types.InputSchema = null,
    outputSchema: ?types.OutputSchema = null,
    execution: ?types.ToolExecution = null,
    icons: ?[]const types.Icon = null,
    annotations: ?mcp.tools.ToolAnnotations = null,
    handler: *const fn (user_data: ?*anyopaque, server: *Server, io: std.Io, allocator: std.mem.Allocator, arguments: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult,
    deinit_result: ?ToolResultDeinit = null,
    user_data: ?*anyopaque = null,
};

/// Callback for template-backed resource URIs that are resolved at read time.
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
    trustManifestUri: ?[]const u8 = null,
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
    task_state: ?tasks_ext.State = null,
    capabilities: types.ServerCapabilities = .{},
    client_info: ?types.Implementation = null,
    client_capabilities: ?types.ClientCapabilities = null,
    transport: ?transport_mod.Transport = null,
    stdio_transport: ?*transport_mod.StdioTransport = null,
    correlation_generator: correlation.Generator = .{},
    active_correlation: ?*const correlation.Context = null,
    active_request: ?ActiveRequest = null,
    completed_requests: [64]CompletedRequest = [_]CompletedRequest{.{}} ** 64,
    completed_request_count: u64 = 0,
    startup_started_ns: ?i128 = null,
    first_initialize_recorded: bool = false,
    audit_writer: ?*audit.Writer = null,
    observability: ?*observability_mod.State = null,
    transport_name: []const u8 = "unknown",
    next_request_id: i64 = 1,
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    log_level: protocol.LogLevel = .info,
    /// Maximum accepted JSON-RPC POST body size for the built-in HTTP transport.
    pub const max_http_body_size: usize = http_runner.max_body_size;

    const Self = @This();

    /// White-box test accessors kept separate from the production request API.
    pub const TestAccess = struct {
        pub fn log(server: *Self, io: std.Io, message: []const u8) void {
            server.log(io, message);
        }

        pub fn logError(server: *Self, io: std.Io, message: []const u8) void {
            server.logError(io, message);
        }

        pub fn nextCorrelation(server: *Self, request_id: correlation.RequestId, method: []const u8, tool_name: ?[]const u8) correlation.Context {
            return server.nextCorrelation(request_id, method, tool_name);
        }

        pub fn handleCancellationNotification(server: *Self, io: std.Io, notification: jsonrpc.Notification, notification_correlation: *const correlation.Context) void {
            server.handleCancellationNotification(io, notification, notification_correlation);
        }

        pub fn rememberCompletedRequest(server: *Self, request_id: correlation.RequestId, method: []const u8) void {
            server.rememberCompletedRequest(request_id, method);
        }

        pub fn requestCanObserveCancellation(method: []const u8) bool {
            return isCancellableMethod(method);
        }
    };

    /// Outbound request bookkeeping for responses from the peer.
    pub const PendingRequest = struct {
        method: []const u8,
        timestamp: i64,
    };

    /// Currently executing inbound JSON-RPC request.
    const ActiveRequest = struct {
        request_id: correlation.RequestId,
        method: []const u8,
        cancellable: bool,
        state: *cancellation.State,
    };

    /// Recently completed request id retained to classify late cancellation notifications.
    const CompletedRequest = struct {
        request_id: correlation.RequestId = .{},
        request_id_string: [128]u8 = [_]u8{0} ** 128,
        request_id_string_len: usize = 0,
        method: [64]u8 = [_]u8{0} ** 64,
        method_len: usize = 0,
    };

    /// Stable classifications for protocol-helper peer responses.
    pub const ProtocolResponseStatus = protocol_client.ResponseStatus;

    /// Classifies an elicitation/create response without mutating server state.
    pub fn classifyElicitationResponse(response: ?std.json.Value) ProtocolResponseStatus {
        return protocol_client.classifyElicitationResponse(response);
    }

    /// Classifies a sampling/createMessage response without mutating server state.
    pub fn classifySamplingResponse(response: ?std.json.Value) ProtocolResponseStatus {
        return protocol_client.classifySamplingResponse(response);
    }

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

    /// Add a resource whose returned content follows a zigars-owned cleanup contract.
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

    /// Add a prompt whose returned messages follow a zigars-owned cleanup contract.
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

    /// Enable task-augmented tools/call support backed by zigars runtime jobs.
    pub fn enableTasks(self: *Self, state: anytype) void {
        self.task_state = tasks_ext.State.init(state);
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

    /// Attaches an opt-in audit writer; server stdout remains reserved for JSON-RPC.
    pub fn setAuditWriter(self: *Self, writer: *audit.Writer) void {
        self.audit_writer = writer;
    }

    /// Attaches process-local observability state for adapter-level events.
    pub fn setObservability(self: *Self, state: *observability_mod.State) void {
        self.observability = state;
    }

    /// Carries the monotonic bootstrap start time for startup timing records.
    pub fn setStartupStart(self: *Self, started_ns: i128) void {
        self.startup_started_ns = started_ns;
    }

    /// Returns the active cooperative cancellation token, if the current request is cancellable.
    pub fn currentCancellationToken(self: *Self) ?app_ports.CancellationToken {
        const active = self.active_request orelse return null;
        if (!active.cancellable) return null;
        return active.state.token();
    }

    /// Options for running the server
    pub const HttpRunConfig = http_runner.RunConfig;

    /// Transport choices supported by the standalone server loop.
    pub const RunOptions = union(enum) {
        stdio: void,
        http: HttpRunConfig,
    };

    /// Run the server with the specified transport
    pub fn run(self: *Self, io: std.Io, allocator: std.mem.Allocator, options: RunOptions) !void {
        switch (options) {
            .stdio => {
                self.log(io, "Server listening on STDIO");
                const bind_started_ns = monotonicNowNs(io);
                const stdio = try allocator.create(transport_mod.StdioTransport);
                stdio.* = .{};
                self.stdio_transport = stdio;
                self.transport = stdio.transport();
                self.transport_name = "stdio";
                self.recordStartupPhaseRange("transport_bind", bind_started_ns, monotonicNowNs(io));
                try self.messageLoop(io, allocator);
            },
            .http => |config| {
                try http_runner.run(self, io, allocator, config);
            },
        }
    }

    /// Run the server with a custom transport
    pub fn runWithTransport(self: *Self, io: std.Io, allocator: std.mem.Allocator, t: transport_mod.Transport) !void {
        self.transport = t;
        self.transport_name = "custom";
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
    pub fn handleMessage(self: *Self, io: std.Io, allocator: std.mem.Allocator, data: []const u8) !void {
        const parsed_message = jsonrpc.parseMessage(allocator, data) catch {
            var parse_correlation = self.nextCorrelation(correlation.RequestId.absent(), "jsonrpc/parse", null);
            self.logWithCorrelation(io, &parse_correlation, "JSON-RPC parse error");
            self.appendAudit(allocator, .{
                .event = "parse_error",
                .direction = "inbound",
                .transport = self.transport_name,
                .mcp_method = "jsonrpc/parse",
                .payload = data,
                .is_error = true,
            });
            const error_response = jsonrpc.createParseError(null);
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        };
        defer parsed_message.deinit();

        switch (parsed_message.message) {
            .request => |req| try self.handleRequest(io, allocator, req, data),
            .notification => |notif| try self.handleNotification(io, notif, data),
            .response => |resp| self.handleResponse(resp),
            .error_response => |err| self.handleErrorResponse(io, err),
        }
    }

    /// Handle an incoming request
    pub fn handleRequest(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request, raw_payload: ?[]const u8) !void {
        const started_ns = monotonicNowNs(io);
        var request_correlation = self.nextCorrelation(correlation.RequestId.from(request.id), request.method, null);
        const previous_correlation = self.active_correlation;
        self.active_correlation = &request_correlation;
        defer self.active_correlation = previous_correlation;

        var cancellation_state: cancellation.State = .{};
        const previous_active = self.active_request;
        self.active_request = .{
            .request_id = request_correlation.request_id,
            .method = request.method,
            .cancellable = isCancellableMethod(request.method),
            .state = &cancellation_state,
        };
        defer self.active_request = previous_active;

        var request_is_error = false;
        defer {
            const ended_ns = monotonicNowNs(io);
            self.rememberCompletedRequest(request_correlation.request_id, request.method);
            if (self.observability) |observability| {
                observability.recordMcpRequest(request.method, elapsedMs(started_ns, ended_ns), request_is_error);
            }
            if (std.mem.eql(u8, request.method, "initialize") and !self.first_initialize_recorded) {
                self.first_initialize_recorded = true;
                self.recordStartupPhaseRange("first_initialize", started_ns, ended_ns);
            }
        }
        errdefer request_is_error = true;

        self.appendAudit(allocator, .{
            .event = "request",
            .direction = "inbound",
            .transport = self.transport_name,
            .mcp_method = request.method,
            .mcp_request_id_type = request_correlation.request_id.typeName(),
            .mcp_request_id_value = request_correlation.request_id.valueString(),
            .correlation = auditCorrelation(&request_correlation),
            .tool_name = request_correlation.tool_name,
            .payload = raw_payload,
        });
        self.logWithCorrelation(io, &request_correlation, "Received request");

        if (self.state == .uninitialized and !std.mem.eql(u8, request.method, "initialize")) {
            self.logWithCorrelation(io, &request_correlation, "Server not initialized");
            request_is_error = true;
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
            if (self.state != .uninitialized) {
                self.logWithCorrelation(io, &request_correlation, "Server already initialized");
                request_is_error = true;
                const error_response = jsonrpc.createErrorResponse(
                    request.id,
                    jsonrpc.ErrorCode.INVALID_REQUEST,
                    "Server already initialized",
                    null,
                );
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            }
            try self.handleInitialize(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "shutdown")) {
            try self.handleShutdown(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "ping")) {
            try self.handlePing(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tools/list")) {
            try self.handleToolsList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tools/call")) {
            try self.handleToolsCall(io, allocator, request, &request_correlation);
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
            self.logWithCorrelation(io, &request_correlation, "Method not found");
            request_is_error = true;
            const error_response = jsonrpc.createMethodNotFound(request.id, request.method);
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handles the initialize request and sends the JSON-RPC response or error.
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
                if (obj.get("capabilities")) |capabilities_val| {
                    self.client_capabilities = parseClientCapabilities(capabilities_val);
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
                    std.mem.doNotOptimizeAway(tools_obj.count());
                    try requests_obj.put(response_allocator, "tools", .{ .object = tools_obj });
                }
                std.mem.doNotOptimizeAway(requests_obj.count());
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
        if (self.config.trustManifestUri) |uri| {
            var trust_manifest: std.json.ObjectMap = .empty;
            try trust_manifest.put(response_allocator, "uri", .{ .string = uri });
            try trust_manifest.put(response_allocator, "mimeType", .{ .string = "application/json" });

            var zigars: std.json.ObjectMap = .empty;
            try zigars.put(response_allocator, "trust_manifest", .{ .object = trust_manifest });
            try result.put(response_allocator, "zigars", .{ .object = zigars });
        }

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handles the shutdown request and sends the JSON-RPC response or error.
    fn handleShutdown(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        self.state = .shutting_down;
        const result: std.json.ObjectMap = .empty;
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handles the ping request and sends the JSON-RPC response or error.
    fn handlePing(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handles the tools list request and sends the JSON-RPC response or error.
    fn handleToolsList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();
        const page = pagination.fromParams(request.params) catch return self.sendInvalidParams(io, allocator, request.id, pagination.invalid_cursor_message);

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

            if (tool.outputSchema) |schema| {
                var output_schema: std.json.ObjectMap = .empty;
                try output_schema.put(response_allocator, "type", .{ .string = schema.type });
                if (schema.@"$schema") |s| try output_schema.put(response_allocator, "$schema", .{ .string = s });
                if (schema.properties) |p| try output_schema.put(response_allocator, "properties", p);
                if (schema.required) |req| {
                    var arr: std.json.Array = .init(response_allocator);
                    for (req) |name| try arr.append(.{ .string = name });
                    try output_schema.put(response_allocator, "required", .{ .array = arr });
                }
                try tool_obj.put(response_allocator, "outputSchema", .{ .object = output_schema });
            }

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

    /// Handles the tools call request and sends the JSON-RPC response or error.
    fn handleToolsCall(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request, request_correlation: *correlation.Context) !void {
        const tool_name = mcp.tools.getString(request.params, "name") orelse "";
        request_correlation.setToolName(tool_name);
        const arguments: ?std.json.Value = if (mcp.tools.getObject(request.params, "arguments")) |object| .{ .object = object } else null;

        if (self.tools.get(tool_name)) |tool| {
            var tool_arena = std.heap.ArenaAllocator.init(allocator);
            defer tool_arena.deinit();
            const tool_allocator = tool_arena.allocator();
            const previous_correlation = self.active_correlation;
            self.active_correlation = request_correlation;
            defer self.active_correlation = previous_correlation;
            const tool_result = tool.handler(tool.user_data, self, io, tool_allocator, arguments) catch |err| {
                self.logWithCorrelation(io, request_correlation, "Tool handler failed");
                try self.sendToolHandlerErrorResponse(io, allocator, request, tool_name, err, request_correlation);
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
            try request_correlation.putMeta(allocator, &result);

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            self.logWithCorrelation(io, request_correlation, "Tool not found");
            const error_response = jsonrpc.createInvalidParams(request.id, "Tool not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Sends a structured tools/call error response using transient JSON owned by the response arena.
    fn sendToolHandlerErrorResponse(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request, tool_name: []const u8, err: anyerror, request_correlation: *const correlation.Context) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var content_array: std.json.Array = .init(response_allocator);
        try json_helpers.appendToolContentValue(response_allocator, &content_array, .{ .text = .{ .text = @errorName(err) } });

        var result: std.json.ObjectMap = .empty;
        try result.put(response_allocator, "content", .{ .array = content_array });
        try result.put(response_allocator, "isError", .{ .bool = true });
        try result.put(response_allocator, "structuredContent", try toolHandlerErrorValue(response_allocator, tool_name, err));
        try request_correlation.putMeta(response_allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Returns the structured JSON payload for a failed tool callback.
    fn toolHandlerErrorValue(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) !std.json.Value {
        return tool_errors.valueFromError(allocator, .{
            .tool = tool_name,
            .operation = "dispatch_tool",
            .phase = "tool_handler",
            .code = "unexpected_tool_handler_error",
            .category = "server_state",
            .resolution = "Inspect zigars stderr logs, fix the tool handler failure, then retry. Expected user errors should return structured tool_error results before this fallback.",
        }, err);
    }

    /// Handles the resources list request and sends the JSON-RPC response or error.
    fn handleResourcesList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();
        const page = pagination.fromParams(request.params) catch return self.sendInvalidParams(io, allocator, request.id, pagination.invalid_cursor_message);

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

    /// Handles the resources read request and sends the JSON-RPC response or error.
    fn handleResourcesRead(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        const uri = mcp.tools.getString(request.params, "uri") orelse "";

        if (self.resources.get(uri)) |resource| {
            const content = resource.handler(resource.user_data, io, allocator, uri) catch |err| {
                var response_arena = std.heap.ArenaAllocator.init(allocator);
                defer response_arena.deinit();
                const error_response = jsonrpc.createInternalError(request.id, try resourceHandlerErrorValue(response_arena.allocator(), uri, err));
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            };
            defer if (self.resource_content_deinits.get(uri)) |deinit_content| deinit_content(allocator, content);

            var response_arena = std.heap.ArenaAllocator.init(allocator);
            defer response_arena.deinit();
            const response_allocator = response_arena.allocator();

            var contents_array: std.json.Array = .init(response_allocator);
            var content_obj: std.json.ObjectMap = .empty;
            try content_obj.put(response_allocator, "uri", .{ .string = uri });
            if (content.text) |text| {
                try content_obj.put(response_allocator, "text", .{ .string = text });
            }
            if (content.blob) |blob| {
                try content_obj.put(response_allocator, "blob", .{ .string = blob });
            }
            if (content.mimeType) |mime| {
                try content_obj.put(response_allocator, "mimeType", .{ .string = mime });
            }
            try contents_array.append(.{ .object = content_obj });

            var result: std.json.ObjectMap = .empty;
            try result.put(response_allocator, "contents", .{ .array = contents_array });

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

            var response_arena = std.heap.ArenaAllocator.init(allocator);
            defer response_arena.deinit();
            const response_allocator = response_arena.allocator();

            var contents_array: std.json.Array = .init(response_allocator);
            var content_obj: std.json.ObjectMap = .empty;
            try content_obj.put(response_allocator, "uri", .{ .string = uri });
            if (content.text) |text| try content_obj.put(response_allocator, "text", .{ .string = text });
            if (content.blob) |blob| try content_obj.put(response_allocator, "blob", .{ .string = blob });
            if (content.mimeType) |mime| try content_obj.put(response_allocator, "mimeType", .{ .string = mime });
            try contents_array.append(.{ .object = content_obj });

            var result: std.json.ObjectMap = .empty;
            try result.put(response_allocator, "contents", .{ .array = contents_array });

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Resource not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Returns the structured JSON payload for a failed resource callback.
    fn resourceHandlerErrorValue(allocator: std.mem.Allocator, uri: []const u8, err: anyerror) !std.json.Value {
        return tool_errors.valueFromError(allocator, .{
            .tool = "resources/read",
            .operation = "read_resource",
            .phase = "resource_handler",
            .code = "unexpected_resource_handler_error",
            .category = "server_state",
            .resolution = "Inspect zigars stderr logs, fix the resource handler failure, then retry.",
            .details = &.{.{ .key = "resource_uri", .value = .{ .string = uri } }},
        }, err);
    }

    /// Handles the resource templates list request and sends the JSON-RPC response or error.
    fn handleResourceTemplatesList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();
        const page = pagination.fromParams(request.params) catch return self.sendInvalidParams(io, allocator, request.id, pagination.invalid_cursor_message);

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

    /// Handles the prompts list request and sends the JSON-RPC response or error.
    fn handlePromptsList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();
        const page = pagination.fromParams(request.params) catch return self.sendInvalidParams(io, allocator, request.id, pagination.invalid_cursor_message);

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

    /// Handles the prompts get request and sends the JSON-RPC response or error.
    fn handlePromptsGet(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        const prompt_name = mcp.tools.getString(request.params, "name") orelse "";
        const arguments: ?std.json.Value = if (mcp.tools.getObject(request.params, "arguments")) |object| .{ .object = object } else null;

        if (self.prompts.get(prompt_name)) |prompt| {
            const messages = prompt.handler(prompt.user_data, io, allocator, arguments) catch |err| {
                var response_arena = std.heap.ArenaAllocator.init(allocator);
                defer response_arena.deinit();
                const error_response = jsonrpc.createInternalError(request.id, try promptHandlerErrorValue(response_arena.allocator(), prompt_name, err));
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            };
            defer if (self.prompt_message_deinits.get(prompt_name)) |deinit_messages| deinit_messages(allocator, messages);

            var response_arena = std.heap.ArenaAllocator.init(allocator);
            defer response_arena.deinit();
            const response_allocator = response_arena.allocator();

            var messages_array: std.json.Array = .init(response_allocator);
            for (messages) |msg| {
                var msg_obj: std.json.ObjectMap = .empty;
                try msg_obj.put(response_allocator, "role", .{ .string = msg.role.toString() });
                var content_obj: std.json.ObjectMap = .empty;
                switch (msg.content) {
                    .text => |text| {
                        try content_obj.put(response_allocator, "type", .{ .string = "text" });
                        try content_obj.put(response_allocator, "text", .{ .string = text.text });
                    },
                    .image => |img| {
                        try content_obj.put(response_allocator, "type", .{ .string = "image" });
                        try content_obj.put(response_allocator, "data", .{ .string = img.data });
                        try content_obj.put(response_allocator, "mimeType", .{ .string = img.mimeType });
                    },
                    .audio => |aud| {
                        try content_obj.put(response_allocator, "type", .{ .string = "audio" });
                        try content_obj.put(response_allocator, "data", .{ .string = aud.data });
                        try content_obj.put(response_allocator, "mimeType", .{ .string = aud.mimeType });
                    },
                    .resource_link => |link| {
                        try content_obj.put(response_allocator, "type", .{ .string = "resource_link" });
                        try content_obj.put(response_allocator, "uri", .{ .string = link.uri });
                        try content_obj.put(response_allocator, "name", .{ .string = link.name });
                    },
                    .resource => |res| {
                        try content_obj.put(response_allocator, "type", .{ .string = "resource" });
                        var res_inner: std.json.ObjectMap = .empty;
                        try res_inner.put(response_allocator, "uri", .{ .string = res.resource.uri });
                        if (res.resource.text) |text| try res_inner.put(response_allocator, "text", .{ .string = text });
                        try content_obj.put(response_allocator, "resource", .{ .object = res_inner });
                    },
                }
                try msg_obj.put(response_allocator, "content", .{ .object = content_obj });
                try messages_array.append(.{ .object = msg_obj });
            }

            var result: std.json.ObjectMap = .empty;
            try result.put(response_allocator, "messages", .{ .array = messages_array });
            if (prompt.description) |desc| {
                try result.put(response_allocator, "description", .{ .string = desc });
            }

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Prompt not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Returns the structured JSON payload for a failed prompt callback.
    fn promptHandlerErrorValue(allocator: std.mem.Allocator, prompt_name: []const u8, err: anyerror) !std.json.Value {
        return tool_errors.valueFromError(allocator, .{
            .tool = "prompts/get",
            .operation = "get_prompt",
            .phase = "prompt_handler",
            .code = "unexpected_prompt_handler_error",
            .category = "server_state",
            .resolution = "Inspect zigars stderr logs, fix the prompt handler failure, then retry.",
            .details = &.{.{ .key = "prompt", .value = .{ .string = prompt_name } }},
        }, err);
    }

    /// Handles the set log level request and sends the JSON-RPC response or error.
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

    /// Sends a JSON-RPC invalid-params error, using the allocator only for serialization.
    pub fn sendInvalidParams(self: *Self, io: std.Io, allocator: std.mem.Allocator, id: types.RequestId, message: []const u8) !void {
        const error_response = jsonrpc.createInvalidParams(id, message);
        try self.sendResponse(io, allocator, .{ .error_response = error_response });
    }

    /// Parses log level, returning null when the field is absent.
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

    /// Parses the subset of client capabilities needed by protocol helper scaffolds.
    fn parseClientCapabilities(value: std.json.Value) types.ClientCapabilities {
        if (value != .object) return .{};
        const obj = value.object;
        return .{
            .roots = if (obj.get("roots")) |roots| parseRootsCapability(roots) else null,
            .sampling = if (obj.get("sampling")) |sampling| parseSamplingCapability(sampling) else null,
            .elicitation = if (obj.get("elicitation")) |elicitation| parseElicitationCapability(elicitation) else null,
        };
    }

    /// Parses roots/listChanged support without retaining borrowed JSON.
    fn parseRootsCapability(value: std.json.Value) ?types.RootsCapability {
        if (value != .object) return .{};
        return .{ .listChanged = if (value.object.get("listChanged")) |list_changed| list_changed == .bool and list_changed.bool else false };
    }

    /// Parses sampling support without retaining borrowed JSON.
    fn parseSamplingCapability(value: std.json.Value) ?types.SamplingCapability {
        if (value != .object) return .{};
        const obj = value.object;
        return .{
            .context = if (obj.get("context")) |_| .{} else null,
            .tools = if (obj.get("tools")) |_| .{} else null,
        };
    }

    /// Parses elicitation support without retaining borrowed JSON.
    fn parseElicitationCapability(value: std.json.Value) ?types.ElicitationCapability {
        if (value != .object) return .{};
        const obj = value.object;
        return .{
            .form = if (obj.get("form")) |_| .{} else null,
            .url = if (obj.get("url")) |_| .{} else null,
        };
    }

    /// Handles inbound JSON-RPC notifications and updates local server state.
    pub fn handleNotification(self: *Self, io: std.Io, notification: jsonrpc.Notification, raw_payload: ?[]const u8) !void {
        var notification_correlation = self.nextCorrelation(correlation.RequestId.absent(), notification.method, null);
        self.appendAudit(self.allocator, .{
            .event = "notification",
            .direction = "inbound",
            .transport = self.transport_name,
            .mcp_method = notification.method,
            .correlation = auditCorrelation(&notification_correlation),
            .payload = raw_payload,
        });
        if (std.mem.eql(u8, notification.method, "notifications/initialized")) {
            self.state = .ready;
            self.logWithCorrelation(io, &notification_correlation, "Server initialized and ready");
        } else if (std.mem.eql(u8, notification.method, "notifications/cancelled")) {
            self.handleCancellationNotification(io, notification, &notification_correlation);
            self.logWithCorrelation(io, &notification_correlation, "Cancellation notification received");
        } else if (std.mem.eql(u8, notification.method, "notifications/roots/list_changed")) {
            self.logWithCorrelation(io, &notification_correlation, "Roots list changed");
        }
    }

    /// Handles successful peer responses by clearing pending request bookkeeping.
    pub fn handleResponse(self: *Self, response: jsonrpc.Response) void {
        const id = switch (response.id) {
            .integer => |i| i,
            .string => return,
        };
        _ = self.pending_requests.remove(id);
    }

    /// Handles peer error responses by clearing pending request bookkeeping and logging.
    pub fn handleErrorResponse(self: *Self, io: std.Io, err: jsonrpc.ErrorResponse) void {
        if (err.id) |id| {
            const int_id = switch (id) {
                .integer => |i| i,
                .string => return,
            };
            _ = self.pending_requests.remove(int_id);
        }
        self.logError(io, err.@"error".message);
    }

    /// Sends a JSON-RPC notification, using the allocator only for serialization.
    pub fn sendNotification(self: *Self, io: std.Io, allocator: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !void {
        const notification = jsonrpc.createNotification(method, params);
        try self.sendResponse(io, allocator, .{ .notification = notification });
    }

    /// Sends a log notification when it meets the configured level threshold.
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

    /// Sends a progress notification with transient params owned by a response arena.
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

    /// Returns whether the initialized client advertised elicitation support.
    pub fn supportsElicitation(self: *Self) bool {
        return protocol_client.supportsElicitation(self);
    }

    /// Returns whether the initialized client advertised sampling support.
    pub fn supportsSampling(self: *Self) bool {
        return protocol_client.supportsSampling(self);
    }

    /// Sends elicitation/create when supported; otherwise returns a structured fallback.
    pub fn tryElicitationCreate(self: *Self, io: std.Io, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        return protocol_client.tryElicitationCreate(self, io, allocator, params);
    }

    /// Sends sampling/createMessage when supported; otherwise returns a structured fallback.
    pub fn trySamplingCreateMessage(self: *Self, io: std.Io, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        return protocol_client.trySamplingCreateMessage(self, io, allocator, params);
    }

    /// Sends a protocol helper request to the active client and waits for its matching JSON-RPC response.
    pub fn requestClientProtocol(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: app_ports.ProtocolRequest) !app_ports.ProtocolResponse {
        return protocol_client.requestClientProtocol(self, io, allocator, request);
    }

    /// Emits the tools changed notification through the active transport.
    pub fn notifyToolsChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/tools/list_changed", null);
    }

    /// Emits the resources changed notification through the active transport.
    pub fn notifyResourcesChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/resources/list_changed", null);
    }

    /// Emits the resource updated notification through the active transport.
    pub fn notifyResourceUpdated(self: *Self, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void {
        var response_arena = std.heap.ArenaAllocator.init(allocator);
        defer response_arena.deinit();
        const response_allocator = response_arena.allocator();

        var params: std.json.ObjectMap = .empty;
        try params.put(response_allocator, "uri", .{ .string = uri });
        try self.sendNotification(io, allocator, "notifications/resources/updated", .{ .object = params });
    }

    /// Emits the prompts changed notification through the active transport.
    pub fn notifyPromptsChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/prompts/list_changed", null);
    }

    /// Serializes and sends a JSON-RPC message through the active transport, mapping allocation failure to protocol errors.
    pub fn sendResponse(self: *Self, io: std.Io, allocator: std.mem.Allocator, message: jsonrpc.Message) !void {
        if (self.transport) |t| {
            const json = jsonrpc.serializeMessage(allocator, message) catch {
                self.logError(io, "Failed to serialize response");
                return;
            };
            defer allocator.free(json);
            self.appendAudit(allocator, self.auditEventForOutboundMessage(message, json));
            t.send(io, allocator, json) catch {
                self.logError(io, "Failed to send response");
                return;
            };
        }
    }

    /// Classifies and applies an MCP cancellation notification to the currently active request.
    fn handleCancellationNotification(self: *Self, io: std.Io, notification: jsonrpc.Notification, notification_correlation: *const correlation.Context) void {
        _ = io;
        var target_id = cancellationTargetId(notification.params) orelse {
            self.recordCancellationEvent("malformed", correlation.RequestId.absent(), null);
            self.appendAudit(self.allocator, .{
                .event = "cancellation",
                .direction = "inbound",
                .transport = self.transport_name,
                .mcp_method = notification.method,
                .correlation = auditCorrelation(notification_correlation),
                .ok = false,
                .is_error = true,
            });
            return;
        };
        const reason = cancellationReason(notification.params) orelse "client requested cancellation";

        var status: []const u8 = "unknown";
        var target_method: ?[]const u8 = null;
        if (self.active_request) |active| {
            if (requestIdEqual(active.request_id, target_id)) {
                target_method = active.method;
                if (active.cancellable) {
                    active.state.request(reason);
                    status = "requested_active";
                } else {
                    status = "not_cancellable";
                }
            }
        }
        if (std.mem.eql(u8, status, "unknown")) {
            if (self.completedRequestMethod(target_id)) |method| {
                status = "completed_late";
                target_method = method;
            }
        }

        self.recordCancellationEvent(status, target_id, target_method);
        self.appendAudit(self.allocator, .{
            .event = "cancellation",
            .direction = "inbound",
            .transport = self.transport_name,
            .mcp_method = notification.method,
            .mcp_request_id_type = target_id.typeName(),
            .mcp_request_id_value = target_id.valueString(),
            .correlation = auditCorrelation(notification_correlation),
            .ok = std.mem.eql(u8, status, "requested_active") or std.mem.eql(u8, status, "completed_late"),
            .is_error = std.mem.eql(u8, status, "unknown") or std.mem.eql(u8, status, "not_cancellable"),
        });
    }

    /// Appends an audit record when audit logging is enabled; audit failures never touch stdout or fail the request.
    fn appendAudit(self: *Self, allocator: std.mem.Allocator, event: audit.Event) void {
        const writer = self.audit_writer orelse return;
        writer.append(allocator, event) catch |err| {
            if (self.observability) |observability| observability.recordAuditWriteError(@errorName(err));
            return;
        };
        if (self.observability) |observability| observability.recordAuditWriteOk();
    }

    /// Builds the audit record for an outbound JSON-RPC message after serialization.
    fn auditEventForOutboundMessage(self: *Self, message: jsonrpc.Message, payload: []const u8) audit.Event {
        const active = self.active_correlation;
        const corr = if (active) |context| auditCorrelation(context) else null;
        return switch (message) {
            .request => |request| blk: {
                var request_id = correlation.RequestId.from(request.id);
                break :blk .{
                    .event = "request",
                    .direction = "outbound",
                    .transport = self.transport_name,
                    .mcp_method = request.method,
                    .mcp_request_id_type = request_id.typeName(),
                    .mcp_request_id_value = request_id.valueString(),
                    .correlation = corr,
                    .payload = payload,
                };
            },
            .notification => |notification| .{
                .event = "notification",
                .direction = "outbound",
                .transport = self.transport_name,
                .mcp_method = notification.method,
                .correlation = corr,
                .payload = payload,
            },
            .response => |response| blk: {
                var request_id = correlation.RequestId.from(response.id);
                break :blk .{
                    .event = "response",
                    .direction = "outbound",
                    .transport = self.transport_name,
                    .mcp_method = if (active) |context| context.mcp_method else null,
                    .mcp_request_id_type = request_id.typeName(),
                    .mcp_request_id_value = request_id.valueString(),
                    .correlation = corr,
                    .tool_name = if (active) |context| context.tool_name else null,
                    .ok = true,
                    .payload = payload,
                };
            },
            .error_response => |err| blk: {
                var request_id = correlation.RequestId.fromOptional(err.id);
                break :blk .{
                    .event = "response",
                    .direction = "outbound",
                    .transport = self.transport_name,
                    .mcp_method = if (active) |context| context.mcp_method else null,
                    .mcp_request_id_type = request_id.typeName(),
                    .mcp_request_id_value = request_id.valueString(),
                    .correlation = corr,
                    .tool_name = if (active) |context| context.tool_name else null,
                    .ok = false,
                    .is_error = true,
                    .payload = payload,
                };
            },
        };
    }

    /// Records a completed request id in a fixed-size ring for late cancellation classification.
    fn rememberCompletedRequest(self: *Self, request_id: correlation.RequestId, method: []const u8) void {
        if (request_id.kind == .absent) return;
        const index: usize = @intCast(self.completed_request_count % @as(u64, self.completed_requests.len));
        const slot = &self.completed_requests[index];
        slot.* = .{};
        slot.request_id.kind = request_id.kind;
        slot.request_id.integer = request_id.integer;
        slot.request_id.integer_text = request_id.integer_text;
        slot.request_id.integer_text_len = request_id.integer_text_len;
        if (request_id.kind == .string) {
            const len = @min(request_id.string.len, slot.request_id_string.len);
            @memcpy(slot.request_id_string[0..len], request_id.string[0..len]);
            slot.request_id_string_len = len;
            slot.request_id.string = slot.request_id_string[0..len];
        }
        slot.method_len = @min(method.len, slot.method.len);
        @memcpy(slot.method[0..slot.method_len], method[0..slot.method_len]);
        self.completed_request_count +|= 1;
    }

    /// Finds the method for a recently completed request id, if still retained.
    fn completedRequestMethod(self: *Self, request_id: correlation.RequestId) ?[]const u8 {
        const retained: usize = @intCast(@min(self.completed_request_count, @as(u64, self.completed_requests.len)));
        var offset: usize = 0;
        while (offset < retained) : (offset += 1) {
            const index: usize = @intCast((self.completed_request_count - 1 - @as(u64, offset)) % @as(u64, self.completed_requests.len));
            const slot = &self.completed_requests[index];
            if (requestIdEqual(slot.request_id, request_id)) return slot.method[0..slot.method_len];
        }
        return null;
    }

    /// Records a cancellation event into observability state when available.
    fn recordCancellationEvent(self: *Self, status: []const u8, request_id: correlation.RequestId, method: ?[]const u8) void {
        if (self.observability) |observability| {
            observability.recordCancellation(status, request_id.typeName(), request_id.valueString(), method);
        }
    }

    /// Records a startup phase range relative to the bootstrap start time.
    pub fn recordStartupPhaseRange(self: *Self, name: []const u8, phase_start_ns: i128, phase_end_ns: i128) void {
        const observability = self.observability orelse return;
        const startup_start_ns = self.startup_started_ns orelse phase_start_ns;
        observability.recordStartupPhase(name, elapsedMs(startup_start_ns, phase_start_ns), elapsedMs(phase_start_ns, phase_end_ns));
    }

    /// Allocates the next process-local request correlation context.
    fn nextCorrelation(self: *Self, request_id: correlation.RequestId, method: []const u8, tool_name: ?[]const u8) correlation.Context {
        return self.correlation_generator.next(request_id, method, tool_name);
    }

    /// Writes request-scoped diagnostics with compact correlation fields.
    fn logWithCorrelation(self: *Self, io: std.Io, context: *const correlation.Context, message: []const u8) void {
        var request_id_buffer: [64]u8 = undefined;
        const request_id = context.request_id.compactValue(&request_id_buffer);
        var prefix_buffer: [256]u8 = undefined;
        const prefix = logging.formatCorrelationPrefix(&prefix_buffer, .{
            .trace_id = context.compactTrace(),
            .request_id = request_id,
            .method = context.mcp_method,
            .tool_name = context.tool_name,
        });
        var line_buffer: [768]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "[{s}] {s}", .{ prefix, message }) catch message;
        self.log(io, line);
    }

    /// Writes diagnostic text to stderr when stdio transport owns the error stream.
    fn log(self: *Self, io: std.Io, message: []const u8) void {
        if (self.stdio_transport) |t| {
            t.writeStderr(io, message);
        }
    }

    /// Formats a server log error message without taking ownership of the input text.
    fn logError(self: *Self, io: std.Io, message: []const u8) void {
        if (self.stdio_transport) |t| {
            var buf: [512]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "ERROR: {s}", .{message}) catch message;
            t.writeStderr(io, formatted);
        }
    }
};

/// Returns whether a foreground request method can cooperatively observe cancellation.
fn isCancellableMethod(method: []const u8) bool {
    _ = method;
    // The current stdio and HTTP transports dispatch inbound messages serially.
    // A notifications/cancelled message for an active request cannot be handled
    // until that request returns, so no normal request should receive a live
    // cooperative cancellation token. Runtime jobs remain cancellable through
    // tasks/cancel because those jobs run outside the foreground request.
    return false;
}

/// Extracts the target request id from an MCP cancellation notification.
fn cancellationTargetId(params: ?std.json.Value) ?correlation.RequestId {
    const value = params orelse return null;
    if (value != .object) return null;
    const raw_id = value.object.get("requestId") orelse return null;
    return switch (raw_id) {
        .integer => |integer| correlation.RequestId.from(.{ .integer = integer }),
        .string => |string| correlation.RequestId.from(.{ .string = string }),
        else => null,
    };
}

/// Extracts the optional human-readable cancellation reason.
fn cancellationReason(params: ?std.json.Value) ?[]const u8 {
    const value = params orelse return null;
    if (value != .object) return null;
    const reason = value.object.get("reason") orelse return null;
    return if (reason == .string) reason.string else null;
}

/// Compares normalized MCP request ids without conflating integer and string forms.
fn requestIdEqual(left: correlation.RequestId, right: correlation.RequestId) bool {
    if (left.kind != right.kind) return false;
    return switch (left.kind) {
        .integer => left.integer == right.integer,
        .string => std.mem.eql(u8, left.string, right.string),
        .absent => true,
    };
}

/// Captures adapter correlation metadata for the audit writer.
fn auditCorrelation(context: *const correlation.Context) audit.Correlation {
    return .{
        .schema_version = 1,
        .mcp_request_id_type = context.request_id.typeName(),
        .mcp_request_id_value = context.request_id.valueString(),
        .mcp_method = context.mcp_method,
        .tool_name = context.tool_name,
        .trace_id = context.traceId(),
        .span_id = context.spanId(),
        .parent_span_id = context.parent_span_id,
        .tool_call_id = context.toolCallId(),
    };
}

/// Monotonic nanoseconds for latency and startup phase measurements.
fn monotonicNowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

/// Converts a monotonic range to milliseconds, saturating pathological overflow.
fn elapsedMs(start_ns: i128, end_ns: i128) u64 {
    if (end_ns <= start_ns) return 0;
    const milliseconds = @divTrunc(end_ns - start_ns, std.time.ns_per_ms);
    return std.math.cast(u64, milliseconds) orelse std.math.maxInt(u64);
}

/// App-facing protocol helper adapter bound to the currently executing tools/call.
pub const ProtocolClientAdapter = protocol_client.Adapter(Server);
