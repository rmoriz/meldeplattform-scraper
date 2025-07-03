const std = @import("std");
const Allocator = std.mem.Allocator;

/// Memory pool for efficient allocation of temporary objects
pub const MemoryPool = struct {
    const Self = @This();
    
    arena: std.heap.ArenaAllocator,
    backing_allocator: Allocator,
    
    pub fn init(backing_allocator: Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .backing_allocator = backing_allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }
    
    pub fn reset(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
    }
    
    pub fn allocator(self: *Self) Allocator {
        return self.arena.allocator();
    }
    
    pub fn getStats(self: *Self) MemoryStats {
        const state = self.arena.state;
        return MemoryStats{
            .bytes_allocated = state.end_index,
            .buffer_capacity = state.buffer_list.items.len,
        };
    }
};

pub const MemoryStats = struct {
    bytes_allocated: usize,
    buffer_capacity: usize,
};

/// Scoped memory management for automatic cleanup
pub fn ScopedMemory(comptime T: type) type {
    return struct {
        const Self = @This();
        
        value: T,
        pool: *MemoryPool,
        
        pub fn init(pool: *MemoryPool, value: T) Self {
            return Self{
                .value = value,
                .pool = pool,
            };
        }
        
        pub fn deinit(self: Self) void {
            self.pool.reset();
        }
    };
}