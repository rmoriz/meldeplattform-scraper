# RSS Cache Parser

A Zig-based RSS feed parser with local caching and HTML content extraction for the Munich bike reporting platform.

## Features

- Fetches RSS feed from `https://meldeplattform-rad.muenchenunterwegs.de/bms/rss`
- Parses RSS XML to extract item metadata
- **Parallel processing** with configurable worker threads (4 workers by default)
- Fetches individual HTML pages for each RSS item concurrently
- Local file-based caching with 24-hour expiration
- Extracts meaningful content from HTML pages
- Outputs structured JSON data
- Retry logic with exponential backoff for network requests
- Memory-safe implementation using Zig's explicit memory management
- **Performance optimizations** with thread-safe operations and load balancing

## Project Structure

```
├── build.zig              # Zig build configuration
├── src/
│   ├── main.zig          # Entry point and orchestration
│   ├── rss_parser.zig    # RSS XML parsing
│   ├── http_client.zig   # HTTP client with retry logic
│   ├── cache.zig         # File-based caching system
│   ├── item_fetcher.zig  # HTML content fetching and parsing
│   └── json_output.zig   # JSON serialization
└── cache/                # Cache directory (created at runtime)
```

## Installation & Usage

### Prerequisites
- Zig 0.11.0 or later

### Build
```bash
zig build
```

### Run

**Sequential version (original):**
```bash
zig build run
# or
./zig-out/bin/rss-cache-parser [OPTIONS]
```

**Parallel version (optimized):**
```bash
zig build run-parallel
# or
./zig-out/bin/rss-cache-parser-parallel [OPTIONS]
```

### CLI Options

Both versions support the following command-line options:

```bash
# Show help
./zig-out/bin/rss-cache-parser-parallel --help
./zig-out/bin/rss-cache-parser-parallel -h

# Save JSON output to file
./zig-out/bin/rss-cache-parser-parallel --output munich_reports.json
./zig-out/bin/rss-cache-parser-parallel -o data.json

# Default behavior (output to stdout)
./zig-out/bin/rss-cache-parser-parallel
```

### Performance Benchmark
```bash
python3 benchmark.py
```

## How It Works

1. **RSS Parsing**: Fetches and parses the RSS feed to extract item URLs and metadata
2. **Caching Strategy**: 
   - Uses SHA-256 hash of URL as cache filename
   - Stores cached data as JSON with timestamp
   - Checks file modification time for 24-hour expiration
3. **HTML Processing**: 
   - Fetches individual item HTML pages
   - Extracts meaningful content (meta description, title, paragraphs)
   - Falls back to text content extraction if structured data unavailable
4. **Output**: Generates structured JSON with all processed items

## Cache Structure

Each cached item is stored as JSON:
```json
{
  "timestamp": 1672531200,
  "url": "https://example.com/item/123",
  "html_content": "<html>...</html>",
  "title": "Item Title",
  "pub_date": "Wed, 02 Jul 2025 18:32:19 +0000"
}
```

## Output Format

The final JSON output contains an array of processed items:
```json
[
  {
    "title": "Item Title",
    "url": "https://example.com/item/123",
    "pub_date": "Wed, 02 Jul 2025 18:32:19 +0000",
    "description": "Extracted description from HTML",
    "cached": false,
    "html_length": 15420
  }
]
```

## Error Handling

- Network failures: Automatic retry with exponential backoff (up to 3 attempts)
- Parse failures: Logged and skipped, processing continues with other items
- Cache failures: Falls back to direct fetch
- Graceful degradation: Returns partial results if some items fail

## Performance Features

- **Parallel Processing**: Multi-threaded execution with configurable worker count
- **Memory Management**: Uses arena allocators for temporary data, explicit cleanup
- **Caching**: Reduces network load with 24-hour cache expiration
- **Thread Safety**: Mutex-protected operations for concurrent access
- **Load Balancing**: Optimal work distribution across worker threads
- **Resource Limits**: Configurable limits for HTTP response sizes
- **Performance Monitoring**: Built-in timing and throughput metrics

### Performance Improvements

Parallel processing provides significant speedup for RSS feeds with many items:

- **2x speedup** with 2 workers on typical workloads
- **3-4x speedup** with 4 workers on I/O-bound operations
- **Automatic fallback** to sequential processing for small workloads
- **Efficient scaling** up to the number of available CPU cores

## Docker Usage

### Build and Run with Docker

```bash
# Build the Docker image
docker build -t meldeplattform-scraper .

# Run with output to stdout
docker run --rm meldeplattform-scraper

# Save output to file (with volume mount)
docker run --rm -v $(pwd)/output:/app/output meldeplattform-scraper --output /app/output/munich_reports.json

# Run with docker-compose
docker-compose up

# Pull from GitHub Container Registry
docker pull ghcr.io/[username]/meldeplattform-scraper:latest
```

### Automated Builds

GitHub Actions automatically builds and publishes Docker images to GitHub Container Registry on every push to main branch.

## Configuration

Key constants can be modified in the source files:
- `CACHE_EXPIRY_HOURS` in `cache.zig` (default: 24)
- `RSS_URL` in `main.zig`
- HTTP timeout and retry settings in `http_client.zig`

### CLI Options Reference

| Option | Short | Description | Example |
|--------|-------|-------------|---------|
| `--help` | `-h` | Show usage information | `./scraper -h` |
| `--output <file>` | `-o <file>` | Save JSON to file instead of stdout | `./scraper -o data.json` |

## Dependencies

- Zig standard library only
- No external dependencies required
- Uses built-in HTTP client, JSON parser, and crypto functions