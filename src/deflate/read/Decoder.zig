const builtin = @import("builtin");
const std = @import("std");

const Decoder = @This();
const Bit = @import("Bit.zig");
const common = @import("../common.zig");
const Dictionary = @import("../Dictionary.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const big_endian = builtin.cpu.arch.endian() == .big;
const stableSort = std.mem.sort;
const Reader = std.Io.Reader;


bit: Bit,
is_last_block: bool,
huffman: *Huffman,
dictionary: *Dictionary,
state: State,
err: ?Error,


pub const State = union(enum) {
    non_compressed: NonCompressedState,
    compressed: CompressedState,
    rest: void,
};
pub const StateTag = std.meta.Tag(State);

pub const NonCompressedState = struct {
    length: u16,
    count: u16 = 0,

    pub fn init(b: *Bit) Reader.Error!NonCompressedState {
        b.drainCurrentByte();
        const len = try readLe(u16, b.inner);
        const nlen = try readLe(u16, b.inner);

        if (~nlen != len) return Reader.Error.ReadFailed;
        return .{ .length = len };
    }

    /// null means the block is ended
    pub fn readByteMayEnd(self: *NonCompressedState, b: *Bit) Reader.Error!?u8 {
        if (self.count >= self.length) return null;

        var byte: u8 = undefined;
        try b.inner.readSliceAll(@ptrCast(&byte));
        self.count += 1;
        return byte;
    }
};

pub const CompressedState = struct {
    huffman: *Huffman,
    backwarding: ?struct {
        backward: Huffman.Action.Backward,
        count: u9 = 0,
    } = null,

    pub fn initFixed(h: *Huffman) CompressedState {
        h.* = .fixed;
        return .{ 
            .huffman = h,
        };
    }

    pub fn initDynamic(h: *Huffman, b: *Bit) (Reader.Error || Error)!CompressedState {
        try h.readFrom(b);
        return .{
            .huffman = h,
        };
    }

    /// null means the block is ended
    pub fn readByteMayEnd(self: *CompressedState, b: *Bit, d: *Dictionary) (Reader.Error || Error)!?u8 {
        while (true) {
            if (self.backwarding) |bw| {
                if (bw.count >= bw.backward.length) {
                    self.backwarding = null;
                } else {
                    self.backwarding.?.count += 1;
                    if (d.get(bw.backward.distance)) |byte| {
                        return byte;
                    } else {
                        return Error.InvalidDistanceCode;
                    }
                }
            }

            const action = try self.huffman.readAction(b);
            switch (action) {
                .literal => |byte| return byte,
                .block_end => return null,
                .backward => |bw| self.backwarding = .{ .backward = bw },
            }
        }
    }
};

pub const Huffman = struct {
    lit: LitTree,
    distance: DistanceTree,

    const CodeLengthTree = Tree(u3, u5, common.code_length_code_count);
    /// Huffman tree for literal/length
    pub const LitTree = Tree(u4, u9, common.literal_length_count);
    /// Huffman tree for distance
    pub const DistanceTree = Tree(u4, u5, common.distance_count);

    /// build the literal/length or the distance Huffman tree
    fn Tree(comptime CodeLength: type, comptime Value: type, value_count: Value) type {
        assert(@typeInfo(Value) == .int and @typeInfo(Value).int.signedness == .unsigned);
        assert(@typeInfo(CodeLength) == .int and @typeInfo(CodeLength).int.signedness == .unsigned);
        const Code = std.meta.Int(.unsigned, @as(u16, std.math.maxInt(CodeLength)) + 1);
        assert(@typeInfo(Value).int.bits <= @typeInfo(Code).int.bits);

        return struct {
            values: [value_count]ValueCodeLength,
            /// code length - 1 as index
            codes: [std.math.maxInt(CodeLength)]CodeValues,

            pub const ValueCodeLength = struct {
                value: Value,
                code_length: CodeLength,
            };
            pub const CodeValues = struct {
                code_start: Code,
                index_start: Value,
                length: Value,
            };

            fn fixed(fixed_info: []const struct {CodeLength, Value}) @This() {
                @setEvalBranchQuota(7500);
                var _fixed: @This() = undefined;

                var value: Value = 0;
                for (fixed_info) |info| {
                    const stop = value + info.@"1";
                    while (value < stop) : (value += 1) {
                        _fixed.values[value] = .{ .value = value, .code_length = info.@"0" };
                    }
                }

                _fixed.buildCodes();
                return _fixed;
            }

            pub fn buildCodes(self: *@This()) void {
                // sort working buffer by code length
                const lessThanFn = struct {
                    fn foo(_: void, lhs: ValueCodeLength, rhs: ValueCodeLength) bool {
                        return lhs.code_length < rhs.code_length;
                    }
                }.foo;
                stableSort(ValueCodeLength, &self.values, void {}, lessThanFn);

                // reset codes
                var cl: CodeLength = 1;
                while (cl != 0) : (cl +%= 1) {
                    self.codes[cl - 1] = .{ .code_start = 0, .index_start = 0, .length = 0 };
                }

                // skip values with 0 code length (not occur)
                var idx: Value = 0;
                while (true) : (idx += 1) {
                    if (idx >= self.values.len) {
                        return; // all lits have 0 code length
                    }
                    if (self.values[idx].code_length != 0) {
                        break;
                    }
                }

                // build codes
                cl = 1;
                var idx_s: Value = idx;
                var code_s: Code = 0;
                while (true) {
                    if (idx >= self.values.len or self.values[idx].code_length > cl) {
                        const len = idx - idx_s;
                        self.codes[cl - 1] = .{
                            .code_start = code_s,
                            .index_start = idx_s,
                            .length = len,
                        };
                        if (idx >= self.values.len) {
                            return;
                        } else {
                            const next_cl = self.values[idx].code_length;
                            idx_s = idx;
                            code_s = (code_s + len) << (next_cl - cl);
                            cl = next_cl;
                        }
                    } else {
                        idx += 1;
                    }
                }
            }

            pub fn ensureValid(self: @This()) Error!void {
                var code_len: CodeLength = 1;
                var max_code_len: CodeLength = 0;
                while (code_len != 0) : (code_len +%= 1) {
                    const codes = self.codes[code_len - 1];
                    if (codes.length == 0) continue;
                    max_code_len = code_len;
                    // check code length
                    const curr_max_code = codes.code_start + (codes.length - 1);
                    const curr_max_code_len = @typeInfo(Code).int.bits - @clz(curr_max_code);
                    if (curr_max_code_len > code_len) return Error.InvalidDynamicHuffmanBlock;
                }
                // check the max code with max code length should be all 1s
                if (max_code_len == 0) return Error.InvalidDynamicHuffmanBlock; // no codes
                const codes = self.codes[max_code_len - 1];
                const max_code = codes.code_start + (codes.length - 1);
                if (max_code & (max_code +% 1) != 0) return Error.InvalidDynamicHuffmanBlock;
            }

            pub fn decode(self: @This(), b: *Bit) (Reader.Error || Error)!Value {
                var code: Code = try b.readBit();
                var code_len: CodeLength = 1;
                while (true) : ({
                    code = (code << 1) | try b.readBit();
                    code_len += 1;
                }) {
                    const codes = self.codes[code_len - 1];
                    assert(code >= codes.code_start);
                    const index_offset = code - codes.code_start;
                    if (index_offset < codes.length) {
                        const index = codes.index_start + @as(Value, @truncate(index_offset));
                        return self.values[index].value;
                    } else if (code_len >= self.codes.len) {
                        return Error.InvalidHuffmanCode;
                    }
                }
            }
        };
    }

    /// the extra functionalities for code length tree
    pub const CodeLengthTreeExtra = struct {
        tree: *CodeLengthTree,
        last_set: ?u4 = null,

        pub const FillAction = struct {
            code_length: u4,
            fill_count: u8,
        };

        pub fn readFillAction(self: *CodeLengthTreeExtra, b: *Bit) (Reader.Error || Error)!FillAction {
            const code_len_code = self.tree.decode(b) catch |err| switch (err) {
                Error.InvalidHuffmanCode => return Error.InvalidDynamicHuffmanBlock,
                else => return err,
            };
            if (code_len_code < 16) {
                const code_len: u4 = @truncate(code_len_code);
                self.last_set = code_len;
                return .{ .code_length = code_len, .fill_count = 1 };
            } else if (code_len_code == 16) {
                if (self.last_set == null) {
                    return Error.InvalidDynamicHuffmanBlock;
                }
                const fill_count = try b.readLeBits(2) + 3;
                return .{ .code_length = self.last_set.?, .fill_count = @truncate(fill_count) };
            } else if (code_len_code < 19) {
                const fill_count = if (code_len_code == 17) 
                    try b.readLeBits(3) + 3
                else
                    try b.readLeBits(7) + 11
                ;
                self.last_set = 0;
                return .{ .code_length = 0, .fill_count = @truncate(fill_count) };
            } else {
                return Error.InvalidDynamicHuffmanBlock;
            }
        }

        pub fn readCodeLengthTree(self: CodeLengthTreeExtra, b: *Bit, code_length_code_length_count: u16) Reader.Error!void {
            var code_lens = std.mem.zeroes([self.tree.values.len]u3);
            var idx: u16 = 0;
            while (idx < code_length_code_length_count) : (idx += 1) {
                code_lens[idx] = @truncate(try b.readLeBits(3));
            }

            idx = 0;
            while (idx < self.tree.values.len) : (idx += 1) {
                const jdx = common.code_length_codes[idx];
                self.tree.values[jdx] = .{
                    .value = jdx,
                    .code_length = code_lens[idx],
                };
            }
        }
    };

    const fixed: Huffman = .{
        .lit = .fixed(&common.fixed_lit_tree_info),
        .distance = .fixed(&common.fixed_distance_tree_info),
    };

    pub fn readFrom(self: *Huffman, b: *Bit) (Reader.Error || Error)!void {
        const lit_count = try b.readLeBits(5) + 257;
        const dist_count = try b.readLeBits(5) + 1;
        const clcl_count = try b.readLeBits(4) + 4;
        if (lit_count > common.literal_length_count or
            dist_count > common.distance_count or
            clcl_count > common.code_length_code_count) {
            return Error.InvalidDynamicHuffmanBlock;
        }

        // read code length code tree
        var cl_tree: CodeLengthTree = undefined;
        var cl_extra: CodeLengthTreeExtra = .{ .tree = &cl_tree };
        try cl_extra.readCodeLengthTree(b, clcl_count);
        cl_tree.buildCodes();
        try cl_tree.ensureValid();

        // read lit tree
        var idx: u16 = 0;
        while (idx < lit_count) {
            var action = try cl_extra.readFillAction(b);
            while (action.fill_count > 0) : ({
                action.fill_count -= 1;
                idx += 1;
            }) {
                self.lit.values[idx] = .{ .value = @truncate(idx), .code_length = action.code_length };
            }
        }
        if (idx > lit_count) return Error.InvalidDynamicHuffmanBlock; // should read exactlly
        while (idx < common.literal_length_count) : (idx += 1) {
            self.lit.values[idx] = .{ .value = @truncate(idx), .code_length = 0 };
        }

        // read distance tree
        idx = 0;
        cl_extra.last_set = null; // reset state
        while (idx < dist_count) {
            var action = try cl_extra.readFillAction(b);
            while (action.fill_count > 0) : ({
                action.fill_count -= 1;
                idx += 1;
            }) {
                self.distance.values[idx] = .{ .value = @truncate(idx), .code_length = action.code_length };
            }
        }
        if (idx > dist_count) return Error.InvalidDynamicHuffmanBlock; // should read exactlly
        while (idx < common.distance_count) : (idx += 1) {
            self.distance.values[idx] = .{ .value = @truncate(idx), .code_length = 0 };
        }

        self.distance.buildCodes();
        try self.distance.ensureValid();
        self.lit.buildCodes();
        try self.lit.ensureValid();
    }

    pub const Action = union(enum) {
        literal: u8,
        block_end: void,
        backward: Backward,

        pub const Backward = struct {
            length: u9,
            distance: u15,
        };
    };

    pub fn readAction(self: Huffman, b: *Bit) (Reader.Error || Error)!Action {
        const lit = try self.lit.decode(b);
        if (lit < 256) {
            return .{ .literal = @truncate(lit) };
        } else if (lit == 256) {
            return .block_end;
        } else if (lit < common.literal_length_count) {
            const extra_len_count, const length_start = common.length_table[lit - 257];
            const extra_len = try b.readLeBits(extra_len_count);
            const length = length_start + @as(u9, @truncate(extra_len));

            const dist_code = try self.distance.decode(b);
            if (dist_code >= common.distance_count) return Error.InvalidDistanceCode;
            const extra_dist_len, const distance_start = common.distance_table[dist_code];
            const extra_dist = try b.readLeBits(extra_dist_len);
            const distance = distance_start + @as(u15, @truncate(extra_dist));

            return .{ .backward = .{ .length = length, .distance = distance } };
        } else {
            return Error.InvalidLiteralLengthCode;
        }
    }
};

pub const Error = error {
    InvalidBlockType,
    NonCompressedBlockLengthCheckFailed,
    InvalidDynamicHuffmanBlock,
    InvalidHuffmanCode,
    InvalidLiteralLengthCode,
    InvalidDistanceCode,
};

pub fn init(a: Allocator, r: *Reader) Allocator.Error!Decoder {
    const dict = try a.create(Dictionary);
    dict.init();
    return .{
        .bit = .init(r),
        .is_last_block = false,
        .huffman = try a.create(Huffman),
        .dictionary = dict,
        .state = .rest,
        .err = null,
    };
}

pub fn deinit(self: Decoder, a: Allocator) void {
    a.destroy(self.huffman);
    a.destroy(self.dictionary);
}

pub fn isFinished(self: Decoder) bool {
    return self.is_last_block and self.state == .rest;
}

/// null means deflate stream ended
pub fn readByte(self: *Decoder) Reader.Error!?u8 {
    while (true) {
        if (self.state == .rest) {
            if (self.is_last_block) return null;
            try self.startNextBlock();
        }

        const may_byte = switch (self.state) {
            .rest => unreachable,
            .non_compressed => |*state| state.readByteMayEnd(&self.bit),
            .compressed => |*state| state.readByteMayEnd(&self.bit, self.dictionary),
        } catch |err| return self.absorbErr(err);

        if (may_byte) |byte| {
            self.dictionary.append(byte);
            return byte;
        } else {
            self.state = .rest;
            continue;
        }
    }
}

// TODO: integrade with `Reader` interface
// TODO: better deflate stream ending

fn startNextBlock(self: *Decoder) Reader.Error!void {
    self.is_last_block = try self.bit.readLeBits(1) != 0;
    const block_type: u2 = @truncate(try self.bit.readLeBits(2));
    switch (block_type) {
        0 => self.state = .{ .non_compressed = try .init(&self.bit) },
        1 => self.state = .{ .compressed = .initFixed(self.huffman) },
        2 => {
            // ? compiler BUG: error: type '@Type(.enum_literal)' not a function
            //const state: CompressedState = .initDynamic(self.huffman, &self.bit) catch |err| return self.absorbErr(err);
            //                               ~^~~~~~~~~~~
            const state = CompressedState.initDynamic(self.huffman, &self.bit) catch |err| return self.absorbErr(err);
            self.state = .{ .compressed = state };
        },
        3 => {
            self.err = Error.InvalidBlockType;
            return Reader.Error.ReadFailed;
        },
    }
}

fn absorbErr(self: *Decoder, err: (Reader.Error || Error)) Reader.Error {
    switch (err) {
        Reader.Error.EndOfStream, Reader.Error.ReadFailed => return @errorCast(err),
        else => {
            self.err = @errorCast(err);
            return Reader.Error.ReadFailed;
        },
    }
}


fn readLe(comptime T: type, r: *Reader) Reader.Error!T {
    var tmp: T = undefined;
    try r.readSliceAll(std.mem.asBytes(&tmp));
    return if (big_endian) @byteSwap(tmp) else tmp;
}


test "read dynamic Huffman codes" {
    const expectEqual = std.testing.expectEqual;

    const content = [_]u8 {
        0xDC, 0x58, 0xEB, 0x72, 0xE3, 0x34, 0x14, 0xFE, 0xEF, 0xA7, 0x38, 0x94, 0x99, 0x4E, 0x02, 0x69,
        0x93, 0x14, 0x86, 0x85, 0xDE, 0x18, 0x93, 0xB8, 0x5B, 0x43, 0x6E, 0x93, 0xA4, 0x2D, 0x85, 0x61,
        0xBC, 0x8A, 0x2D, 0x37, 0x62, 0x6D, 0x2B, 0x58, 0xF2, 0x86, 0xC2, 0xF0, 0xEE, 0x9C, 0x23, 0x3B,
        0xB5, 0x53, 0x37, 0x94, 0x2E, 0xBB, 0x7F, 0xF0, 0xB4, 0xD3, 0xEA, 0x5C, 0xBE, 0x73, 0xD1, 0x77,
        0x24, 0x27, 0x9F, 0x8A,
    };
    var r: Reader = .fixed(&content);
    var b: Bit = .init(&r);
    _ = try b.readLeBits(3); // 100

    var huffman: Huffman = undefined;
    try huffman.readFrom(&b);

    try expectEqual(35, try huffman.lit.decode(&b));
    // TODO: more robust tests
}

