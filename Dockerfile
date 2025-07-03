# Multi-stage build for Zig RSS Cache Parser
FROM alpine:3.19 AS builder

# Install dependencies for building
RUN apk add --no-cache \
    curl \
    xz \
    ca-certificates

# Install Zig
ARG ZIG_VERSION=0.13.0
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-aarch64-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt && \
        ln -s /opt/zig-linux-aarch64-${ZIG_VERSION}/zig /usr/local/bin/zig; \
    else \
        curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt && \
        ln -s /opt/zig-linux-x86_64-${ZIG_VERSION}/zig /usr/local/bin/zig; \
    fi

# Set working directory
WORKDIR /app

# Copy source files
COPY build.zig .
COPY src/ src/

# Build the parallel version
RUN zig build -Doptimize=ReleaseSafe --verbose

# Production stage
FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    tzdata

# Create non-root user
RUN addgroup -g 1000 scraper && \
    adduser -D -s /bin/sh -u 1000 -G scraper scraper

# Set working directory
WORKDIR /app

# Copy binary from builder stage
COPY --from=builder /app/zig-out/bin/rss-cache-parser-parallel /app/meldeplattform-scraper

# Create cache directory with proper permissions
RUN mkdir -p /app/cache && \
    chown -R scraper:scraper /app

# Switch to non-root user
USER scraper

# Set timezone to Munich
ENV TZ=Europe/Berlin

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD test -f /app/cache/*.json || exit 0

# Default command runs the parallel scraper
CMD ["/app/meldeplattform-scraper"]

# To save output to file, run with:
# docker run --rm -v $(pwd)/output:/app/output meldeplattform-scraper --output /app/output/data.json