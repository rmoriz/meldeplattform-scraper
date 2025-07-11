# Multi-stage build for Zig RSS Cache Parser
FROM alpine:3.22 AS builder

# Install dependencies for building
RUN apk add --no-cache \
    curl \
    xz \
    ca-certificates \
    vips-dev \
    glib-dev \
    gobject-introspection-dev \
    build-base \
    pkgconfig \
    musl-dev

# Install Zig - use target-specific architecture
ARG ZIG_VERSION=0.14.1
ARG TARGETARCH
RUN echo "TARGETARCH is: ${TARGETARCH}" && \
    case "${TARGETARCH:-amd64}" in \
        "arm64") ZIG_ARCH="aarch64" ;; \
        "amd64") ZIG_ARCH="x86_64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}, defaulting to x86_64" && ZIG_ARCH="x86_64" ;; \
    esac && \
    echo "Using ZIG_ARCH: ${ZIG_ARCH}" && \
    curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt && \
    ln -s /opt/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}/zig /usr/local/bin/zig

# Set working directory
WORKDIR /app

# Copy source files
COPY build.zig .
COPY src/ src/

# Build the parallel version with explicit target architecture
ARG TARGETARCH
RUN echo "Building for TARGETARCH: ${TARGETARCH}" && \
    case "${TARGETARCH:-amd64}" in \
        "arm64") \
            echo "Building for ARM64 with ReleaseSmall optimization" && \
            zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall; \
            ;; \
        "amd64") \
            echo "Building for AMD64 with ReleaseSafe optimization" && \
            zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe; \
            ;; \
        *) \
            echo "Unsupported architecture: ${TARGETARCH}, defaulting to AMD64" && \
            zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe; \
            ;; \
    esac

# Production stage
FROM alpine:3.22

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    vips \
    glib \
    musl

# Create non-root user
RUN addgroup -g 1000 scraper && \
    adduser -D -s /bin/sh -u 1000 -G scraper scraper

# Set working directory
WORKDIR /app

# Copy binary from builder stage
COPY --from=builder /app/zig-out/bin/meldeplattform-scraper-parallel /app/meldeplattform-scraper

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

# Set the entrypoint to the application
ENTRYPOINT ["/app/meldeplattform-scraper"]

# Default command (can be overridden)
CMD []

# To save output to file, run with:
# docker run --rm -v $(pwd)/output:/app/output meldeplattform-scraper --output /app/output/data.json