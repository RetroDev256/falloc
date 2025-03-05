Ever wanted a zig allocator that could allocate all the free space of your HDD? Look no further! Really though, don't. Unless you have a specific need for this, you likely don't need it ;)

I created this allocator (POSIX systems only right now) for the purpose of single, *very* large allocations. Think lots and lots of math with hundreds of gigabytes in each array.
