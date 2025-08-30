const std = @import("std");

const Dictionary = @This();


buf: [32 * 1024]u8,
next_index: u15 = 0,
full_filled: bool = false,


/// will not set .buf
pub fn init(self: *Dictionary) void {
    self.next_index = 0;
    self.full_filled = false;
}

pub fn append(self: *Dictionary, byte: u8) void {
    self.buf[self.next_index] = byte;
    self.next_index +%= 1;
    if (self.next_index == 0) self.full_filled = true; // already filled 23KiB data
}

pub fn get(self: Dictionary, distance: u15) ?u8 {
    const index = self.next_index -% distance;
    if (!self.full_filled and index >= self.next_index) return null;
    return self.buf[index];
}

