Ever wanted a zig allocator that could allocate all the free space of your HDD? Look no further! Really though, don't. Unless you have a specific need for this, you likely don't need it ;)

I created this allocator (POSIX systems only right now) for the purpose of single, *very* large allocations. Think lots and lots of math with hundreds of gigabytes in each array.

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Falloc = @import("Falloc");

pub fn main() !void {
    const gpa: Allocator = Falloc.allocator;
    // 256 GiB (may take a while, look at disk IO for your progress bar lol)
    const mem = try gpa.alloc(u8, 1 << 38);
    defer gpa.free(mem);

    // In a real-world use case scenario, this would be better utilized.
    const hello = "Hello, World!\n";
    @memcpy(mem[0..hello.len], hello);
    std.debug.print("{s}", .{mem[0..hello.len]});
}
```
