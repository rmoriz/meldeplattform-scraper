const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const RssItem = struct {
    title: []u8,
    link: []u8,
    description: []u8,
    pub_date: []u8,
    guid: []u8,

    pub fn deinit(self: RssItem, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.link);
        allocator.free(self.description);
        allocator.free(self.pub_date);
        allocator.free(self.guid);
    }
};

pub fn parseRss(allocator: Allocator, rss_content: []const u8) !ArrayList(RssItem) {
    var items = ArrayList(RssItem).init(allocator);
    
    var lines = std.mem.splitScalar(u8, rss_content, '\n');
    var current_item: ?RssItem = null;
    var in_item = false;
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        
        if (std.mem.indexOf(u8, trimmed, "<item>")) |_| {
            in_item = true;
            current_item = RssItem{
                .title = try allocator.dupe(u8, ""),
                .link = try allocator.dupe(u8, ""),
                .description = try allocator.dupe(u8, ""),
                .pub_date = try allocator.dupe(u8, ""),
                .guid = try allocator.dupe(u8, ""),
            };
        } else if (std.mem.indexOf(u8, trimmed, "</item>")) |_| {
            if (current_item) |item| {
                try items.append(item);
                current_item = null;
            }
            in_item = false;
        } else if (in_item and current_item != null) {
            if (extractXmlContent(trimmed, "title")) |content| {
                allocator.free(current_item.?.title);
                current_item.?.title = try allocator.dupe(u8, content);
            } else if (extractXmlContent(trimmed, "link")) |content| {
                allocator.free(current_item.?.link);
                current_item.?.link = try allocator.dupe(u8, content);
            } else if (extractXmlContent(trimmed, "description")) |content| {
                allocator.free(current_item.?.description);
                current_item.?.description = try allocator.dupe(u8, content);
            } else if (extractXmlContent(trimmed, "pubDate")) |content| {
                allocator.free(current_item.?.pub_date);
                current_item.?.pub_date = try allocator.dupe(u8, content);
            } else if (extractXmlContent(trimmed, "guid")) |content| {
                allocator.free(current_item.?.guid);
                current_item.?.guid = try allocator.dupe(u8, content);
            }
        }
    }
    
    return items;
}

fn extractXmlContent(line: []const u8, tag: []const u8) ?[]const u8 {
    const open_tag = std.fmt.allocPrint(std.heap.page_allocator, "<{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(open_tag);
    const close_tag = std.fmt.allocPrint(std.heap.page_allocator, "</{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(close_tag);
    
    if (std.mem.indexOf(u8, line, open_tag)) |start_pos| {
        const content_start = start_pos + open_tag.len;
        if (std.mem.indexOf(u8, line[content_start..], close_tag)) |end_pos| {
            return line[content_start..content_start + end_pos];
        }
    }
    return null;
}