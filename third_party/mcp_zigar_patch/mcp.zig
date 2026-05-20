//! Zigar-local MCP wrapper.
//!
//! Most MCP APIs are re-exported from the pinned upstream dependency. The server
//! and tools modules are tracked local patches so zigar can attach an explicit
//! deinitializer to owned tool results after `tools/call` response serialization.

const upstream = @import("mcp_upstream");

pub const report = upstream.report;
pub const version_info = upstream.version_info;

pub const ISSUES_URL = upstream.ISSUES_URL;
pub const VERSION = upstream.VERSION;

pub const reportError = upstream.reportError;
pub const reportErrorMessage = upstream.reportErrorMessage;

pub const protocol = upstream.protocol;
pub const types = upstream.types;
pub const jsonrpc = upstream.jsonrpc;
pub const schema = upstream.schema;

pub const transport = upstream.transport;
pub const StdioTransport = upstream.StdioTransport;
pub const HttpTransport = upstream.HttpTransport;
pub const Transport = upstream.Transport;

pub const server = @import("server.zig");
pub const Server = server.Server;
pub const ServerConfig = server.ServerConfig;

pub const tools = @import("tools.zig");
pub const Tool = tools.Tool;
pub const ToolBuilder = tools.ToolBuilder;
pub const ToolResult = tools.ToolResult;

pub const resources = upstream.resources;
pub const Resource = upstream.Resource;
pub const ResourceTemplate = upstream.ResourceTemplate;

pub const prompts = upstream.prompts;
pub const Prompt = upstream.Prompt;
pub const PromptMessage = upstream.PromptMessage;

pub const client = upstream.client;
pub const Client = upstream.Client;
pub const ClientConfig = upstream.ClientConfig;
pub const elicitation = upstream.elicitation;
pub const roots = upstream.roots;
pub const sampling = upstream.sampling;

pub const utils = upstream.utils;
pub const errors = upstream.errors;
pub const logging = upstream.logging;
pub const progress = upstream.progress;
