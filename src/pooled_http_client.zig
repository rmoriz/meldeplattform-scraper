const std = @import("std");
const Allocator = std.mem.Allocator;
const connection_pool = @import("connection_pool.zig");
const connection_metrics = @import("connection_metrics.zig");

pub fn fetchUrlPooled(allocator: Allocator, url: []const u8) ![]u8 {
    const start_time = std.time.milliTimestamp();
    
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    
    // Extract host from URL
    const host_component = uri.host orelse return error.InvalidHost;
    const host = switch (host_component) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
    
    // Get connection from pool
    const pool = connection_pool.getGlobalPool() orelse return error.PoolNotInitialized;
    var conn = pool.getConnection(host) catch |err| {
        if (connection_metrics.getGlobalMetrics()) |metrics| {
            if (err == error.PoolExhausted) {
                metrics.recordPoolExhaustion();
            }
        }
        std.io.getStdErr().writer().print("Failed to get pooled connection: {}\n", .{err}) catch {};
        // Fallback to non-pooled request
        const result = try fetchUrlDirect(allocator, url);
        const response_time = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        if (connection_metrics.getGlobalMetrics()) |metrics| {
            metrics.recordDirectRequest(response_time);
        }
        return result;
    };
    defer pool.releaseConnection(conn);
    
    const was_reused = conn.last_used < start_time - 1000; // Connection older than 1 second
    const result = try fetchWithConnection(allocator, &conn.client, uri);
    
    const response_time = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
    if (connection_metrics.getGlobalMetrics()) |metrics| {
        metrics.recordPooledRequest(response_time, was_reused);
    }
    
    return result;
}

pub fn fetchUrlDirect(allocator: Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    return fetchWithConnection(allocator, &client, uri);
}

fn fetchWithConnection(allocator: Allocator, client: *std.http.Client, uri: std.Uri) ![]u8 {
    const server_header_buffer = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(server_header_buffer);
    
    var request = try client.open(.GET, uri, .{
        .server_header_buffer = server_header_buffer,
        .headers = .{
            .user_agent = .{ .override = "RSS-Cache-Parser/1.0" },
        },
    });
    defer request.deinit();

    try request.send();
    try request.finish();
    try request.wait();

    if (request.response.status != .ok) {
        std.io.getStdErr().writer().print("HTTP Error: {}\n", .{request.response.status}) catch {};
        return error.HttpError;
    }

    const body = try request.reader().readAllAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    return body;
}

pub fn fetchUrlWithRetryPooled(allocator: Allocator, url: []const u8, max_retries: u32) ![]u8 {
    var retries: u32 = 0;
    while (retries < max_retries) {
        if (fetchUrlPooled(allocator, url)) |result| {
            return result;
        } else |err| {
            retries += 1;
            if (retries >= max_retries) {
                return err;
            }
            std.io.getStdErr().writer().print("Retry {}/{} for URL: {s}\n", .{ retries, max_retries, url }) catch {};
            std.time.sleep(std.time.ns_per_s * retries); // Exponential backoff
        }
    }
    return error.MaxRetriesExceeded;
}

// Connection pool statistics and monitoring
pub fn printPoolStats() void {
    if (connection_pool.getGlobalPool()) |pool| {
        const stats = pool.getStats();
        std.io.getStdErr().writer().print("Connection Pool Stats:\n", .{}) catch {};
        std.io.getStdErr().writer().print("  Total: {}/{}\n", .{ stats.total_connections, stats.max_connections }) catch {};
        std.io.getStdErr().writer().print("  Active: {}\n", .{stats.active_connections}) catch {};
        std.io.getStdErr().writer().print("  Idle: {}\n", .{stats.idle_connections}) catch {};
    }
    
    if (connection_metrics.getGlobalMetrics()) |metrics| {
        metrics.printStats();
    }
}