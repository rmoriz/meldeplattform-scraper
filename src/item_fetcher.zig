const std = @import("std");
const Allocator = std.mem.Allocator;

const rss_parser = @import("rss_parser.zig");
const http_client = @import("http_client.zig");
const pooled_http_client = @import("pooled_http_client.zig");
const cache = @import("cache.zig");
const json_output = @import("json_output.zig");

pub fn processItem(allocator: Allocator, rss_item: rss_parser.RssItem) !json_output.ProcessedItem {
    const cache_filename = try cache.getCacheFilename(allocator, rss_item.link);
    defer allocator.free(cache_filename);
    
    // Check if we have valid cached data
    if (cache.isCacheValid(cache_filename)) {
        if (cache.loadFromCache(allocator, cache_filename)) |cached_item| {
            defer cached_item.deinit(allocator);
            
            std.io.getStdErr().writer().print("  Using cached data for: {s}\n", .{rss_item.title}) catch {};
            
            return json_output.ProcessedItem{
                .id = json_output.extractIdFromUrl(cached_item.url),
                .title = try allocator.dupe(u8, cached_item.title),
                .url = try allocator.dupe(u8, cached_item.url),
                .pub_date = try allocator.dupe(u8, cached_item.pub_date),
                .creation_date = try extractCreationDate(allocator, cached_item.html_content, cached_item.pub_date),
                .address = try extractAddress(allocator, cached_item.html_content),
                .borough = try extractBorough(allocator, cached_item.html_content),
                .html_content = try allocator.dupe(u8, cached_item.html_content),
                .description = try extractDescription(allocator, cached_item.html_content),
                .cached = true,
            };
        } else |_| {
            // Cache load failed, fall through to fetch
        }
    }
    
    // Fetch fresh data
    std.io.getStdErr().writer().print("  Fetching fresh data for: {s}\n", .{rss_item.title}) catch {};
    
    const html_content = http_client.fetchUrlWithRetry(allocator, rss_item.link, 3) catch |err| {
        std.io.getStdErr().writer().print("  Failed to fetch {s}: {}\n", .{ rss_item.link, err }) catch {};
        return error.FetchFailed;
    };
    defer allocator.free(html_content);
    
    // Create cached item and save it
    const cached_item = cache.CachedItem{
        .timestamp = std.time.timestamp(),
        .url = try allocator.dupe(u8, rss_item.link),
        .html_content = try allocator.dupe(u8, html_content),
        .title = try allocator.dupe(u8, rss_item.title),
        .pub_date = try allocator.dupe(u8, rss_item.pub_date),
    };
    defer cached_item.deinit(allocator);
    
    cache.saveToCache(allocator, cache_filename, cached_item) catch |err| {
        std.io.getStdErr().writer().print("  Warning: Failed to save cache for {s}: {}\n", .{ rss_item.link, err }) catch {};
    };
    
    return json_output.ProcessedItem{
        .id = json_output.extractIdFromUrl(rss_item.link),
        .title = try allocator.dupe(u8, rss_item.title),
        .url = try allocator.dupe(u8, rss_item.link),
        .pub_date = try allocator.dupe(u8, rss_item.pub_date),
        .creation_date = try extractCreationDate(allocator, html_content, rss_item.pub_date),
        .address = try extractAddress(allocator, html_content),
        .borough = try extractBorough(allocator, html_content),
        .html_content = try allocator.dupe(u8, html_content),
        .description = try extractDescription(allocator, html_content),
        .cached = false,
    };
}

fn extractBorough(allocator: Allocator, html_content: []const u8) ![]u8 {
    // Look for "Stadtteil" pattern in HTML - specifically in <dd>Stadtteil Name</dd> format
    if (std.mem.indexOf(u8, html_content, "Stadtteil ")) |pos| {
        const after_stadtteil = html_content[pos + 10..]; // "Stadtteil " is 10 chars
        
        // Find the end of the borough name (until </dd> or line break)
        var borough_end: usize = 0;
        while (borough_end < after_stadtteil.len and borough_end < 150) {
            const char = after_stadtteil[borough_end];
            
            if (char == '<' or char == '\n' or char == '\r') {
                break;
            }
            
            borough_end += 1;
        }
        
        if (borough_end > 3) { // Minimum borough name length
            const potential_borough = std.mem.trim(u8, after_stadtteil[0..borough_end], " \t\r\n");
            if (potential_borough.len > 3) {
                return allocator.dupe(u8, potential_borough);
            }
        }
    }
    
    // Fallback: return empty string if no borough found
    return allocator.dupe(u8, "");
}

fn extractAddress(allocator: Allocator, html_content: []const u8) ![]u8 {
    // Look for "autom. ermittelt:" pattern - this is the main pattern for Munich platform
    if (std.mem.indexOf(u8, html_content, "autom. ermittelt:")) |pos| {
        const after_pattern = html_content[pos + 16..]; // "autom. ermittelt:" is 16 chars
        
        // Skip whitespace
        var i: usize = 0;
        while (i < after_pattern.len and i < 50) {
            const char = after_pattern[i];
            if (char == ' ' or char == '\t' or char == '\n' or char == '\r') {
                i += 1;
                continue;
            }
            break;
        }
        
        if (i < after_pattern.len) {
            const address_start = i;
            var address_end = address_start;
            
            // Extract until we hit a closing parenthesis, line break, or HTML tag
            while (address_end < after_pattern.len and address_end < address_start + 200) {
                const addr_char = after_pattern[address_end];
                
                if (addr_char == ')' or addr_char == '\n' or addr_char == '\r' or addr_char == '<') {
                    break;
                }
                
                address_end += 1;
            }
            
            if (address_end > address_start + 5) {
                const potential_address = std.mem.trim(u8, after_pattern[address_start..address_end], " \t\r\n,.");
                if (potential_address.len > 5) {
                    // Clean up the address by removing trailing "München, Germany" and leading ": "
                    var cleaned_address = cleanAddress(potential_address);
                    cleaned_address = removeLeadingColon(cleaned_address);
                    return allocator.dupe(u8, cleaned_address);
                }
            }
        }
    }
    
    // Fallback: return empty string if no address found
    return allocator.dupe(u8, "");
}

fn cleanAddress(address: []const u8) []const u8 {
    // Remove trailing "München, Germany" or similar patterns
    const patterns_to_remove = [_][]const u8{
        ", Germany",
        " Germany"
    };
    
    var cleaned = address;
    
    for (patterns_to_remove) |pattern| {
        if (std.mem.endsWith(u8, cleaned, pattern)) {
            cleaned = cleaned[0..cleaned.len - pattern.len];
            break; // Only remove one pattern to avoid over-cleaning
        }
    }
    
    return std.mem.trim(u8, cleaned, " \t\r\n,.");
}

fn removeLeadingColon(address: []const u8) []const u8 {
    // Remove leading ": " from address
    if (std.mem.startsWith(u8, address, ": ")) {
        return address[2..];
    } else if (std.mem.startsWith(u8, address, ":")) {
        return address[1..];
    }
    
    return address;
}

fn extractDescription(allocator: Allocator, html_content: []const u8) ![]u8 {
    // Extract the actual report description from the messagetext-detail class
    if (std.mem.indexOf(u8, html_content, "class=\"messagetext-detail\"")) |pos| {
        const after_class = html_content[pos..];
        
        // Find the opening tag end
        if (std.mem.indexOf(u8, after_class, ">")) |tag_end| {
            const content_start = pos + tag_end + 1;
            
            // Find the closing div - look for </div>
            const search_area = html_content[content_start..@min(content_start + 2000, html_content.len)];
            
            if (try extractCleanTextFromArea(allocator, search_area, 50, 1000)) |text| {
                if (text.len > 50) {
                    return text;
                }
                allocator.free(text);
            }
        }
    }
    
    // Fallback: look for meaningful paragraphs
    if (try extractMeaningfulParagraph(allocator, html_content)) |content| {
        return content;
    }
    
    // Last resort: extract general text content
    return extractTextContent(allocator, html_content, 500);
}

fn extractCleanTextFromArea(allocator: Allocator, html_area: []const u8, min_length: usize, max_length: usize) !?[]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var in_tag = false;
    var in_attribution = false;
    var char_count: usize = 0;
    var i: usize = 0;
    
    while (i < html_area.len and char_count < max_length) {
        const char = html_area[i];
        
        if (char == '<') {
            in_tag = true;
            
            // Check if this is the start of an ol-attribution tag
            if (i + 20 < html_area.len) {
                const tag_preview = html_area[i..i + 20];
                if (std.mem.indexOf(u8, tag_preview, "class=\"ol-attribution\"")) |_| {
                    in_attribution = true;
                }
            }
        } else if (char == '>') {
            in_tag = false;
            
            // Check if we're closing an ol-attribution tag
            if (in_attribution and i >= 20) {
                const before_tag = html_area[i-20..i];
                if (std.mem.indexOf(u8, before_tag, "</")) |_| {
                    if (std.mem.indexOf(u8, before_tag, "ol-attribution")) |_| {
                        in_attribution = false;
                    }
                }
            }
        } else if (!in_tag and !in_attribution) {
            if (char == '\n' or char == '\r' or char == '\t') {
                if (result.items.len > 0 and result.items[result.items.len - 1] != ' ') {
                    try result.append(' ');
                    char_count += 1;
                }
            } else if (char != ' ' or (result.items.len > 0 and result.items[result.items.len - 1] != ' ')) {
                try result.append(char);
                char_count += 1;
            }
        }
        
        i += 1;
    }
    
    // Clean up the result and format municipal responses
    const text = std.mem.trim(u8, result.items, " \t\r\n");
    if (text.len >= min_length) {
        const formatted_text = try formatMunicipalResponse(allocator, text);
        return formatted_text;
    }
    
    return null;
}

fn extractMeaningfulParagraph(allocator: Allocator, html: []const u8) !?[]u8 {
    var search_pos: usize = 0;
    
    while (std.mem.indexOfPos(u8, html, search_pos, "<p")) |p_start| {
        if (std.mem.indexOfPos(u8, html, p_start, ">")) |tag_end| {
            const content_start = tag_end + 1;
            
            if (std.mem.indexOfPos(u8, html, content_start, "</p>")) |p_end| {
                const paragraph_content = html[content_start..p_end];
                
                if (try extractCleanTextFromArea(allocator, paragraph_content, 50, 800)) |text| {
                    if (text.len > 50 and !isNavigationText(text)) {
                        return text;
                    }
                    allocator.free(text);
                }
                
                search_pos = p_end + 4;
            } else {
                search_pos = content_start;
            }
        } else {
            search_pos = p_start + 2;
        }
    }
    return null;
}

fn isNavigationText(text: []const u8) bool {
    const nav_words = [_][]const u8{
        "Home", "Menu", "Login", "Anmelden", "Registrieren", 
        "Impressum", "Datenschutz", "Support", "Navigation"
    };
    
    for (nav_words) |word| {
        if (std.mem.indexOf(u8, text, word) != null) {
            return true;
        }
    }
    
    return text.len < 30;
}

fn extractCreationDate(allocator: Allocator, html_content: []const u8, fallback_date: []const u8) ![]u8 {
    // Look for "Diese Meldung wurde am DD.MM.YYYY via api erstellt" pattern
    if (extractDateFromMeldungPattern(html_content)) |date| {
        return allocator.dupe(u8, date);
    }
    
    // Look for "wurde am" patterns
    if (extractDateFromLabel(html_content, "wurde am")) |date| {
        return allocator.dupe(u8, date);
    }
    
    // Look for date in title
    if (extractDateFromTitle(html_content)) |date| {
        return allocator.dupe(u8, date);
    }
    
    // Fallback: Parse publication date from RSS and format it
    if (parseAndFormatDate(allocator, fallback_date)) |formatted_date| {
        return formatted_date;
    } else |_| {
        return allocator.dupe(u8, fallback_date);
    }
}

fn extractDateFromMeldungPattern(html: []const u8) ?[]const u8 {
    const patterns = [_][]const u8{
        "Diese Meldung wurde am",
        "wurde am"
    };
    
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, html, pattern)) |pos| {
            const after_pattern = html[pos + pattern.len..];
            
            var i: usize = 0;
            while (i < after_pattern.len and i < 50) {
                const char = after_pattern[i];
                
                if (char == ' ' or char == '\t' or char == '\n' or char == '\r') {
                    i += 1;
                    continue;
                }
                
                if (std.ascii.isDigit(char)) {
                    const date_start = i;
                    var date_end = date_start;
                    
                    while (date_end < after_pattern.len and date_end < date_start + 10) {
                        const date_char = after_pattern[date_end];
                        if (std.ascii.isDigit(date_char) or date_char == '.') {
                            date_end += 1;
                        } else {
                            break;
                        }
                    }
                    
                    if (date_end == date_start + 10) {
                        const potential_date = after_pattern[date_start..date_end];
                        if (isValidDate(potential_date)) {
                            return potential_date;
                        }
                    }
                }
                i += 1;
            }
        }
    }
    return null;
}

fn extractDateFromLabel(html: []const u8, label: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, html, label)) |pos| {
        const after_label = html[pos + label.len..];
        
        var i: usize = 0;
        while (i < after_label.len and i < 200) {
            const char = after_label[i];
            
            if (char == ' ' or char == '\t' or char == '\n' or char == '\r' or 
                char == '<' or char == '>') {
                i += 1;
                continue;
            }
            
            if (std.ascii.isDigit(char)) {
                const date_start = i;
                var date_end = date_start;
                
                while (date_end < after_label.len and date_end < date_start + 15) {
                    const date_char = after_label[date_end];
                    if (std.ascii.isDigit(date_char) or date_char == '.' or 
                        date_char == '/' or date_char == '-') {
                        date_end += 1;
                    } else {
                        break;
                    }
                }
                
                if (date_end > date_start + 7) {
                    const potential_date = std.mem.trim(u8, after_label[date_start..date_end], " \t\r\n");
                    if (isValidDate(potential_date)) {
                        return potential_date;
                    }
                }
            }
            i += 1;
        }
    }
    return null;
}

fn isValidDate(date_str: []const u8) bool {
    if (date_str.len != 10) return false;
    
    if (std.ascii.isDigit(date_str[0]) and std.ascii.isDigit(date_str[1]) and date_str[2] == '.' and
        std.ascii.isDigit(date_str[3]) and std.ascii.isDigit(date_str[4]) and date_str[5] == '.' and
        std.ascii.isDigit(date_str[6]) and std.ascii.isDigit(date_str[7]) and 
        std.ascii.isDigit(date_str[8]) and std.ascii.isDigit(date_str[9])) {
        
        const day = (date_str[0] - '0') * 10 + (date_str[1] - '0');
        const month = (date_str[3] - '0') * 10 + (date_str[4] - '0');
        
        return day >= 1 and day <= 31 and month >= 1 and month <= 12;
    }
    
    return false;
}

fn extractDateFromTitle(html: []const u8) ?[]const u8 {
    if (extractHtmlTag(html, "title")) |title| {
        if (title.len >= 10) {
            const potential_date = title[0..10];
            if (isValidDate(potential_date)) {
                return potential_date;
            }
        }
        
        var i: usize = 0;
        while (i < title.len and i < title.len - 9) {
            if (std.ascii.isDigit(title[i])) {
                const potential_date = title[i..@min(i + 10, title.len)];
                if (potential_date.len == 10 and isValidDate(potential_date)) {
                    return potential_date;
                }
            }
            i += 1;
        }
    }
    return null;
}

fn parseAndFormatDate(allocator: Allocator, rss_date: []const u8) ![]u8 {
    if (rss_date.len < 16) return error.InvalidDate;
    
    if (std.mem.indexOf(u8, rss_date, ", ")) |comma_pos| {
        const after_comma = rss_date[comma_pos + 2..];
        
        var day_end: usize = 0;
        while (day_end < after_comma.len and std.ascii.isDigit(after_comma[day_end])) {
            day_end += 1;
        }
        
        if (day_end == 0) return error.InvalidDate;
        const day = after_comma[0..day_end];
        
        if (day_end + 1 < after_comma.len) {
            const month_start = day_end + 1;
            var month_end = month_start;
            while (month_end < after_comma.len and after_comma[month_end] != ' ') {
                month_end += 1;
            }
            
            if (month_end > month_start) {
                const month_name = after_comma[month_start..month_end];
                const month_num = getMonthNumber(month_name);
                
                if (month_end + 1 < after_comma.len) {
                    const year_start = month_end + 1;
                    var year_end = year_start;
                    while (year_end < after_comma.len and std.ascii.isDigit(after_comma[year_end])) {
                        year_end += 1;
                    }
                    
                    if (year_end > year_start and year_end - year_start == 4) {
                        const year = after_comma[year_start..year_end];
                        return std.fmt.allocPrint(allocator, "{s:0>2}.{d:0>2}.{s}", .{ day, month_num, year });
                    }
                }
            }
        }
    }
    
    return error.InvalidDate;
}

fn getMonthNumber(month_name: []const u8) u8 {
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    };
    
    for (months, 0..) |month, i| {
        if (std.mem.eql(u8, month_name, month)) {
            return @intCast(i + 1);
        }
    }
    
    return 1;
}

fn extractHtmlTag(html: []const u8, tag: []const u8) ?[]const u8 {
    const open_tag = std.fmt.allocPrint(std.heap.page_allocator, "<{s}", .{tag}) catch return null;
    defer std.heap.page_allocator.free(open_tag);
    const close_tag = std.fmt.allocPrint(std.heap.page_allocator, "</{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(close_tag);
    
    if (std.mem.indexOf(u8, html, open_tag)) |start_pos| {
        if (std.mem.indexOf(u8, html[start_pos..], ">")) |tag_end| {
            const content_start = start_pos + tag_end + 1;
            if (std.mem.indexOf(u8, html[content_start..], close_tag)) |end_pos| {
                return html[content_start..content_start + end_pos];
            }
        }
    }
    return null;
}

fn extractTextContent(allocator: Allocator, html_content: []const u8, max_length: usize) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var in_tag = false;
    var char_count: usize = 0;
    
    for (html_content) |char| {
        if (char == '<') {
            in_tag = true;
        } else if (char == '>') {
            in_tag = false;
        } else if (!in_tag and char_count < max_length) {
            if (char != '\n' and char != '\r' and char != '\t') {
                try result.append(char);
                char_count += 1;
            } else if (result.items.len > 0 and result.items[result.items.len - 1] != ' ') {
                try result.append(' ');
                char_count += 1;
            }
        }
        
        if (char_count >= max_length) break;
    }
    
    return result.toOwnedSlice();
}

fn formatMunicipalResponse(allocator: Allocator, text: []const u8) ![]u8 {
    // First, filter out unwanted footer content
    const filtered_text = try filterUnwantedContent(allocator, text);
    defer allocator.free(filtered_text);
    
    // Look for "Antwort von Landeshauptstadt München" and add proper formatting
    if (std.mem.indexOf(u8, filtered_text, "Antwort von Landeshauptstadt München")) |pos| {
        const response_phrase = "Antwort von Landeshauptstadt München";
        const response_end = pos + response_phrase.len;
        
        // Check if already properly formatted (with newlines before and ":\n\n" after)
        var already_formatted = false;
        if (response_end + 3 <= filtered_text.len) {
            const after_response = filtered_text[response_end..response_end + 3];
            if (std.mem.eql(u8, after_response, ":\n\n")) {
                // Check if there are proper newlines before as well
                if (pos >= 2) {
                    const before_response = filtered_text[pos-2..pos];
                    if (std.mem.eql(u8, before_response, "\n\n")) {
                        already_formatted = true;
                    }
                }
            }
        }
        
        if (already_formatted) {
            return allocator.dupe(u8, filtered_text);
        }
        
        // Create new text with proper formatting
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        // Check if we need to add newlines before the response
        var needs_newlines_before = true;
        if (pos >= 2) {
            const before_response = filtered_text[pos-2..pos];
            if (std.mem.eql(u8, before_response, "\n\n") or 
                std.mem.eql(u8, before_response, ". ") or
                std.mem.eql(u8, before_response, "! ") or
                std.mem.eql(u8, before_response, "? ")) {
                needs_newlines_before = false;
            }
        }
        
        // Add text before the response
        if (needs_newlines_before) {
            // Remove any single space before "Antwort"
            var text_before_pos = pos;
            if (pos > 0 and filtered_text[pos-1] == ' ') {
                text_before_pos = pos - 1;
            }
            try result.appendSlice(filtered_text[0..text_before_pos]);
            try result.appendSlice("\n\nAntwort von Landeshauptstadt München");
        } else {
            try result.appendSlice(filtered_text[0..response_end]);
        }
        
        // Add ":\n\n" after the response phrase
        try result.appendSlice(":\n\n");
        
        // Add the rest of the text, but skip any existing colon or spacing
        var remaining_start = response_end;
        if (remaining_start < filtered_text.len) {
            // Skip any existing colon and whitespace (but preserve intentional spacing)
            while (remaining_start < filtered_text.len and 
                   (filtered_text[remaining_start] == ':' or 
                    filtered_text[remaining_start] == ' ' or 
                    filtered_text[remaining_start] == '\t')) {
                remaining_start += 1;
            }
            
            // Skip only immediate newlines after colon/spaces, but preserve paragraph breaks
            while (remaining_start < filtered_text.len and 
                   (filtered_text[remaining_start] == '\n' or 
                    filtered_text[remaining_start] == '\r')) {
                remaining_start += 1;
            }
            
            if (remaining_start < filtered_text.len) {
                try result.appendSlice(filtered_text[remaining_start..]);
            }
        }
        
        return result.toOwnedSlice();
    }
    
    // Also handle the shorter version "Antwort von Landeshauptstadt" for backward compatibility
    if (std.mem.indexOf(u8, filtered_text, "Antwort von Landeshauptstadt")) |pos| {
        // Look backwards to see if we need to add spacing
        var needs_spacing = true;
        if (pos >= 2) {
            // Check if there are already line breaks before the response
            const before_response = filtered_text[pos-2..pos];
            if (std.mem.eql(u8, before_response, "\n\n") or 
                std.mem.eql(u8, before_response, "  ")) {
                needs_spacing = false;
            }
        }
        
        if (needs_spacing) {
            // Create new text with proper spacing
            var result = std.ArrayList(u8).init(allocator);
            defer result.deinit();
            
            // Add text before the response
            try result.appendSlice(filtered_text[0..pos]);
            
            // Add empty line before municipal response
            try result.appendSlice("\n\nAntwort von Landeshauptstadt");
            
            // Add the rest of the text after "Antwort von Landeshauptstadt"
            const response_start = pos + "Antwort von Landeshauptstadt".len;
            if (response_start < filtered_text.len) {
                try result.appendSlice(filtered_text[response_start..]);
            }
            
            return result.toOwnedSlice();
        }
    }
    
    // No formatting needed, return filtered text
    return allocator.dupe(u8, filtered_text);
}

fn filterUnwantedContent(allocator: Allocator, text: []const u8) ![]u8 {
    // List of unwanted patterns to filter out
    const unwanted_patterns = [_][]const u8{
        "Meldungsposition",
        "OpenStreetMap-Mitwirkende",
        "Hauskoordinaten:",
        "Bayrische Vermessungsverwaltung",
        "OpenStreetMap",
        "&middot;",
        "Nr.836",
        "\"group\":\"Karten\"",
        "\"url\":\"https://map1.mvv-muenchen.de",
        "\"visible\":1",
        "\"crossorigin\":0",
        "\"type\"",
    };
    
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var i: usize = 0;
    while (i < text.len) {
        var found_unwanted = false;
        
        // Check if any unwanted pattern starts at current position
        for (unwanted_patterns) |pattern| {
            if (i + pattern.len <= text.len and std.mem.startsWith(u8, text[i..], pattern)) {
                // Found unwanted pattern, skip to end of line or find a good stopping point
                while (i < text.len and text[i] != '\n') {
                    i += 1;
                }
                found_unwanted = true;
                break;
            }
        }
        
        if (!found_unwanted) {
            try result.append(text[i]);
            i += 1;
        }
    }
    
    // Clean up any trailing whitespace and multiple newlines
    const cleaned = std.mem.trim(u8, result.items, " \t\r\n");
    
    // Remove multiple consecutive spaces and newlines
    var final_result = std.ArrayList(u8).init(allocator);
    defer final_result.deinit();
    
    var prev_was_space = false;
    for (cleaned) |char| {
        if (char == ' ' or char == '\t' or char == '\r' or char == '\n') {
            if (!prev_was_space) {
                try final_result.append(' ');
                prev_was_space = true;
            }
        } else {
            try final_result.append(char);
            prev_was_space = false;
        }
    }
    
    return final_result.toOwnedSlice();
}