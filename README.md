# nyasgz

A gzip file reader with no dependencies.

*Just for learning.*

---

## Usage

- importing

```zig
const nyasgz = @import("nyasgz");
```

- read gzip file content

```zig
const allocator: std.mem.Allocator = ...;
const file_reader: std.fs.File.Reader = ...;

var gz: nyasgz.gzip.FileReader = try .init(allocator, &file_reader);
defer gz.deinit(allocator);

const content: std.ArrayList(u8) = .init;
while (true) {
    const byte = try gz.decoder.readByte() orelse break;
    try content.append(allocator, byte);
}
```

```
```
```
```
