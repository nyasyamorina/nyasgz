const std = @import("std");

const assert = std.debug.assert;
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;


pub const BitReader = struct {
    inner: *Reader,
    current_byte: u8,
    remain_bit_count: u3,

    pub fn init(r: *Reader) BitReader {
        return .{
            .inner = r,
            .current_byte = undefined,
            .remain_bit_count = 0,
        };
    }

    pub fn readInt(self: *BitReader, comptime Int: type) Reader.Error!Int {
        comptime assert(@typeInfo(Int) == .int);

        var res: Int = 0;
        var getted_bc: u16 = 0;
        const target_bc = @typeInfo(Int).int.bits;
        while (getted_bc < target_bc) {
            if (self.remain_bit_count == 0) {
                try self.inner.readSliceAll(@ptrCast(&self.current_byte));
                // self.remain_bits = 8 = 0;
            }
            const available_bc: u16 = if (self.remain_bit_count > 0) self.remain_bit_count else 8;
            const available_bits = self.current_byte >> -%self.remain_bit_count; // = current_byte >> (8 - remain_bit_count)

            const get_bc = @min(target_bc - getted_bc, available_bc);
            res |= nyasIntCast(Int, available_bits) << @truncate(getted_bc);
            getted_bc += get_bc;
            self.remain_bit_count = @truncate(available_bc - get_bc);
        }
        return res;
    }

    pub fn drainCurrentByte(self: *BitReader) void {
        self.remain_bit_count = 0;
    }
};


fn nyasIntCast(comptime Int: type, int: anytype) Int {
    comptime assert(@typeInfo(Int) == .int);
    comptime assert(@typeInfo(@TypeOf(int)) == .int);
    const src_bits = @typeInfo(@TypeOf(int)).int.bits;
    const dst_bits = @typeInfo(Int).int.bits;
    return if (src_bits > dst_bits) 
        @truncate(int) 
    else 
        @as(std.meta.Int(@typeInfo(Int).int.signedness, src_bits), @bitCast(int))
    ;
}


test "BitReader" {
    const content = [_]u8 {0b11000110, 0b10101011, 0b10101010, 0b00000010, 1};
    var r: Reader = .fixed(&content);

    var br: BitReader = .init(&r);
    try std.testing.expectEqual(0b0, try br.readInt(u1));
    try std.testing.expectEqual(0b11, try br.readInt(u2));
    try std.testing.expectEqual(0b000, try br.readInt(u3));
    try std.testing.expectEqual(0b1111, try br.readInt(u4));
    try std.testing.expectEqual(0xAAAA, try br.readInt(u16));
    br.drainCurrentByte();
    try std.testing.expectEqual(1, try br.readInt(u1));
}

