const std = @import("std");
const logging = @import("logging.zig");

const Logger = logging.Logger;

test "disabled logger accepts messages without an IO sink" {
    const logger = Logger.disabled();
    logger.info("test", "ignored {s}", .{"message"});
}
