#!/bin/bash

# Build script for MK Patch Librarian
set -e

echo "=========================================="
echo "  MK Patch Librarian - Build Script"
echo "=========================================="

cd "$(dirname "$0")"

# Check if Swift is installed
if ! command -v swift &> /dev/null; then
    echo "Error: Swift not found. Please install Xcode Command Line Tools."
    exit 1
fi

echo "Swift version:"
swift --version

# Build the project
echo ""
echo "Building..."
swift build --package-path . -c release

if [ $? -eq 0 ]; then
    echo ""
    echo "Build successful!"
    
    # Find the executable
    BINARY_PATH="$(swift build --package-path . -c release --show-bin-path)/MKPatchLibrarian"
    
    if [ -n "$BINARY_PATH" ]; then
        echo ""
        echo "Executable location: $BINARY_PATH"
        
        # Make executable if not already
        chmod +x "$BINARY_PATH" 2>/dev/null || true
        
        echo ""
        echo "To run the app:"
        echo "  $BINARY_PATH"
    fi
else
    echo ""
    echo "Build failed!"
    exit 1
fi

echo ""
echo "=========================================="
echo "  Build Complete!"
echo "=========================================="
