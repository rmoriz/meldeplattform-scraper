const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const rss_parser = @import("rss_parser.zig");
const http_client = @import("http_client.zig");
const cache = @import("cache.zig");
const item_fetcher = @import("item_fetcher.zig");
const json_output = @import("json_output.zig");
const memory_optimized_json = @import("memory_optimized_json.zig");
const memory_pool = @import("memory_pool.zig");
const connection_pool = @import("connection_pool.zig");
const pooled_http_client = @import("pooled_http_client.zig");
const connection_metrics = @import("connection_metrics.zig");

const RSS_URL = "https://meldeplattform-rad.muenchenunterwegs.de/bms/rss";
const MAX_CONCURRENT_WORKERS = 4;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            print("Memory leaks detected!\n", .{});
        } else {
            print("No memory leaks detected.\n", .{});
        }
    }
    const allocator = gpa.allocator();
    
    // Initialize memory pool for temporary allocations
    var pool = memory_pool.MemoryPool.init(allocator);
    defer pool.deinit();

    // Initialize connection pool and metrics
    connection_pool.initGlobalPool(allocator, 8); // Max 8 connections
    defer connection_pool.deinitGlobalPool();
    connection_metrics.initGlobalMetrics();

    print("RSS Cache Parser - Starting...\n", .{});

    // Initialize cache directory
    try cache.initCacheDir();

    // Fetch RSS feed using direct HTTP client (avoiding SSL issues)
    print("Fetching RSS feed from: {s}\n", .{RSS_URL});
    const rss_content = http_client.fetchUrl(allocator, RSS_URL) catch |err| {
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

    // Process items in parallel (limit to first 3 for testing)
    const items_to_process = rss_items.items[0..@min(3, rss_items.items.len)];
    print("Processing {} items with {} concurrent workers...\n", .{ items_to_process.len, MAX_CONCURRENT_WORKERS });
    
    var processed_items = try processItemsParallel(allocator, items_to_process);
    defer {
        for (processed_items.items) |item| {
            item.deinit(allocator);
        }
        processed_items.deinit();
    }

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
    
    print("\nProcessed {} items successfully\n", .{processed_items.items.len});
}

const WorkerContext = struct {
    allocator: Allocator,
    input_items: []const rss_parser.RssItem,
    output_items: []?json_output.ProcessedItem,
    start_index: usize,
    end_index: usize,
    worker_id: usize,
    mutex: *Thread.Mutex,
};

fn workerThread(context: *WorkerContext) void {
    for (context.start_index..context.end_index) |i| {
        const rss_item = context.input_items[i];
        
        context.mutex.lock();
        print("Worker {}: Processing item {} - {s}\n", .{ context.worker_id, i + 1, rss_item.title });
        context.mutex.unlock();
        
        const processed_item = item_fetcher.processItem(context.allocator, rss_item) catch |err| {
            context.mutex.lock();
            print("Worker {}: Error processing item {s}: {}\n", .{ context.worker_id, rss_item.title, err });
            context.mutex.unlock();
            continue;
        };
        
        context.output_items[i] = processed_item;
    }
}

fn processItemsParallel(allocator: Allocator, rss_items: []const rss_parser.RssItem) !ArrayList(json_output.ProcessedItem) {
    const num_items = rss_items.len;
    const num_workers = @min(MAX_CONCURRENT_WORKERS, num_items);
    
    if (num_workers <= 1) {
        // Fall back to sequential processing for small workloads
        return processItemsSequential(allocator, rss_items);
    }
    
    // Allocate output array
    const output_items = try allocator.alloc(?json_output.ProcessedItem, num_items);
    defer allocator.free(output_items);
    
    // Initialize all slots to null
    for (output_items) |*item| {
        item.* = null;
    }
    
    // Create worker threads
    var threads = try allocator.alloc(Thread, num_workers);
    defer allocator.free(threads);
    
    var contexts = try allocator.alloc(WorkerContext, num_workers);
    defer allocator.free(contexts);
    
    var mutex = Thread.Mutex{};
    
    const items_per_worker = num_items / num_workers;
    const remainder = num_items % num_workers;
    
    // Start worker threads
    for (0..num_workers) |worker_id| {
        const start_index = worker_id * items_per_worker + @min(worker_id, remainder);
        const end_index = start_index + items_per_worker + (if (worker_id < remainder) @as(usize, 1) else @as(usize, 0));
        
        contexts[worker_id] = WorkerContext{
            .allocator = allocator,
            .input_items = rss_items,
            .output_items = output_items,
            .start_index = start_index,
            .end_index = end_index,
            .worker_id = worker_id,
            .mutex = &mutex,
        };
        
        threads[worker_id] = try Thread.spawn(.{}, workerThread, .{&contexts[worker_id]});
    }
    
    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }
    
    // Collect results
    var processed_items = ArrayList(json_output.ProcessedItem).init(allocator);
    for (output_items) |maybe_item| {
        if (maybe_item) |item| {
            try processed_items.append(item);
        }
    }
    
    return processed_items;
}

fn processItemsSequential(allocator: Allocator, rss_items: []const rss_parser.RssItem) !ArrayList(json_output.ProcessedItem) {
    var processed_items = ArrayList(json_output.ProcessedItem).init(allocator);
    
    for (rss_items, 0..) |rss_item, i| {
        print("Processing item {} - {s}\n", .{ i + 1, rss_item.title });
        
        const processed_item = item_fetcher.processItem(allocator, rss_item) catch |err| {
            print("Error processing item {s}: {}\n", .{ rss_item.title, err });
            continue;
        };
        
        try processed_items.append(processed_item);
    }
    
    return processed_items;
}