const builtin = @import("builtin");
const std = @import("std");

const Decoder = @This();
const Bit = @import("Bit.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const big_endian = builtin.cpu.arch.endian() == .big;
const Reader = std.Io.Reader;


bit: Bit,
is_last_block: bool,
state: State,
err: ?Error,


pub const State = union(enum) {
    non_compressed: NonCompressedState,
    fixed_compressed: FixedCompressedState,
    dynamic_compressed: DynamicCompressedState,
    rest: void,
};
pub const StateTag = std.meta.Tag(State);

pub const NonCompressedState = struct {
    length: u16,
    current: u16 = 0,
};

pub const FixedCompressedState = struct {

};

pub const DynamicCompressedState = struct {

};

pub const Error = error {
    InvalidBlockType,
    NonCompressedBlockLengthCheckFailed,
};

pub fn init(a: Allocator, r: *Reader) Decoder {
    _ = a;
    return .{
        .bit = .init(r),
        .is_last_block = false,
        .state = .rest,
        .err = null,
    };
}

pub fn deinit(self: Decoder, a: Allocator) void {
    _ = self;
    _ = a;
}

pub fn is_finished(self: Decoder) bool {
    return self.is_last_block and self.state == .rest;
}

pub fn readByte(self: *Decoder) Reader.Error!u8 {
    if (self.state == .rest) {
        if (self.is_last_block) return Reader.Error.EndOfStream;
        try self.startNextBlock();
    }
    const byte = switch (self.state) {
        .non_compressed => |*s| try self.readNonCompressedByte(s),
        .fixed_compressed => |*s| try self.readFixedCompressedByte(s),
        .dynamic_compressed => |*s| try self.readDynamicCompressedByte(s),
        .rest => unreachable,
    };
    return byte;
}

fn startNextBlock(self: *Decoder) Reader.Error!void {
    self.is_last_block = try self.bit.readInt(u1, 1) != 0;
    const block_type = try self.bit.readInt(u2, 2);
    switch (block_type) {
        0 => try self.startNonCompressedBlock(),
        1 => try self.startFixedCompressedBlock(),
        2 => try self.startDynamicCompressedBlock(),
        3 => {
            self.err = Error.InvalidBlockType;
            return Reader.Error.ReadFailed;
        },
    }
}

fn startNonCompressedBlock(self: *Decoder) Reader.Error!void {
    self.bit.drainCurrentByte();
    const len = try readLe(u16, self.bit.inner);
    const nlen = try readLe(u16, self.bit.inner);

    self.state = .{ .non_compressed = .{ .length = len } };
    if (~nlen != len) {
        self.err = Error.NonCompressedBlockLengthCheckFailed;
        return Reader.Error.ReadFailed;
    }
}

fn startFixedCompressedBlock(self: *Decoder) Reader.Error!void {
    self.state = .{ .fixed_compressed = .{} };
}

fn startDynamicCompressedBlock(self: *Decoder) Reader.Error!void {
    _ = self;
}

fn readNonCompressedByte(self: *Decoder, s: *NonCompressedState) Reader.Error!u8 {
    const len = s.length;
    const curr = &s.current;
    assert(len > curr.*);

    assert(self.bit.remain_bit_count == 0);
    var res: u8 = undefined;
    try self.bit.inner.readSliceAll(@ptrCast(&res));

    curr.* += 1;
    if (curr.* >= len) self.state = .rest; // block end
    return res;
}

fn readFixedCompressedByte(self: *Decoder, s: *FixedCompressedState) Reader.Error!u8 {
    _ = self;
    _ = s;
    return 0;
}

fn readDynamicCompressedByte(self: *Decoder, s: *DynamicCompressedState) Reader.Error!u8 {
    _ = self;
    _ = s;
    return 0;
}


fn readLe(comptime T: type, r: *Reader) Reader.Error!T {
    var tmp: T = undefined;
    try r.readSliceAll(std.mem.asBytes(&tmp));
    return if (big_endian) @byteSwap(tmp) else tmp;
}

