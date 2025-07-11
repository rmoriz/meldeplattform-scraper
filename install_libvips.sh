#!/bin/bash

# Script to install libvips on different platforms

set -e

echo "Installing libvips..."

# Detect the platform
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    if command -v apt-get &> /dev/null; then
        # Debian/Ubuntu
        echo "Detected Debian/Ubuntu system"
        sudo apt-get update
        sudo apt-get install -y libvips-dev pkg-config
    elif command -v yum &> /dev/null; then
        # RHEL/CentOS/Fedora
        echo "Detected RHEL/CentOS/Fedora system"
        sudo yum install -y vips-devel pkgconfig
    elif command -v pacman &> /dev/null; then
        # Arch Linux
        echo "Detected Arch Linux system"
        sudo pacman -S libvips pkgconf
    else
        echo "Unsupported Linux distribution. Please install libvips manually."
        exit 1
    fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    echo "Detected macOS system"
    if command -v brew &> /dev/null; then
        brew install vips pkg-config
    else
        echo "Homebrew not found. Please install Homebrew first or install libvips manually."
        exit 1
    fi
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    # Windows
    echo "Detected Windows system"
    echo "Please install libvips manually from: https://github.com/libvips/libvips/releases"
    echo "Or use vcpkg: vcpkg install libvips"
    exit 1
else
    echo "Unsupported operating system: $OSTYPE"
    exit 1
fi

echo "libvips installation completed!"
echo "Verifying installation..."

if pkg-config --exists vips; then
    echo "✓ libvips found: $(pkg-config --modversion vips)"
else
    echo "✗ libvips not found in pkg-config"
    exit 1
fi