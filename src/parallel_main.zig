const std = @import("std");
const print = std.debug.print;
const stderr = std.io.getStdErr().writer();
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
    
    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    var output_file: ?[]const u8 = null;
    
    // Parse CLI arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--output") or std.mem.eql(u8, args[i], "-o")) {
            if (i + 1 >= args.len) {
                stderr.print("Error: --output requires a filename\n", .{}) catch {};
                stderr.print("Usage: {s} [--output <filename>]\n", .{args[0]}) catch {};
                return;
            }
            output_file = args[i + 1];
            i += 1; // Skip the filename argument
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            stderr.print("RSS Cache Parser - Parallel Processing Version\n", .{}) catch {};
            stderr.print("Usage: {s} [OPTIONS]\n", .{args[0]}) catch {};
            stderr.print("\nOptions:\n", .{}) catch {};
            stderr.print("  --output, -o <filename>  Save JSON output to file instead of stdout\n", .{}) catch {};
            stderr.print("  --help, -h               Show this help message\n", .{}) catch {};
            return;
        } else {
            stderr.print("Error: Unknown argument '{s}'\n", .{args[i]}) catch {};
            stderr.print("Usage: {s} [--output <filename>]\n", .{args[0]}) catch {};
            return;
        }
    }

    stderr.print("RSS Cache Parser - Parallel Processing Version\n", .{}) catch {};
    stderr.print("Max concurrent workers: {}\n", .{MAX_CONCURRENT_WORKERS}) catch {};
    
    // Initialize connection pool and metrics
    connection_pool.initGlobalPool(allocator, 12); // More connections for parallel processing
    defer connection_pool.deinitGlobalPool();
    connection_metrics.initGlobalMetrics();

    // Initialize cache directory and purge old files
    try cache.initCacheDir();
    try cache.purgeOldCacheFiles();

    // Fetch RSS feed using connection pool
    stderr.print("Fetching RSS feed from: {s}\n", .{RSS_URL}) catch {};
    const rss_content = pooled_http_client.fetchUrlPooled(allocator, RSS_URL) catch |err| {
        stderr.print("Error fetching RSS: {}\n", .{err}) catch {};
        return;
    };
    defer allocator.free(rss_content);

    // Parse RSS to get item list
    stderr.print("Parsing RSS feed...\n", .{}) catch {};
    const rss_items = rss_parser.parseRss(allocator, rss_content) catch |err| {
        stderr.print("Error parsing RSS: {}\n", .{err}) catch {};
        return;
    };
    defer {
        for (rss_items.items) |item| {
            item.deinit(allocator);
        }
        rss_items.deinit();
    }

    stderr.print("Found {} RSS items\n", .{rss_items.items.len}) catch {};

    // Process items using thread pool
    const start_time = std.time.milliTimestamp();
    
    const num_workers = @min(MAX_CONCURRENT_WORKERS, rss_items.items.len);
    var thread_pool = try ItemProcessor.init(allocator, processItemWorker, num_workers);
    defer thread_pool.deinit();
    
    stderr.print("Processing items with {} workers...\n", .{num_workers}) catch {};
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
    stderr.print("\nGenerating JSON output...\n", .{}) catch {};
    const json_str = memory_optimized_json.itemsToJsonOptimized(allocator, processed_items.items) catch |err| {
        stderr.print("Error generating JSON: {}\n", .{err}) catch {};
        return;
    };
    defer allocator.free(json_str);

    // Write JSON to file or stdout
    if (output_file) |filename| {
        const file = std.fs.cwd().createFile(filename, .{}) catch |err| {
            stderr.print("Error creating output file '{s}': {}\n", .{ filename, err }) catch {};
            return;
        };
        defer file.close();
        
        file.writeAll(json_str) catch |err| {
            stderr.print("Error writing to output file '{s}': {}\n", .{ filename, err }) catch {};
            return;
        };
        
        stderr.print("JSON output saved to: {s}\n", .{filename}) catch {};
    } else {
        // Only JSON goes to stdout
        const stdout = std.io.getStdOut().writer();
        stdout.print("{s}\n", .{json_str}) catch {};
    }

    // Print connection pool statistics to stderr
    stderr.print("\n", .{}) catch {};
    pooled_http_client.printPoolStats();
    
    stderr.print("\nProcessed {} items successfully in {}ms\n", .{ processed_items.items.len, processing_time }) catch {};
    stderr.print("Average time per item: {d:.2}ms\n", .{ @as(f64, @floatFromInt(processing_time)) / @as(f64, @floatFromInt(processed_items.items.len)) }) catch {};
}