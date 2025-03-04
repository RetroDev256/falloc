const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

// TODO: manage context in an "always allocated" mapping to a file
// This context will allow things to be resized and freed and stuff

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
    map_len: usize,
    file_len: usize, // TODO: see if we can merge the two lens
    fd: std.posix.fd_t,
};
const footer_a: Alignment = .fromByteUnits(@alignOf(Footer));

/// Return a pointer to `len` bytes with specified `alignment`, or return
/// `null` indicating the allocation failed.
///
/// `ret_addr` is optionally provided as the first return address of the
/// allocation call stack. If the value is `0` it means no return address
/// has been provided.
fn alloc(_: *anyopaque, len: usize, a: Alignment, _: usize) ?[*]u8 {
    const fd = tmpfile() catch return null;

    // Allocate enough space for the footer & proper alignment
    const map_len = len + @sizeOf(Footer);
    const over_alloc = map_len + footer_a.toByteUnits() + a.toByteUnits();
    std.posix.ftruncate(fd, @intCast(over_alloc)) catch {
        std.posix.close(fd);
        return null;
    };

    // Ensure that the mapping will link to the file on disk, and not RAM
    const mapping = std.posix.mmap(
        null,
        over_alloc,
        std.posix.PROT.WRITE | std.posix.PROT.READ | std.posix.PROT.SEM,
        .{ .UNINITIALIZED = true, .NORESERVE = true, .TYPE = .SHARED },
        fd,
        0,
    ) catch {
        std.posix.close(fd);
        return null;
    };

    // Align the footer and memory correctly
    const aligned_addr = a.forward(@intFromPtr(mapping.ptr));
    assert(a.check(aligned_addr));

    const footer_addr = footer_a.forward(aligned_addr + len);
    assert(footer_a.check(footer_addr));

    // Set the footer so that we can resize/remap/free later
    const footer: *Footer = @ptrFromInt(footer_addr);
    footer.* = .{
        .origin = mapping.ptr,
        .map_len = over_alloc,
        .file_len = over_alloc,
        .fd = fd,
    };

    return @ptrFromInt(aligned_addr);
}

/// Attempt to expand or shrink memory in place.
///
/// `memory.len` must equal the length requested from the most recent
/// successful call to `alloc`, `resize`, or `remap`. `alignment` must
/// equal the same value that was passed as the `alignment` parameter to
/// the original `alloc` call.
///
/// A result of `true` indicates the resize was successful and the
/// allocation now has the same address but a size of `new_len`. `false`
/// indicates the resize could not be completed without moving the
/// allocation to a different address.
///
/// `new_len` must be greater than zero.
fn resize(_: *anyopaque, memory: []u8, a: Alignment, new_len: usize, _: usize) bool {
    const aligned_addr: usize = @intFromPtr(memory.ptr);
    assert(a.check(aligned_addr));

    const footer_addr = footer_a.forward(aligned_addr + memory.len);
    assert(footer_a.check(footer_addr));

    const footer: *Footer = @ptrFromInt(footer_addr);

    // Allocate enough space for the footer & proper alignment
    const new_map_len = new_len + @sizeOf(Footer);
    const new_over_alloc = new_map_len + footer_a.toByteUnits() + a.toByteUnits();
    std.posix.ftruncate(footer.fd, @intCast(new_over_alloc)) catch {
        return false; // Unable to truncate the file
    };

    const mapping = std.posix.mremap(
        footer.origin,
        footer.map_len,
        new_over_alloc,
        .{},
        null,
    ) catch {
        // Set the file length for if the ftruncate succeeds but the mremap fails
        // This goes at the original address as we judge the position of the footer
        // based on the mapped length, not the file length
        footer.file_len = new_over_alloc;
        return false; // Unable to remap the file
    };

    // The mapping position must not change
    assert(mapping.ptr == footer.origin);

    const new_footer_addr = footer_a.forward(aligned_addr + new_len);
    assert(footer_a.check(new_footer_addr));

    const new_footer: *Footer = @ptrFromInt(new_footer_addr);
    new_footer.* = .{
        .origin = footer.origin,
        .map_len = new_over_alloc,
        .file_len = new_over_alloc,
        .fd = footer.fd,
    };

    return true;
}

/// Attempt to expand or shrink memory, allowing relocation.
///
/// `memory.len` must equal the length requested from the most recent
/// successful call to `alloc`, `resize`, or `remap`. `alignment` must
/// equal the same value that was passed as the `alignment` parameter to
/// the original `alloc` call.
///
/// A non-`null` return value indicates the resize was successful. The
/// allocation may have same address, or may have been relocated. In either
/// case, the allocation now has size of `new_len`. A `null` return value
/// indicates that the resize would be equivalent to allocating new memory,
/// copying the bytes from the old memory, and then freeing the old memory.
/// In such case, it is more efficient for the caller to perform the copy.
///
/// `new_len` must be greater than zero.
///
/// `ret_addr` is optionally provided as the first return address of the
/// allocation call stack. If the value is `0` it means no return address
/// has been provided.
fn remap(_: *anyopaque, memory: []u8, a: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = .{ memory, a, new_len, ret_addr };
    return null;
}

/// Free and invalidate a region of memory.
///
/// `memory.len` must equal the length requested from the most recent
/// successful call to `alloc`, `resize`, or `remap`. `alignment` must
/// equal the same value that was passed as the `alignment` parameter to
/// the original `alloc` call.
///
/// `ret_addr` is optionally provided as the first return address of the
/// allocation call stack. If the value is `0` it means no return address
/// has been provided.
fn free(_: *anyopaque, memory: []u8, a: Alignment, ret_addr: usize) void {
    _ = .{ memory, a, ret_addr };
    // well frick
}

fn tmpfile() !std.posix.fd_t {
    // TODO: some number of attempts with 32/64 bit random number instead?
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
