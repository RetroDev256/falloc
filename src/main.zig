const std = @import("std");
const Allocator = std.mem.Allocator;
const Falloc = @import("Falloc");

pub fn main() !void {
    const gpa: Allocator = Falloc.allocator;
    const mem = try gpa.alloc(u8, 1 << 30); // 1 GiB
    try std.heap.testAllocator(gpa);
    const hello = "Hello, World!\n";
    @memcpy(mem[0..hello.len], hello);
    std.debug.print("{s}", .{mem[0..hello.len]});
}
