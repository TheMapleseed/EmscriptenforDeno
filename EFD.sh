#!/bin/bash
# MacOS build script for Emscripten with Deno target using Clang

# Check for required tools
if ! command -v clang++ &> /dev/null; then
    echo "Error: clang++ is required but not found"
    exit 1
fi

if ! command -v deno &> /dev/null; then
    echo "Error: deno is required but not found"
    exit 1
fi

if ! command -v git &> /dev/null; then
    echo "Error: git is required but not found"
    exit 1
fi

if ! command -v cmake &> /dev/null; then
    echo "Error: cmake is required but not found"
    exit 1
fi

# Set up build environment
export CC=clang
export CXX=clang++
export LLVM_ROOT=$(xcode-select -p)/usr/lib/clang
export MACOSX_DEPLOYMENT_TARGET=11.0

# Create build directory
BUILD_DIR="$HOME/emscripten-build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone LLVM for Emscripten
git clone https://github.com/llvm/llvm-project.git
cd llvm-project

# Create build directory for LLVM
mkdir -p build
cd build

# Configure LLVM build with CMake
cmake -G "Unix Makefiles" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TARGETS_TO_BUILD="WebAssembly;X86" \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install" \
    ../llvm

# Build LLVM (using number of CPU cores for parallel build)
make -j$(sysctl -n hw.ncpu)
make install

# Clone Emscripten
cd "$BUILD_DIR"
git clone https://github.com/emscripten-core/emscripten.git
cd emscripten

# Create Emscripten configuration
mkdir -p ~/.emscripten

cat > ~/.emscripten << EOF
import os
EMSCRIPTEN_ROOT = os.path.expanduser('$BUILD_DIR/emscripten')
LLVM_ROOT = os.path.expanduser('$BUILD_DIR/install/bin')
BINARYEN_ROOT = os.path.expanduser('$BUILD_DIR/install')
COMPILER_ENGINE = 'deno'
JS_ENGINES = ['deno']

# Deno-specific settings
DEFAULT_FINAL_SUFFIX = '.js'
ENVIRONMENT = 'web,worker,deno'
EXPORT_ES6 = 1
USE_ES6_IMPORT_META = 0
MODULARIZE = 1

# Build settings
COMPILER_OPTS = [
    '-s', 'ENVIRONMENT=web,worker,deno',
    '-s', 'EXPORT_ES6=1',
    '-s', 'MODULARIZE=1',
    '--emit-unicode=1'
]
EOF

# Create test file
cat > test.c << EOF
#include <emscripten.h>
#include <stdio.h>

EMSCRIPTEN_KEEPALIVE
int add(int a, int b) {
    return a + b;
}
EOF

# Compile test file
"$BUILD_DIR/install/bin/clang" \
    --target=wasm32-unknown-emscripten \
    -o test.wasm \
    test.c \
    -I"$BUILD_DIR/emscripten/system/include" \
    -L"$BUILD_DIR/emscripten/system/lib" \
    -s ENVIRONMENT=web,worker,deno \
    -s EXPORT_ES6=1 \
    -s MODULARIZE=1 \
    --emit-unicode=1

# Create Deno test wrapper
cat > test.ts << EOF
const wasmModule = await WebAssembly.instantiateStreaming(
    fetch("test.wasm"),
    {
        env: {
            emscripten_notify_memory_growth: () => {},
        }
    }
);

const { add } = wasmModule.instance.exports;
console.log("Test result:", add(5, 3));
EOF

# Test the build
echo "Testing Deno build..."
deno run --allow-read --allow-net test.ts

echo "Build complete! Emscripten is installed at $BUILD_DIR/emscripten"
