const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const rss_parser = @import("rss_parser.zig");
const http_client = @import("http_client.zig");
const cache = @import("cache.zig");
const item_fetcher = @import("item_fetcher.zig");
const json_output = @import("json_output.zig");
const memory_optimized_json = @import("memory_optimized_json.zig");
const connection_pool = @import("connection_pool.zig");
const pooled_http_client = @import("pooled_http_client.zig");
const connection_metrics = @import("connection_metrics.zig");
const ThreadPool = @import("thread_pool.zig").ThreadPool;

const RSS_URL = "https://meldeplattform-rad.muenchenunterwegs.de/bms/rss";
const MAX_CONCURRENT_WORKERS = 4;

const ItemProcessor = ThreadPool(rss_parser.RssItem, json_output.ProcessedItem);

fn processItemWorker(allocator: Allocator, rss_item: rss_parser.RssItem) !json_output.ProcessedItem {
    return item_fetcher.processItem(allocator, rss_item);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("RSS Cache Parser - Parallel Processing Version\n", .{});
    print("Max concurrent workers: {}\n", .{MAX_CONCURRENT_WORKERS});
    
    // Initialize connection pool and metrics
    connection_pool.initGlobalPool(allocator, 12); // More connections for parallel processing
    defer connection_pool.deinitGlobalPool();
    connection_metrics.initGlobalMetrics();

    // Initialize cache directory
    try cache.initCacheDir();

    // Fetch RSS feed using connection pool
    print("Fetching RSS feed from: {s}\n", .{RSS_URL});
    const rss_content = pooled_http_client.fetchUrlPooled(allocator, RSS_URL) catch |err| {
        print("Error fetching RSS: {}\n", .{err});
        return;
    };
    defer allocator.free(rss_content);

    // Parse RSS to get item list
    print("Parsing RSS feed...\n", .{});
    const rss_items = rss_parser.parseRss(allocator, rss_content) catch |err| {
        print("Error parsing RSS: {}\n", .{err});
        return;
    };
    defer {
        for (rss_items.items) |item| {
            item.deinit(allocator);
        }
        rss_items.deinit();
    }

    print("Found {} RSS items\n", .{rss_items.items.len});

    // Process items using thread pool
    const start_time = std.time.milliTimestamp();
    
    const num_workers = @min(MAX_CONCURRENT_WORKERS, rss_items.items.len);
    var thread_pool = try ItemProcessor.init(allocator, processItemWorker, num_workers);
    defer thread_pool.deinit();
    
    print("Processing items with {} workers...\n", .{num_workers});
    var processed_items = try thread_pool.execute(rss_items.items);
    defer {
        for (processed_items.items) |item| {
            item.deinit(allocator);
        }
        processed_items.deinit();
    }
    
    const end_time = std.time.milliTimestamp();
    const processing_time = end_time - start_time;

    // Output as JSON (memory optimized)
    print("\nGenerating JSON output...\n", .{});
    const json_str = memory_optimized_json.itemsToJsonOptimized(allocator, processed_items.items) catch |err| {
        print("Error generating JSON: {}\n", .{err});
        return;
    };
    defer allocator.free(json_str);

    print("\n=== JSON OUTPUT ===\n", .{});
    print("{s}\n", .{json_str});
    print("=== END OUTPUT ===\n", .{});

    // Print connection pool statistics
    print("\n", .{});
    pooled_http_client.printPoolStats();
    
    print("\nProcessed {} items successfully in {}ms\n", .{ processed_items.items.len, processing_time });
    print("Average time per item: {d:.2}ms\n", .{ @as(f64, @floatFromInt(processing_time)) / @as(f64, @floatFromInt(processed_items.items.len)) });
}