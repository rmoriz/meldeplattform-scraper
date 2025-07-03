const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const json_output = @import("json_output.zig");

/// Memory-optimized JSON serialization that avoids intermediate allocations
pub fn itemsToJsonOptimized(allocator: Allocator, items: []const json_output.ProcessedItem) ![]u8 {
    var buffer = ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    const writer = buffer.writer();
    
    try writer.writeAll("[\n");
    
    for (items, 0..) |item, i| {
        if (i > 0) {
            try writer.writeAll(",\n");
        }
        
        try writer.writeAll("  {\n");
        
        // Write each field manually to avoid JSON object allocations
        try writeJsonFieldInt(writer, "id", item.id, true);
        try writeJsonField(writer, "title", item.title, true);
        try writeJsonField(writer, "url", item.url, true);
        try writeJsonField(writer, "pub_date", item.pub_date, true);
        try writeJsonField(writer, "creation_date", item.creation_date, true);
        try writeJsonField(writer, "address", item.address, true);
        try writeJsonField(writer, "borough", item.borough, true);
        try writeJsonField(writer, "description", item.description, true);
        try writeJsonFieldBool(writer, "cached", item.cached, true);
        try writeJsonFieldInt(writer, "html_length", item.html_content.len, false);
        
        try writer.writeAll("\n  }");
    }
    
    try writer.writeAll("\n]");
    
    return buffer.toOwnedSlice();
}

fn writeJsonField(writer: anytype, key: []const u8, value: []const u8, comma: bool) !void {
    try writer.print("    \"{s}\": \"", .{key});
    
    // Escape JSON string
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(char),
        }
    }
    
    try writer.writeByte('"');
    if (comma) {
        try writer.writeByte(',');
    }
    try writer.writeByte('\n');
}

fn writeJsonFieldBool(writer: anytype, key: []const u8, value: bool, comma: bool) !void {
    try writer.print("    \"{s}\": {}", .{ key, value });
    if (comma) {
        try writer.writeByte(',');
    }
    try writer.writeByte('\n');
}

fn writeJsonFieldInt(writer: anytype, key: []const u8, value: anytype, comma: bool) !void {
    try writer.print("    \"{s}\": {}", .{ key, value });
    if (comma) {
        try writer.writeByte(',');
    }
    try writer.writeByte('\n');
}