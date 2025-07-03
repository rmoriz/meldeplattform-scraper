const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn fetchUrl(allocator: Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    
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
        std.debug.print("HTTP Error: {}\n", .{request.response.status});
        return error.HttpError;
    }

    const body = try request.reader().readAllAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    return body;
}

pub fn fetchUrlWithRetry(allocator: Allocator, url: []const u8, max_retries: u32) ![]u8 {
    var retries: u32 = 0;
    while (retries < max_retries) {
        if (fetchUrl(allocator, url)) |result| {
            return result;
        } else |err| {
            retries += 1;
            if (retries >= max_retries) {
                return err;
            }
            std.debug.print("Retry {}/{} for URL: {s}\n", .{ retries, max_retries, url });
            std.time.sleep(std.time.ns_per_s * retries); // Exponential backoff
        }
    }
    return error.MaxRetriesExceeded;
}