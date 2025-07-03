const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

pub const ConnectionMetrics = struct {
    const Self = @This();
    
    total_requests: u64,
    pooled_requests: u64,
    direct_requests: u64,
    connection_reuses: u64,
    connection_timeouts: u64,
    pool_exhaustions: u64,
    total_response_time_ms: u64,
    mutex: Thread.Mutex,
    
    pub fn init() Self {
        return Self{
            .total_requests = 0,
            .pooled_requests = 0,
            .direct_requests = 0,
            .connection_reuses = 0,
            .connection_timeouts = 0,
            .pool_exhaustions = 0,
            .total_response_time_ms = 0,
            .mutex = Thread.Mutex{},
        };
    }
    
    pub fn recordPooledRequest(self: *Self, response_time_ms: u64, was_reused: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.total_requests += 1;
        self.pooled_requests += 1;
        self.total_response_time_ms += response_time_ms;
        
        if (was_reused) {
            self.connection_reuses += 1;
        }
    }
    
    pub fn recordDirectRequest(self: *Self, response_time_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.total_requests += 1;
        self.direct_requests += 1;
        self.total_response_time_ms += response_time_ms;
    }
    
    pub fn recordPoolExhaustion(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.pool_exhaustions += 1;
    }
    
    pub fn recordConnectionTimeout(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.connection_timeouts += 1;
    }
    
    pub fn getStats(self: *Self) MetricsSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return MetricsSnapshot{
            .total_requests = self.total_requests,
            .pooled_requests = self.pooled_requests,
            .direct_requests = self.direct_requests,
            .connection_reuses = self.connection_reuses,
            .connection_timeouts = self.connection_timeouts,
            .pool_exhaustions = self.pool_exhaustions,
            .average_response_time_ms = if (self.total_requests > 0) 
                self.total_response_time_ms / self.total_requests else 0,
            .pool_efficiency = if (self.total_requests > 0) 
                (@as(f64, @floatFromInt(self.pooled_requests)) / @as(f64, @floatFromInt(self.total_requests))) * 100.0 else 0.0,
            .reuse_rate = if (self.pooled_requests > 0) 
                (@as(f64, @floatFromInt(self.connection_reuses)) / @as(f64, @floatFromInt(self.pooled_requests))) * 100.0 else 0.0,
        };
    }
    
    pub fn printStats(self: *Self) void {
        const stats = self.getStats();
        
        std.debug.print("Connection Metrics:\n", .{});
        std.debug.print("  Total Requests: {}\n", .{stats.total_requests});
        std.debug.print("  Pooled: {} ({d:.1}%)\n", .{ stats.pooled_requests, stats.pool_efficiency });
        std.debug.print("  Direct: {}\n", .{stats.direct_requests});
        std.debug.print("  Connection Reuses: {} ({d:.1}%)\n", .{ stats.connection_reuses, stats.reuse_rate });
        std.debug.print("  Pool Exhaustions: {}\n", .{stats.pool_exhaustions});
        std.debug.print("  Connection Timeouts: {}\n", .{stats.connection_timeouts});
        std.debug.print("  Avg Response Time: {}ms\n", .{stats.average_response_time_ms});
    }
};

pub const MetricsSnapshot = struct {
    total_requests: u64,
    pooled_requests: u64,
    direct_requests: u64,
    connection_reuses: u64,
    connection_timeouts: u64,
    pool_exhaustions: u64,
    average_response_time_ms: u64,
    pool_efficiency: f64,
    reuse_rate: f64,
};

// Global metrics instance
var global_metrics: ?ConnectionMetrics = null;
var metrics_mutex = Thread.Mutex{};

pub fn initGlobalMetrics() void {
    metrics_mutex.lock();
    defer metrics_mutex.unlock();
    
    if (global_metrics == null) {
        global_metrics = ConnectionMetrics.init();
    }
}

pub fn getGlobalMetrics() ?*ConnectionMetrics {
    metrics_mutex.lock();
    defer metrics_mutex.unlock();
    
    if (global_metrics) |*metrics| {
        return metrics;
    }
    return null;
}