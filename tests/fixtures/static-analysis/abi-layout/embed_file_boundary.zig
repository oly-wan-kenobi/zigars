pub const EmbedFileBoundary = extern struct {
    bytes: *const [@embedFile("../../outside-workspace.txt").len]u8,
};
