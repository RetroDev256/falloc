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
