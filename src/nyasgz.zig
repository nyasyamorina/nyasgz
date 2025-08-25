pub const gzip = @import("gzip.zig");
pub const deflate = @import("deflate.zig");

test {
    const testing = @import("std").testing;
    testing.refAllDeclsRecursive(@This());
}

