Ever wanted a zig allocator that could allocate all the free space of your HDD? Look no further! Really though, don't. Unless you have a specific need for this, you likely don't need it ;)

I created this allocator (POSIX systems only right now) for the purpose of single, *very* large allocations. Think lots and lots of math with hundreds of gigabytes in each array.

It is advised that you use ReleaseFast/ReleaseSmall when using this library. When using Debug/ReleaseSafe, the allocated memory is set to `undefined` by the Allocator interface, which may take a while on large allocations.

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const falloc = @import("falloc");

pub fn main() !void {
    const gpa: Allocator = falloc.allocator;

    // 256 GiB of memory to work with
    const mem = try gpa.alloc(u8, 1 << 38);
    defer gpa.free(mem);

    // In a real-world use case scenario, this would be better utilized.
    const hello = "Hello, World!\n";
    @memcpy(mem[0..hello.len], hello);
    std.debug.print("{s}", .{mem[0..hello.len]});
}
```
