const std = @import("std");

const Reader = std.Io.Reader;
const assert = std.debug.assert;
const Bit = @This();


inner: *Reader,
current_byte: u8,
remain_bit_count: u3,

pub fn init(r: *Reader) Bit {
    return .{
        .inner = r,
        .current_byte = undefined,
        .remain_bit_count = 0,
    };
}

pub fn readInt(self: *Bit, comptime Int: type, bit_count: u16) Reader.Error!Int {
    comptime assert(@typeInfo(Int) == .int);
    assert(@typeInfo(Int).int.bits >= bit_count);

    var res: Int = 0;
    var getted_bc: u16 = 0;
    while (getted_bc < bit_count) {
        if (self.remain_bit_count == 0) {
            try self.inner.readSliceAll(@ptrCast(&self.current_byte));
            // self.remain_bits = 8 = 0;
        }
        const available_bc: u16 = if (self.remain_bit_count > 0) self.remain_bit_count else 8;
        const available_bits = self.current_byte >> -%self.remain_bit_count; // = current_byte >> (8 - remain_bit_count)

        const get_bc = @min(bit_count - getted_bc, available_bc);
        res |= nyasIntCast(Int, available_bits) << @truncate(getted_bc);
        getted_bc += get_bc;
        self.remain_bit_count = @truncate(available_bc - get_bc);
    }

    const mask = unbounedShl(Int, 1, bit_count) -% 1;
    return res & mask;
}

pub fn drainCurrentByte(self: *Bit) void {
    self.remain_bit_count = 0;
}


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

fn unbounedShl(comptime Int: type, lhs: Int, rhs: u16) Int {
    comptime assert(@typeInfo(Int) == .int);
    assert(rhs >= 0);
    return if (rhs >= @typeInfo(Int).int.bits)
        0
    else
        lhs << @truncate(rhs)
    ;
}


test "nyasgz.defalte.read.Bit" {
    const content = [_]u8 {0b11000110, 0b10101011, 0b10101010, 0b00000010, 1};
    var r: Reader = .fixed(&content);

    var bit_reader: Bit = .init(&r);
    try std.testing.expectEqual(0b0, try bit_reader.readInt(u1, 1));
    try std.testing.expectEqual(0b11, try bit_reader.readInt(u2, 2));
    try std.testing.expectEqual(0b000, try bit_reader.readInt(u3, 3));
    try std.testing.expectEqual(0b1111, try bit_reader.readInt(u4, 4));
    try std.testing.expectEqual(0xAAAA, try bit_reader.readInt(u16, 16));
    bit_reader.drainCurrentByte();
    try std.testing.expectEqual(1, try bit_reader.readInt(u8, 8));
}

