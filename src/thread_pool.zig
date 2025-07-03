const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub fn ThreadPool(comptime WorkItem: type, comptime Result: type) type {
    return struct {
        const Self = @This();
        
        pub const WorkerFn = *const fn (allocator: Allocator, work_item: WorkItem) anyerror!Result;
        
        allocator: Allocator,
        worker_fn: WorkerFn,
        num_workers: usize,
        work_queue: ArrayList(WorkItem),
        result_queue: ArrayList(?Result),
        threads: []Thread,
        mutex: Thread.Mutex,
        condition: Thread.Condition,
        shutdown: bool,
        work_index: usize,
        
        pub fn init(allocator: Allocator, worker_fn: WorkerFn, num_workers: usize) !Self {
            const threads = try allocator.alloc(Thread, num_workers);
            
            return Self{
                .allocator = allocator,
                .worker_fn = worker_fn,
                .num_workers = num_workers,
                .work_queue = ArrayList(WorkItem).init(allocator),
                .result_queue = ArrayList(?Result).init(allocator),
                .threads = threads,
                .mutex = Thread.Mutex{},
                .condition = Thread.Condition{},
                .shutdown = false,
                .work_index = 0,
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.work_queue.deinit();
            self.result_queue.deinit();
            self.allocator.free(self.threads);
        }
        
        pub fn execute(self: *Self, work_items: []const WorkItem) !ArrayList(Result) {
            // Initialize work and result queues
            try self.work_queue.appendSlice(work_items);
            try self.result_queue.resize(work_items.len);
            
            // Initialize all results to null
            for (self.result_queue.items) |*result| {
                result.* = null;
            }
            
            self.work_index = 0;
            self.shutdown = false;
            
            // Start worker threads
            for (self.threads, 0..) |*thread, i| {
                thread.* = try Thread.spawn(.{}, workerLoop, .{ self, i });
            }
            
            // Wait for all threads to complete
            for (self.threads) |thread| {
                thread.join();
            }
            
            // Collect successful results
            var results = ArrayList(Result).init(self.allocator);
            for (self.result_queue.items) |maybe_result| {
                if (maybe_result) |result| {
                    try results.append(result);
                }
            }
            
            // Clear queues for next use
            self.work_queue.clearRetainingCapacity();
            self.result_queue.clearRetainingCapacity();
            
            return results;
        }
        
        fn workerLoop(self: *Self, worker_id: usize) void {
            while (true) {
                self.mutex.lock();
                defer self.mutex.unlock();
                
                // Check if we should shutdown
                if (self.shutdown or self.work_index >= self.work_queue.items.len) {
                    break;
                }
                
                // Get next work item
                const work_item_index = self.work_index;
                self.work_index += 1;
                const work_item = self.work_queue.items[work_item_index];
                
                // Release lock while processing
                self.mutex.unlock();
                
                std.io.getStdErr().writer().print("Worker {}: Processing item {}\n", .{ worker_id, work_item_index + 1 }) catch {};
                
                // Process work item
                const result = self.worker_fn(self.allocator, work_item) catch |err| {
                    std.io.getStdErr().writer().print("Worker {}: Error processing item {}: {}\n", .{ worker_id, work_item_index + 1, err }) catch {};
                    self.mutex.lock();
                    continue;
                };
                
                // Store result
                self.mutex.lock();
                self.result_queue.items[work_item_index] = result;
            }
            
            // Signal shutdown to other workers
            self.shutdown = true;
            self.condition.broadcast();
        }
    };
}