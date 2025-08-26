/// array starts with code 257 and ends with 285, 
/// the elements are tuples of extra bit count and the base length when extra bits = 0.
///
/// Example: code = 277, extra bits = 9, then
/// the base length = code_length[277-257].@"1" = 67, and the actual length = 67 + 9.
pub const code_length = [_]struct {u8, u16} {
    .{0, 3}, .{0, 4}, .{0, 5}, .{0, 6}, .{0, 7}, .{0, 8}, .{0, 9}, .{0, 10},
    .{1, 11}, .{1, 13}, .{1, 15}, .{1, 17}, 
    .{2, 19}, .{2, 23}, .{2, 27}, .{2, 31},
    .{3, 35}, .{3, 43}, .{3, 51}, .{3, 59},
    .{4, 67}, .{4, 83}, .{4, 99}, .{4, 115},
    .{5, 131}, .{5, 163}, .{5, 195}, .{5, 227},
    .{0, 258},
};

/// array starts with 0 and ends with 29,
/// the elements are tuples of extra bit count and the base distance when extra bits = 0.
/// Example: code = 11, extra bits = 12, then
/// the base length = code_distance[11].@"1" = 49, the actual distance = 49 + 12
pub const code_distance = [_]struct {u8, u16} {
    .{0, 1}, .{0, 2}, .{0, 3}, .{0, 4},
    .{1, 5}, .{1, 7},
    .{2, 9}, .{2, 13},
    .{3, 17}, .{3, 25},
    .{4, 33}, .{4, 49},
    .{5, 65}, .{5, 97},
    .{6, 129}, .{6, 193},
    .{7, 257}, .{7, 385},
    .{8, 513}, .{8, 769},
    .{9, 1025}, .{9, 1537},
    .{10, 2049}, .{10, 3073},
    .{11, 4097}, .{11, 6145},
    .{12, 8193}, .{12, 12289},
    .{13, 16385}, .{13, 24577},
};


test "check code tables" {
    const checkCodeTable = struct {
        fn foo(table: []const struct {u8, u16}) !void {
            const expectEqual = @import("std").testing.expectEqual;
            var idx: u16 = 1;
            while (idx < table.len) : (idx += 1) {
                const check = table[idx - 1];
                const expect = table[idx].@"1";
                if (expect == 258) continue; // exception for the last element in code_length
                try expectEqual(table[idx].@"1", check.@"1" + (@as(u16, 1) << @truncate(check.@"0")));
            }
        }
    }.foo;

    try checkCodeTable(&code_length);
    try checkCodeTable(&code_distance);
}

