const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const ProcessedItem = struct {
    title: []u8,
    url: []u8,
    pub_date: []u8,
    creation_date: []u8,
    address: []u8,
    html_content: []u8,
    description: []u8,
    cached: bool,

    pub fn deinit(self: ProcessedItem, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.pub_date);
        allocator.free(self.creation_date);
        allocator.free(self.address);
        allocator.free(self.html_content);
        allocator.free(self.description);
    }
};

pub fn itemsToJson(allocator: Allocator, items: []const ProcessedItem) ![]u8 {
    // Use arena allocator for temporary JSON structures
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    
    var json_array = std.json.Array.init(arena_allocator);
    
    for (items) |item| {
        var json_obj = std.json.ObjectMap.init(arena_allocator);
        
        try json_obj.put("title", std.json.Value{ .string = item.title });
        try json_obj.put("url", std.json.Value{ .string = item.url });
        try json_obj.put("pub_date", std.json.Value{ .string = item.pub_date });
        try json_obj.put("description", std.json.Value{ .string = item.description });
        try json_obj.put("cached", std.json.Value{ .bool = item.cached });
        try json_obj.put("html_length", std.json.Value{ .integer = @intCast(item.html_content.len) });
        
        try json_array.append(std.json.Value{ .object = json_obj });
    }
    
    const json_value = std.json.Value{ .array = json_array };
    
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try std.json.stringify(json_value, .{ .whitespace = .indent_2 }, buffer.writer());
    return buffer.toOwnedSlice();
}