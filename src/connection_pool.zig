const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Thread = std.Thread;

pub const ConnectionPool = struct {
    const Self = @This();
    
    pub const PooledConnection = struct {
        client: std.http.Client,
        last_used: i64,
        in_use: bool,
        host: []u8,
        
        pub fn deinit(self: *PooledConnection, allocator: Allocator) void {
            self.client.deinit();
            allocator.free(self.host);
        }
    };
    
    allocator: Allocator,
    connections: ArrayList(PooledConnection),
    mutex: Thread.Mutex,
    max_connections: usize,
    connection_timeout_seconds: i64,
    
    pub fn init(allocator: Allocator, max_connections: usize) Self {
        return Self{
            .allocator = allocator,
            .connections = ArrayList(PooledConnection).init(allocator),
            .mutex = Thread.Mutex{},
            .max_connections = max_connections,
            .connection_timeout_seconds = 300, // 5 minutes
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.connections.items) |*conn| {
            conn.deinit(self.allocator);
        }
        self.connections.deinit();
    }
    
    pub fn getConnection(self: *Self, host: []const u8) !*PooledConnection {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const now = std.time.timestamp();
        
        // Clean up expired connections
        try self.cleanupExpiredConnections(now);
        
        // Look for existing connection to the same host
        for (self.connections.items) |*conn| {
            if (!conn.in_use and std.mem.eql(u8, conn.host, host)) {
                conn.in_use = true;
                conn.last_used = now;
                return conn;
            }
        }
        
        // Create new connection if under limit
        if (self.connections.items.len < self.max_connections) {
            const new_conn = PooledConnection{
                .client = std.http.Client{ .allocator = self.allocator },
                .last_used = now,
                .in_use = true,
                .host = try self.allocator.dupe(u8, host),
            };
            
            try self.connections.append(new_conn);
            return &self.connections.items[self.connections.items.len - 1];
        }
        
        // Pool is full, find least recently used connection
        var oldest_index: usize = 0;
        var oldest_time = self.connections.items[0].last_used;
        
        for (self.connections.items, 0..) |conn, i| {
            if (!conn.in_use and conn.last_used < oldest_time) {
                oldest_time = conn.last_used;
                oldest_index = i;
            }
        }
        
        // Reuse the oldest connection
        var conn = &self.connections.items[oldest_index];
        if (conn.in_use) {
            return error.PoolExhausted;
        }
        
        // Update connection for new host
        self.allocator.free(conn.host);
        conn.host = try self.allocator.dupe(u8, host);
        conn.client.deinit();
        conn.client = std.http.Client{ .allocator = self.allocator };
        conn.in_use = true;
        conn.last_used = now;
        
        return conn;
    }
    
    pub fn releaseConnection(self: *Self, conn: *PooledConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        conn.in_use = false;
        conn.last_used = std.time.timestamp();
    }
    
    fn cleanupExpiredConnections(self: *Self, now: i64) !void {
        var i: usize = 0;
        while (i < self.connections.items.len) {
            const conn = &self.connections.items[i];
            const age = now - conn.last_used;
            
            if (!conn.in_use and age > self.connection_timeout_seconds) {
                conn.deinit(self.allocator);
                _ = self.connections.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
    
    pub fn getStats(self: *Self) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var active: usize = 0;
        var idle: usize = 0;
        
        for (self.connections.items) |conn| {
            if (conn.in_use) {
                active += 1;
            } else {
                idle += 1;
            }
        }
        
        return PoolStats{
            .total_connections = self.connections.items.len,
            .active_connections = active,
            .idle_connections = idle,
            .max_connections = self.max_connections,
        };
    }
};

pub const PoolStats = struct {
    total_connections: usize,
    active_connections: usize,
    idle_connections: usize,
    max_connections: usize,
};

// Global connection pool instance
var global_pool: ?ConnectionPool = null;
var pool_mutex = Thread.Mutex{};

pub fn initGlobalPool(allocator: Allocator, max_connections: usize) void {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    
    if (global_pool == null) {
        global_pool = ConnectionPool.init(allocator, max_connections);
    }
}

pub fn deinitGlobalPool() void {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    
    if (global_pool) |*pool| {
        pool.deinit();
        global_pool = null;
    }
}

pub fn getGlobalPool() ?*ConnectionPool {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    
    if (global_pool) |*pool| {
        return pool;
    }
    return null;
}