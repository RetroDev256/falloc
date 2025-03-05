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

    // Allocate enough space for the footer & proper alignment
    const new_map_len = new_len + @sizeOf(Footer);
    const new_over_alloc = new_map_len + footer_a.toByteUnits() + a.toByteUnits();

    const old_footer_ptr: *Footer = @ptrFromInt(footer_addr);
    const old_footer: Footer = old_footer_ptr.*;
    const origin = old_footer.origin;
    const fd = old_footer.fd;

    if (new_len > memory.len) {
        // Attempt to increase the length of the backing file before we attempt to
        // increase the mapped memory region. This is necessary in the case that the
        // file truncation succeeds, but the mremap fails.
        std.posix.ftruncate(fd, new_over_alloc) catch {
            return false; // Unable to truncate the file
        };

        // We know that the file truncation succeeded, and this old footer is still
        // in the right place as far as our code will still determine - update the
        // file length to be in a stable state.
        old_footer_ptr.file_len = new_over_alloc;

        const mapping = std.posix.mremap(
            origin,
            old_footer.map_len,
            new_over_alloc,
            .{},
            null,
        ) catch {
            // Unable to remap the file -
            // We are in a stable state - the pointer remains the same, and because the
            // backing file only increased in memory, we can read and write to the footer
            // with the same address. After all, we find the address of the footer based
            // on the length of the memory slice.
            return false;
        };

        // The mapping position must not change
        assert(mapping.ptr == origin);

        const new_footer_addr = footer_a.forward(aligned_addr + new_len);
        assert(footer_a.check(new_footer_addr));
        const new_footer_ptr: *Footer = @ptrFromInt(new_footer_addr);

        // Everything succeeded, update the metadata
        new_footer_ptr.* = .{
            .fd = fd,
            .origin = origin,
            .file_len = new_over_alloc,
            .map_len = new_over_alloc,
        };
    } else {
        // Attempt to remap the memmory mapped region before we attempt to truncate the file
        // This is because we will still be in a stable state where we can access the entire
        // addressed range, and it will have a backing file for that entire range. In the
        // case that the mremap succeeds but the ftruncate fails, we can still say that the
        // resize was a success, but the metadata will help us track what we *actually* have
        // in spare memory capacity for the file.
        const mapping = std.posix.mremap(
            origin,
            old_footer.map_len,
            new_over_alloc,
            .{},
            null,
        ) catch {
            return false; // Unable to remap the file
        };

        const new_footer_addr = footer_a.forward(aligned_addr + new_len);
        assert(footer_a.check(new_footer_addr));
        const new_footer_ptr: *Footer = @ptrFromInt(new_footer_addr);

        // To ensure a stable state for the allocation, record the state of the allocation.
        new_footer_ptr.* = .{
            .fd = fd,
            .origin = origin,
            .file_len = old_footer.file_len,
            .map_len = new_over_alloc,
        };

        // The mapping position must not change
        assert(mapping.ptr == origin);

        std.posix.ftruncate(fd, new_over_alloc) catch {
            // Unable to truncate the file. Kinda unfortunate, this. Thankfully we are
            // currently in a stable state as to simply return failure.
            return false;
        };

        // Everything succeeded, update the metadata
        new_footer_ptr.file_len = new_over_alloc;
    }

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
