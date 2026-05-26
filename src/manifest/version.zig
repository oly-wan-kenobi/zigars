//! Build-time injected manifest/version contract shared by CLI, server metadata, and release tooling.
const build_options = @import("zigar_build_options");

pub const string = build_options.version;
