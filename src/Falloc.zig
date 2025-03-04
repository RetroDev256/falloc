const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

// TODO: manage context in an "always allocated" mapping to a file
// This context will allow things to be resized and freed and stuff

// TODO: ensure alloc properly aligns to more than just page size

pub const allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

fn alloc(_: *anyopaque, len: usize, _: Alignment, _: usize) ?[*]u8 {
    const fd = tmpfile() catch return null;
    errdefer std.posix.close(fd);
    std.posix.ftruncate(fd, @intCast(len)) catch return null;
    const mapping = std.posix.mmap(
        null,
        len,
        std.posix.PROT.WRITE | std.posix.PROT.READ | std.posix.PROT.SEM,
        .{ .UNINITIALIZED = true, .NORESERVE = true, .TYPE = .SHARED },
        fd,
        0,
    ) catch return null;
    return mapping.ptr;
}

fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = .{ memory, alignment, new_len, ret_addr };
    return false;
}

fn remap(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = .{ memory, alignment, new_len, ret_addr };
    return null;
}

fn free(_: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = .{ memory, alignment, ret_addr };
    // well frick
}

fn tmpfile() !std.posix.fd_t {
    const id = std.crypto.random.int(u128);
    const path = "/tmp/" ++ std.fmt.hex(id);
    const fd = try std.posix.open(path, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
        .EXCL = true,
    }, 0o600);
    errdefer std.posix.close(fd);
    try std.posix.unlink(path);
    return fd;
}
