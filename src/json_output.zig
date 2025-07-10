const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub fn extractIdFromUrl(url: []const u8) u32 {
    // Extract ID from URLs like https://meldeplattform-rad.muenchenunterwegs.de/bms/2033957
    if (std.mem.lastIndexOf(u8, url, "/")) |last_slash_pos| {
        const id_str = url[last_slash_pos + 1..];
        return std.fmt.parseInt(u32, id_str, 10) catch 0;
    }
    return 0;
}

pub const ImageDimensions = struct {
    width: u32,
    height: u32,
};

pub const ImageData = struct {
    url: []u8,
    base64_data: []u8,
    filename: []u8,
    mime_type: []u8,
    file_size: u64,
    image_size: ImageDimensions,

    pub fn deinit(self: ImageData, allocator: Allocator) void {
        allocator.free(self.url);
        allocator.free(self.base64_data);
        allocator.free(self.filename);
        allocator.free(self.mime_type);
    }
};

pub const ProcessedItem = struct {
    id: u32,
    title: []u8,
    url: []u8,
    pub_date: []u8,
    creation_date: []u8,
    address: []u8,
    borough: []u8,
    html_content: []u8,
    description: []u8,
    images: []ImageData,
    cached: bool,

    pub fn deinit(self: ProcessedItem, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.pub_date);
        allocator.free(self.creation_date);
        allocator.free(self.address);
        allocator.free(self.borough);
        allocator.free(self.html_content);
        allocator.free(self.description);
        
        for (self.images) |image| {
            image.deinit(allocator);
        }
        allocator.free(self.images);
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
        
        try json_obj.put("id", std.json.Value{ .integer = @intCast(item.id) });
        try json_obj.put("title", std.json.Value{ .string = item.title });
        try json_obj.put("url", std.json.Value{ .string = item.url });
        try json_obj.put("pub_date", std.json.Value{ .string = item.pub_date });
        try json_obj.put("description", std.json.Value{ .string = item.description });
        
        // Add images array
        var images_array = std.json.Array.init(arena_allocator);
        for (item.images) |image| {
            var image_obj = std.json.ObjectMap.init(arena_allocator);
            try image_obj.put("url", std.json.Value{ .string = image.url });
            try image_obj.put("base64_data", std.json.Value{ .string = image.base64_data });
            try image_obj.put("filename", std.json.Value{ .string = image.filename });
            try image_obj.put("mime_type", std.json.Value{ .string = image.mime_type });
            try image_obj.put("file_size", std.json.Value{ .integer = @intCast(image.file_size) });

            var image_size_obj = std.json.ObjectMap.init(arena_allocator);
            try image_size_obj.put("width", std.json.Value{ .integer = @intCast(image.image_size.width) });
            try image_size_obj.put("height", std.json.Value{ .integer = @intCast(image.image_size.height) });
            try image_obj.put("image_size", std.json.Value{ .object = image_size_obj });

            try images_array.append(std.json.Value{ .object = image_obj });
        }
        try json_obj.put("images", std.json.Value{ .array = images_array });
        
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