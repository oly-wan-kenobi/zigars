const text_edits = @import("edit_zls_text_edits.zig");
const workspace_edits = @import("edit_zls_workspace_edits.zig");

pub const WorkspaceEditProvenance = workspace_edits.WorkspaceEditProvenance;

pub const textEditToolValue = text_edits.textEditToolValue;
pub const textEditToolValueForDocument = text_edits.textEditToolValueForDocument;
pub const previewTextEditResponse = text_edits.previewTextEditResponse;
pub const applyTextEditResponseToFile = text_edits.applyTextEditResponseToFile;

pub const workspaceEditValue = workspace_edits.workspaceEditValue;
pub const workspaceEditValueForDocument = workspace_edits.workspaceEditValueForDocument;
pub const workspaceEditValueForDocumentWithProvenance = workspace_edits.workspaceEditValueForDocumentWithProvenance;
pub const workspaceEditFileValue = workspace_edits.workspaceEditFileValue;
pub const workspaceEditFileValueForDocument = workspace_edits.workspaceEditFileValueForDocument;
pub const applyEditsForUri = workspace_edits.applyEditsForUri;
