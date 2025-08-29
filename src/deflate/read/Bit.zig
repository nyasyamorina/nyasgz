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

pub fn readLeBits(self: *Bit, bit_count: u5) Reader.Error!u16 {
    assert(bit_count <= 16);

    var res: u16 = 0;
    var getted_bc: u5 = 0;
    while (getted_bc < bit_count) {
        if (self.remain_bit_count == 0) {
            try self.inner.readSliceAll(@ptrCast(&self.current_byte));
            // self.remain_bits = 8 = 0;
        }
        const available_bc: u16 = if (self.remain_bit_count > 0) self.remain_bit_count else 8;
        const available_bits = self.current_byte >> -%self.remain_bit_count; // = current_byte >> (8 - remain_bit_count)

        const get_bc = @min(bit_count - getted_bc, available_bc);
        res |= @as(u16, available_bits) << @truncate(getted_bc);
        getted_bc += get_bc;
        self.remain_bit_count = @truncate(available_bc - get_bc);
    }

    const mask = std.math.shl(u16, 1, bit_count) -% 1;
    return res & mask;
}

pub fn readBeBits(self: *Bit, bit_count: u5) Reader.Error!u16 {
    const bits = try self.readLeBits(bit_count);
    if (bits == 0) return 0;
    return @bitReverse(bits) >> @truncate(16 - bit_count);
}

pub fn readBit(self: *Bit) Reader.Error!u1 {
    if (self.remain_bit_count == 0) {
        try self.inner.readSliceAll(@ptrCast(&self.current_byte));
        //self.remain_bit_count = 8 = 0;
    }
    const bit: u1 = @truncate(self.current_byte >> -%self.remain_bit_count);
    self.remain_bit_count -%= 1;
    return bit;
}

pub fn drainCurrentByte(self: *Bit) void {
    self.remain_bit_count = 0;
}


test "nyasgz.defalte.read.Bit" {
    const content = [_]u8 {0b11000110, 0b10101011, 0b10101010, 0b00000010, 1};
    var r: Reader = .fixed(&content);

    var bit_reader: Bit = .init(&r);
    try std.testing.expectEqual(0b0, try bit_reader.readLeBits(1));
    try std.testing.expectEqual(0b11, try bit_reader.readLeBits(2));
    try std.testing.expectEqual(0b000, try bit_reader.readLeBits(3));
    try std.testing.expectEqual(0b1111, try bit_reader.readLeBits(4));
    try std.testing.expectEqual(0xAAAA, try bit_reader.readLeBits(16));
    bit_reader.drainCurrentByte();
    try std.testing.expectEqual(1, try bit_reader.readLeBits(8));
}

