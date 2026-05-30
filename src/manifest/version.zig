//! Build-time injected manifest/version contract shared by CLI, server metadata, and release tooling.
const build_options = @import("zigars_build_options");

/// Semver string injected at build time; never empty in a well-formed build.
pub const string = build_options.version;
