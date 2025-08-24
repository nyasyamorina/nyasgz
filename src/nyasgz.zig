pub const gzip = @import("gzip.zig");

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}

