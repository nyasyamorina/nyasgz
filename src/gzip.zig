const builtin = @import("builtin");
const std = @import("std");

const big_endian = builtin.cpu.arch.endian() == .big;
const Reader = std.Io.Reader;
const File = std.fs.File;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;


pub const GzError = error {
    InvalidSignature,
    InvalidCompressionMethod,
    UnmatchedCrc16AndCrc32,
};

pub const GzBaseHeader = extern struct {
    signature: [2]u8 align(1),
    compression_method: GzCompressionMethod align(1),
    flag: GzFlag align(1),
    /// Unix time
    modified_time: u32 align(1),
    extra_flags: GzDeflateLevel align(1),
    os: GzFilesystem align(1),

    fn readFrom(r: *Reader) (Reader.Error || GzError)!GzBaseHeader {
        comptime std.debug.assert(@sizeOf(GzBaseHeader) == 10);
        var self: GzBaseHeader = undefined;
        try r.readSliceAll(std.mem.asBytes(&self));

        if (!std.mem.eql(u8, &self.signature, &GzHeaderInfo.signature)) {
            return GzError.InvalidSignature;
        } else if (self.compression_method != .deflate) {
            return GzError.InvalidCompressionMethod;
        }

        if (big_endian) {
            self.modified_time = @byteSwap(self.modified_time);
        }
        return self;
    }
};

pub const GzCompressionMethod = enum(u8) {
    deflate = 8,
    _
};

pub const GzFlag = packed struct(u8) {
    text: bool,
    hcrc: bool,
    extra: bool,
    name: bool,
    comment: bool,
    _reserved: u3,
};

pub const GzDeflateLevel = enum(u8) {
    none = 0,
    best = 2,
    fastest = 4,
    _
};

pub const GzFilesystem = enum(u8) {
    /// MS-DOS, OS/2, NT/Win32
    FAT = 0,
    Amiga = 1,
    /// or VMS
    OpenVMS = 2,
    Unix = 3,
    /// VM/CMS
    VM_CMS = 4,
    AtariOS = 5,
    /// OS/2, NT
    HPFS = 6,
    Macintosh = 7,
    ZSystem = 8,
    /// CP/M
    CP_M = 9,
    TOPS_20 = 10,
    NTFS = 11,
    QDOS = 12,
    ArconRISCOS = 13,
    Unknown = 255,
    _
};


pub const GzHeaderInfo = struct {
    may_text_content: bool,
    /// Unix time
    modified_time: u32,
    compression_level: GzDeflateLevel,
    os: GzFilesystem,
    extra_field: ?[]u8,
    file_name: ?[]u8,
    file_comment: ?[]u8,
    // the 2 least significant bytes in `crc32` in the end info
    crc16: ?u16,

    pub const signature = [2]u8 {0x1F, 0x8B};

    pub fn readFrom(a: Allocator, r: *Reader) (Allocator.Error || Reader.Error || GzError)!GzHeaderInfo {
        const base = try GzBaseHeader.readFrom(r);
        var self: GzHeaderInfo = .{
            .may_text_content = base.flag.text,
            .modified_time = base.modified_time,
            .compression_level = base.extra_flags,
            .os = base.os,
            .extra_field = null,
            .file_name = null,
            .file_comment = null,
            .crc16 = null,
        };
        errdefer self.deinit(a);

        if (base.flag.extra) {
            const len = try readLe(u16, r);
            self.extra_field = try a.alloc(u8, len);
            try r.readSliceAll(self.extra_field.?);
        }
        if (base.flag.name) {
            self.file_name = try readCStr(a, r);
        }
        if (base.flag.comment) {
            self.file_comment = try readCStr(a, r);
        }
        if (base.flag.hcrc) {
            self.crc16 = try readLe(u16, r);
        }

        return self;
    }

    pub fn deinit(self: GzHeaderInfo, allocator: Allocator) void {
        if (self.extra_field) |f| allocator.free(f);
        if (self.file_name) |n| allocator.free(n);
        if (self.file_comment) |c| allocator.free(c);
    }
};


pub const GzEndInfo = extern struct {
    /// crc32 of the uncompressed data
    crc32: u32,
    /// (actual size of the uncompressed data) % 2^32
    isize: u32,

    pub fn readFrom(r: *Reader) Reader.Error!GzEndInfo {
        return .{
            .crc32 = try readLe(u32, r),
            .isize = try readLe(u32, r),
        };
    }
};


pub const GzFile = struct {
    header: GzHeaderInfo,
    end: GzEndInfo,

    pub const InitError = Allocator.Error || Reader.Error || File.Reader.SeekError || File.Reader.SizeError || GzError;
    pub fn init(a: Allocator, r: *File.Reader) InitError!GzFile {
        const header: GzHeaderInfo = try .readFrom(a, &r.interface);
        errdefer header.deinit(a);

        // end info should be at the end of file
        const end_info_pos = try r.getSize() - 8;
        const curr_pos = r.pos;
        try r.seekTo(end_info_pos);
        const end: GzEndInfo = try .readFrom(&r.interface);
        try r.seekTo(curr_pos);

        if (header.crc16) |crc16| {
            if (crc16 != @as(u16, @truncate(end.crc32))) {
                return GzError.UnmatchedCrc16AndCrc32;
            }
        }
        return .{
            .header = header,
            .end = end,
        };
    }

    pub fn deinit(self: GzFile, a: Allocator) void {
        self.header.deinit(a);
    }
};


fn readLe(comptime T: type, r: *Reader) Reader.Error!T {
    var tmp: T = undefined;
    try r.readSliceAll(std.mem.asBytes(&tmp));
    return if (big_endian) @byteSwap(tmp) else tmp;
}

fn readCStr(a: Allocator, r: *Reader) (Allocator.Error || Reader.Error)![]u8 {
    var buf: ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    var byte: u8 = undefined;
    try r.readSliceAll(@ptrCast(&byte));
    while (byte != 0) {
        try buf.append(a, byte);
        try r.readSliceAll(@ptrCast(&byte));
    }

    return buf.toOwnedSlice(a);
}


test "GzFile" {
    const filename = "test.GzFile";
    const content = [_]u8 {
        0x1F, 0x8B, 8, 31, 0x78, 0x56, 0x34, 0x12, 2, 11, 4, 0, 1, 2, 3, 4,
        'a', 'b', 'c', 0, 'x', 'y', 'z', 0, 0x11, 0x66,
        '(', 'c', 'o', 'm', 'p', 'r', 'e', 's', 's', 'e', 'd', ' ', 'd', 'a', 't', 'a', ')',
        0x11, 0x66, 0x33, 0x22, 0x99, 0x88, 0x77, 0x66,
    };

    const cwd = std.fs.cwd();
    const wfile = try cwd.createFile(filename, .{ .truncate = true });
    defer cwd.deleteFile(filename) catch {};
    {
        defer wfile.close();
        try wfile.writeAll(&content);
    }

    const rfile = try cwd.openFile(filename, .{});
    defer rfile.close();
    var r = rfile.reader(&.{});

    const gz_file: GzFile = try .init(std.testing.allocator, &r);
    defer gz_file.deinit(std.testing.allocator);

    try std.testing.expectEqual(true, gz_file.header.may_text_content);
    try std.testing.expectEqual(0x12345678, gz_file.header.modified_time);
    try std.testing.expectEqual(GzDeflateLevel.best, gz_file.header.compression_level);
    try std.testing.expectEqual(GzFilesystem.NTFS, gz_file.header.os);
    try std.testing.expectEqualSlices(u8, &.{1, 2, 3, 4}, gz_file.header.extra_field.?);
    try std.testing.expectEqualStrings("abc", gz_file.header.file_name.?);
    try std.testing.expectEqualStrings("xyz", gz_file.header.file_comment.?);
    try std.testing.expectEqual(0x6611, gz_file.header.crc16.?);
    try std.testing.expectEqual(0x22336611, gz_file.end.crc32);
    try std.testing.expectEqual(0x66778899, gz_file.end.isize);
}

