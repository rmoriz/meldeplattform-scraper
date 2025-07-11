const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("vips/vips.h");
});

pub const ResizeConfig = struct {
    max_width: u32 = 800,
    max_height: u32 = 600,
    quality: u8 = 85, // JPEG quality (0-100)
    preserve_aspect_ratio: bool = true,
};

pub const ResizeError = error{
    VipsInitFailed,
    VipsOperationFailed,
    UnsupportedFormat,
    OutOfMemory,
    InvalidImageData,
};

var vips_initialized = false;

pub fn initVips() !void {
    if (!vips_initialized) {
        if (c.vips_init("zig-image-resizer") != 0) {
            return ResizeError.VipsInitFailed;
        }
        vips_initialized = true;
    }
}

pub fn deinitVips() void {
    if (vips_initialized) {
        c.vips_shutdown();
        vips_initialized = false;
    }
}

pub fn resizeImage(allocator: Allocator, image_data: []const u8, config: ResizeConfig) ![]u8 {
    try initVips();
    
    // Load image from memory
    var image: ?*c.VipsImage = null;
    if (c.vips_jpegload_buffer(@constCast(image_data.ptr), image_data.len, &image, @as(?*anyopaque, null)) != 0) {
        // Try PNG if JPEG fails
        if (c.vips_pngload_buffer(@constCast(image_data.ptr), image_data.len, &image, @as(?*anyopaque, null)) != 0) {
            // Try WebP if PNG fails
            if (c.vips_webpload_buffer(@constCast(image_data.ptr), image_data.len, &image, @as(?*anyopaque, null)) != 0) {
                return ResizeError.UnsupportedFormat;
            }
        }
    }
    
    if (image == null) {
        return ResizeError.InvalidImageData;
    }
    defer c.g_object_unref(image);
    
    // Get original dimensions
    const original_width = @as(u32, @intCast(c.vips_image_get_width(image)));
    const original_height = @as(u32, @intCast(c.vips_image_get_height(image)));
    
    // Calculate new dimensions
    const new_dims = calculateNewDimensions(original_width, original_height, config);
    
    // Skip resizing if image is already smaller than target
    if (new_dims.width >= original_width and new_dims.height >= original_height) {
        return allocator.dupe(u8, image_data);
    }
    
    // Resize the image
    var resized: ?*c.VipsImage = null;
    const scale_factor = @min(
        @as(f64, @floatFromInt(new_dims.width)) / @as(f64, @floatFromInt(original_width)),
        @as(f64, @floatFromInt(new_dims.height)) / @as(f64, @floatFromInt(original_height))
    );
    
    if (c.vips_resize(image, &resized, scale_factor, @as(?*anyopaque, null)) != 0) {
        return ResizeError.VipsOperationFailed;
    }
    defer c.g_object_unref(resized);
    
    // Convert to JPEG buffer
    var output_buffer: ?*anyopaque = null;
    var output_size: usize = 0;
    
    if (c.vips_jpegsave_buffer(resized, &output_buffer, &output_size, 
        "Q", @as(c_int, config.quality),
        "optimize_coding", @as(c_int, 1),
        "strip", @as(c_int, 1), // Remove metadata to reduce size
        @as(?*anyopaque, null)) != 0) {
        return ResizeError.VipsOperationFailed;
    }
    
    if (output_buffer == null) {
        return ResizeError.VipsOperationFailed;
    }
    
    // Copy the buffer to Zig-managed memory
    const result = try allocator.alloc(u8, output_size);
    @memcpy(result, @as([*]u8, @ptrCast(output_buffer))[0..output_size]);
    
    // Free the vips buffer
    c.g_free(output_buffer);
    
    return result;
}

const NewDimensions = struct {
    width: u32,
    height: u32,
};

fn calculateNewDimensions(original_width: u32, original_height: u32, config: ResizeConfig) NewDimensions {
    if (!config.preserve_aspect_ratio) {
        return NewDimensions{
            .width = config.max_width,
            .height = config.max_height,
        };
    }
    
    // Calculate scale factor to fit within max dimensions while preserving aspect ratio
    const width_scale = @as(f64, @floatFromInt(config.max_width)) / @as(f64, @floatFromInt(original_width));
    const height_scale = @as(f64, @floatFromInt(config.max_height)) / @as(f64, @floatFromInt(original_height));
    const scale = @min(width_scale, height_scale);
    
    // Don't upscale images
    const final_scale = @min(scale, 1.0);
    
    return NewDimensions{
        .width = @intFromFloat(@as(f64, @floatFromInt(original_width)) * final_scale),
        .height = @intFromFloat(@as(f64, @floatFromInt(original_height)) * final_scale),
    };
}

// Test function to verify libvips integration
pub fn testVipsIntegration() !void {
    try initVips();
    std.debug.print("libvips version: {s}\n", .{c.vips_version_string()});
    deinitVips();
}