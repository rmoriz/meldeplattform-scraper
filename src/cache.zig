const std = @import("std");
const Allocator = std.mem.Allocator;

const CACHE_DIR = "cache";
const CACHE_EXPIRY_HOURS = 24;

pub const CachedItem = struct {
    timestamp: i64,
    url: []u8,
    html_content: []u8,
    title: []u8,
    pub_date: []u8,

    pub fn deinit(self: CachedItem, allocator: Allocator) void {
        allocator.free(self.url);
        allocator.free(self.html_content);
        allocator.free(self.title);
        allocator.free(self.pub_date);
    }
};

pub fn initCacheDir() !void {
    std.fs.cwd().makeDir(CACHE_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // Directory already exists, that's fine
        else => return err,
    };
}

pub fn getCacheFilename(allocator: Allocator, url: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(url);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    
    var hex_hash: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex_hash, "{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
    
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ CACHE_DIR, hex_hash });
}

pub fn isCacheValid(cache_filename: []const u8) bool {
    const file = std.fs.cwd().openFile(cache_filename, .{}) catch return false;
    defer file.close();
    
    const stat = file.stat() catch return false;
    const now = std.time.timestamp();
    const cache_age_hours = @divFloor(now - stat.mtime, 3600);
    
    return cache_age_hours < CACHE_EXPIRY_HOURS;
}

pub fn loadFromCache(allocator: Allocator, cache_filename: []const u8) !CachedItem {
    const file = std.fs.cwd().openFile(cache_filename, .{}) catch return error.CacheNotFound;
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(content);
    
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.InvalidCacheFormat;
    defer parsed.deinit();
    
    const root = parsed.value.object;
    
    return CachedItem{
        .timestamp = @intCast(root.get("timestamp").?.integer),
        .url = try allocator.dupe(u8, root.get("url").?.string),
        .html_content = try allocator.dupe(u8, root.get("html_content").?.string),
        .title = try allocator.dupe(u8, root.get("title").?.string),
        .pub_date = try allocator.dupe(u8, root.get("pub_date").?.string),
    };
}

pub fn saveToCache(allocator: Allocator, cache_filename: []const u8, item: CachedItem) !void {
    const file = std.fs.cwd().createFile(cache_filename, .{}) catch return error.CacheWriteError;
    defer file.close();
    
    // Use arena allocator for temporary JSON structures
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    
    var json_obj = std.json.ObjectMap.init(arena_allocator);
    
    try json_obj.put("timestamp", std.json.Value{ .integer = item.timestamp });
    try json_obj.put("url", std.json.Value{ .string = item.url });
    try json_obj.put("html_content", std.json.Value{ .string = item.html_content });
    try json_obj.put("title", std.json.Value{ .string = item.title });
    try json_obj.put("pub_date", std.json.Value{ .string = item.pub_date });
    
    const json_value = std.json.Value{ .object = json_obj };
    
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try std.json.stringify(json_value, .{}, buffer.writer());
    try file.writeAll(buffer.items);
}