const std = @import("std");
const Allocator = std.mem.Allocator;
const json_output = @import("json_output.zig");

pub fn parseImageDimensions(image_data: []const u8) !json_output.ImageDimensions {
    // Try parsing as PNG
    if (parsePngDimensions(image_data)) |dims| {
        return dims;
    } else |_| {}

    // Try parsing as JPEG
    if (parseJpegDimensions(image_data)) |dims| {
        return dims;
    } else |_| {}

    // Add more parsers here (e.g., GIF, BMP) if needed

    return error.UnsupportedImageFormat;
}

fn parsePngDimensions(image_data: []const u8) !json_output.ImageDimensions {
    // Check for PNG signature
    if (image_data.len < 8 or !std.mem.eql(u8, image_data[0..8], "\x89PNG\r\n\x1a\n")) {
        return error.InvalidPngSignature;
    }

    // Find the IHDR chunk
    var pos: usize = 8;
    while (pos + 8 < image_data.len) {
        const chunk_len = std.mem.readInt(u32, @ptrCast(image_data[pos..].ptr), .big);
        const chunk_type = image_data[pos+4 .. pos+8];

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (pos + 16 > image_data.len) {
                return error.InvalidIhdrChunk;
            }
            const width = std.mem.readInt(u32, @ptrCast(image_data[pos+8..].ptr), .big);
            const height = std.mem.readInt(u32, @ptrCast(image_data[pos+12..].ptr), .big);
            return json_output.ImageDimensions{ .width = width, .height = height };
        }

        pos += 8 + chunk_len + 4; // Add 4 for CRC
    }

    return error.IhdrChunkNotFound;
}

fn parseJpegDimensions(image_data: []const u8) !json_output.ImageDimensions {
    // Check for JPEG signature
    if (image_data.len < 2 or !std.mem.eql(u8, image_data[0..2], "\xff\xd8")) {
        return error.InvalidJpegSignature;
    }

    var pos: usize = 2;
    while (pos + 4 < image_data.len) {
        if (image_data[pos] != 0xff) {
            return error.InvalidJpegMarker;
        }

        const marker = image_data[pos+1];
        if (marker == 0xc0 or marker == 0xc1 or marker == 0xc2) { // SOF0, SOF1, SOF2
            if (pos + 9 > image_data.len) {
                return error.InvalidSofMarker;
            }
            const height = std.mem.readInt(u16, @ptrCast(image_data[pos+5..].ptr), .big);
            const width = std.mem.readInt(u16, @ptrCast(image_data[pos+7..].ptr), .big);
            return json_output.ImageDimensions{ .width = @intCast(width), .height = @intCast(height) };
        }

        const len = std.mem.readInt(u16, @ptrCast(image_data[pos+2..].ptr), .big);
        pos += 2 + len;
    }

    return error.SofMarkerNotFound;
}
