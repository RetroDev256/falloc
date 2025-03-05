const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const PROT = std.posix.PROT;
const MAP = std.posix.MAP;

pub const allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

// This is the struct that stores information about the current allocation
// It is always at the end of the allocated memory
const Footer = struct {
    origin: [*]align(std.heap.page_size_min) u8,
    fd: std.posix.fd_t,

    const footer_align: Alignment = .fromByteUnits(@alignOf(Footer));

    // Get a pointer to where the footer is / should be
    fn acquire(data_ptr: [*]u8, data_len: usize) *Footer {
        const aligned_addr: usize = @intFromPtr(data_ptr);
        const footer_addr = footer_align.forward(aligned_addr + data_len);
        assert(footer_align.check(footer_addr));

        return @ptrFromInt(footer_addr);
    }

    // Writes the footer at the correct position for if it has moved
    fn writeAcquired(self: Footer, data_ptr: [*]u8, data_len: usize) void {
        acquire(data_ptr, data_len).* = self;
    }

    // Calculates the length that the allocation must be to
    // store and align both the memory and the footer
    fn overAllocLength(data_len: usize, data_align: Alignment) usize {
        const map_len = data_len + @sizeOf(Footer);
        return map_len + footer_align.toByteUnits() + data_align.toByteUnits();
    }

    // Calculates the length of the memory mapped region and returns a slice to it.
    // This works because the data length is always tied to the mapped length.
    fn mappedSlice(
        self: Footer,
        data_len: usize,
        data_align: Alignment,
    ) []align(std.heap.page_size_min) u8 {
        return self.origin[0..overAllocLength(data_len, data_align)];
    }
};

fn alloc(_: *anyopaque, len: usize, a: Alignment, _: usize) ?[*]u8 {
    const fd = tmpfile() catch return null;

    // Allocate enough space for the footer & proper alignment
    const over_alloc = Footer.overAllocLength(len, a);
    std.posix.ftruncate(fd, @intCast(over_alloc)) catch {
        std.posix.close(fd);
        return null;
    };

    // Allow our page to be readable, writable, and used for atomics
    const prot: u32 = PROT.WRITE | PROT.READ | PROT.SEM;
    // Our page must map directly to the temporary file on-disk
    const map: MAP = .{ .NORESERVE = true, .TYPE = .SHARED };

    const mapping = std.posix.mmap(null, over_alloc, prot, map, fd, 0) catch {
        std.posix.close(fd);
        return null;
    };

    // Set the footer so that we can resize, remap, and free
    Footer.acquire(mapping.ptr, len).* = .{
        .origin = mapping.ptr,
        .fd = fd,
    };

    // Align the memory correctly
    const data_addr = a.forward(@intFromPtr(mapping.ptr));
    assert(a.check(data_addr));

    return @ptrFromInt(data_addr);
}

fn resize(_: *anyopaque, memory: []u8, a: Alignment, new_len: usize, _: usize) bool {
    // Allocate enough space for the footer & proper alignment
    const over_alloc = Footer.overAllocLength(new_len, a);

    // Copy the footer because it's pointer may be invalidated
    const footer: Footer = Footer.acquire(memory.ptr, memory.len).*;
    const mapped_len = footer.mappedSlice(memory.len, a).len;

    if (new_len > memory.len) {
        // We must attempt to grow the file before we remap, otherwise we
        // will risk some bytes being mapped, but truncated from the file,
        // resulting in a bus error each time we read this memory.

        std.posix.ftruncate(footer.fd, over_alloc) catch return false;

        const mapping = std.posix.mremap(
            footer.origin,
            mapped_len,
            over_alloc,
            .{ .FIXED = true },
            footer.origin,
        ) catch return false;

        assert(mapping.ptr == footer.origin);
    } else {
        // We must attempt to remap before we shrink the file, otherwise we
        // will risk some bytes being mapped, but truncated from the file,
        // resulting in a bus error each time we read this memory.

        const mapping = std.posix.mremap(
            footer.origin,
            mapped_len,
            over_alloc,
            .{ .FIXED = true },
            footer.origin,
        ) catch return false;

        assert(mapping.ptr == footer.origin);

        // This is allowed to silently fail - further resizes will reattempt
        // to correctly size the file anyways, and it doesn't effect our
        // footer or memory mapping if it is a little large.
        std.posix.ftruncate(footer.fd, over_alloc) catch {};
    }

    // We have successfully resized our allocation, so now we need to update
    // the footer for later resize, remap, or free calls.
    footer.writeAcquired(footer.origin, new_len);

    return true;
}

fn remap(_: *anyopaque, memory: []u8, a: Alignment, new_len: usize, _: usize) ?[*]u8 {
    // Allocate enough space for the footer & proper alignment
    const over_alloc = Footer.overAllocLength(new_len, a);

    // Copy the footer because it's pointer may be invalidated
    const footer: Footer = Footer.acquire(memory.ptr, memory.len).*;
    const mapped_len = footer.mappedSlice(memory.len, a).len;

    var mapping: []align(std.heap.page_size_min) u8 = undefined;

    if (new_len > memory.len) {
        // We must attempt to grow the file before we remap, otherwise we
        // will risk some bytes being mapped, but truncated from the file,
        // resulting in a bus error each time we read this memory.

        std.posix.ftruncate(footer.fd, over_alloc) catch return null;

        mapping = std.posix.mremap(
            footer.origin,
            mapped_len,
            over_alloc,
            .{ .MAYMOVE = true },
            null,
        ) catch return null;
    } else {
        // We must attempt to remap before we shrink the file, otherwise we
        // will risk some bytes being mapped, but truncated from the file,
        // resulting in a bus error each time we read this memory.

        mapping = std.posix.mremap(
            footer.origin,
            mapped_len,
            over_alloc,
            .{ .MAYMOVE = true },
            null,
        ) catch return null;

        // This is allowed to silently fail - further resizes will reattempt
        // to correctly size the file anyways, and it doesn't effect our
        // footer or memory mapping if it is a little large.
        std.posix.ftruncate(footer.fd, over_alloc) catch {};
    }

    // We have successfully remapped our allocation, so now we need to give it
    // a footer. This isn't the same footer because the origin has shifted.
    Footer.acquire(mapping.ptr, new_len).* = .{
        .origin = mapping.ptr,
        .fd = footer.fd,
    };

    // Align the memory correctly
    const data_addr = a.forward(@intFromPtr(mapping.ptr));
    assert(a.check(data_addr));

    return @ptrFromInt(data_addr);
}

fn free(_: *anyopaque, data: []u8, data_align: Alignment, _: usize) void {
    const footer: Footer = Footer.acquire(data.ptr, data.len).*;
    const origin_slice = footer.mappedSlice(data.len, data_align);
    std.posix.munmap(origin_slice);
    std.posix.close(footer.fd);
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

test "falloc" {
    const gpa: Allocator = allocator;
    try std.heap.testAllocator(gpa);
    try std.heap.testAllocatorAligned(gpa);
    try std.heap.testAllocatorAlignedShrink(gpa);
    try std.heap.testAllocatorLargeAlignment(gpa);
}
