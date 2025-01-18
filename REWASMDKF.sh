#!/bin/bash
# Combined WASM build and Deno hosting environment for Kata-Firecracker

set -e

# Configuration
KATA_NAME="deno-wasm-env"
BUILD_DIR="/opt/wasm"
DENO_PORT="8000"

# Create pod configuration with port forwarding
cat > deno-wasm-pod.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${KATA_NAME}
  annotations:
    io.kata-containers.config.hypervisor.firecracker: "true"
spec:
  runtimeClassName: kata-fc
  containers:
  - name: deno-wasm
    image: debian:bullseye-slim
    command: ["sleep", "infinity"]
    ports:
    - containerPort: ${DENO_PORT}
      hostPort: ${DENO_PORT}
    resources:
      requests:
        memory: "7Gi"
        cpu: "3"
      limits:
        memory: "8Gi"
        cpu: "4"
    volumeMounts:
    - name: build-output
      mountPath: ${BUILD_DIR}
    securityContext:
      privileged: true
  volumes:
  - name: build-output
    hostPath:
      path: ${BUILD_DIR}
      type: DirectoryOrCreate
EOF

# Create setup script for the container
cat > setup-environment.sh << 'EOF'
#!/bin/bash
set -e

# Install build dependencies
apt-get update
apt-get install -y \
    git \
    curl \
    wget \
    build-essential \
    cmake \
    python3 \
    clang \
    lld \
    pkg-config \
    libssl-dev

# Install Rust and WASM tools
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Add WASM target and tools
rustup target add wasm32-unknown-unknown
rustup target add wasm32-wasi
cargo install wasm-bindgen-cli
cargo install wasm-pack

# Configure Rust for optimized WASM builds
cat > ${BUILD_DIR}/wasm-config.toml << 'RUSTCONFIG'
[build]
target = "wasm32-unknown-unknown"

[target.wasm32-unknown-unknown]
rustflags = [
    "-C", "link-arg=-s",
    "-C", "opt-level=3",
    "-C", "target-feature=+bulk-memory,+mutable-globals,+reference-types,+simd128"
]
RUSTCONFIG

# Install Deno
curl -fsSL https://deno.land/x/install/install.sh | sh
mv /root/.deno/bin/deno /usr/local/bin/

# Install Emscripten
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk
./emsdk install latest
./emsdk activate latest
source ./emsdk_env.sh

# Configure Emscripten for Deno
cat > ~/.emscripten << 'CONFIG'
import os
EMSCRIPTEN_ROOT = os.path.expanduser('~/emsdk/upstream/emscripten')
LLVM_ROOT = os.path.expanduser('~/emsdk/upstream/bin')
BINARYEN_ROOT = os.path.expanduser('~/emsdk/upstream')
COMPILER_ENGINE = '/usr/local/bin/deno'
JS_ENGINES = ['/usr/local/bin/deno']

# Build settings
COMPILER_OPTS = [
    '-s', 'ENVIRONMENT=web,worker,deno',
    '-s', 'EXPORT_ES6=1',
    '-s', 'USE_ES6_IMPORT_META=0',
    '-s', 'MODULARIZE=1',
    '--emit-unicode=1'
]
CONFIG

# Create Deno server file
cat > ${BUILD_DIR}/server.ts << 'DENO'
import { serve } from "https://deno.land/std/http/server.ts";

const MIME_TYPES: Record<string, string> = {
  ".wasm": "application/wasm",
  ".js": "application/javascript",
  ".ts": "application/typescript",
  ".html": "text/html",
};

async function handleRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const filepath = decodeURIComponent(url.pathname);
  
  try {
    if (filepath === "/") {
      // Serve index page listing available WASM modules
      const files = [];
      for await (const entry of Deno.readDir(BUILD_DIR)) {
        if (entry.isFile && entry.name.endsWith(".wasm")) {
          files.push(entry.name);
        }
      }
      
      const html = `
        <!DOCTYPE html>
        <html>
        <head><title>WASM Modules</title></head>
        <body>
          <h1>Available WASM Modules</h1>
          <ul>
            ${files.map(file => `<li><a href="/${file}">${file}</a></li>`).join("\n")}
          </ul>
        </body>
        </html>
      `;
      return new Response(html, {
        headers: { "content-type": "text/html" },
      });
    }
    
    // Serve requested file
    const ext = filepath.substring(filepath.lastIndexOf("."));
    const contentType = MIME_TYPES[ext] || "application/octet-stream";
    
    const file = await Deno.readFile(BUILD_DIR + filepath);
    return new Response(file, {
      headers: { "content-type": contentType },
    });
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return new Response("404 Not Found", { status: 404 });
    }
    return new Response("500 Internal Error", { status: 500 });
  }
}

console.log("WASM build and hosting server starting on port ${DENO_PORT}...");
await serve(handleRequest, { port: ${DENO_PORT} });
DENO

# Create build script
cat > ${BUILD_DIR}/build-and-run.sh << 'EOF'
#!/bin/bash

BUILD_DIR=/opt/wasm
DENO=/usr/local/bin/deno

build_wasm() {
    local SOURCE=$1
    local OUTPUT=$2
    
    # Detect source type
    case "${SOURCE##*.}" in
        rs)
            build_rust_wasm "$SOURCE" "$OUTPUT"
            ;;
        c|cpp)
            build_emscripten_wasm "$SOURCE" "$OUTPUT"
            ;;
        *)
            echo "Unsupported source file type: ${SOURCE##*.}"
            exit 1
            ;;
    esac
}

build_rust_wasm() {
    local SOURCE=$1
    local OUTPUT=$2
    
    echo "Building Rust WASM module: $SOURCE to $OUTPUT..."
    
    # Create temporary Rust project
    local PROJECT_NAME=$(basename "$OUTPUT")
    local TEMP_DIR="${BUILD_DIR}/rust_build_${PROJECT_NAME}"
    
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR"
    
    # Initialize Rust project
    cargo init --lib
    cp "$SOURCE" src/lib.rs
    
    # Add required dependencies
    cat > Cargo.toml << CARGO
[package]
name = "${PROJECT_NAME}"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
wasm-bindgen = "0.2"
js-sys = "0.3"
web-sys = { version = "0.3", features = ["console"] }

[profile.release]
opt-level = 3
lto = true
codegen-units = 1
CARGO

    # Copy wasm-config.toml
    cp ${BUILD_DIR}/wasm-config.toml .cargo/config.toml
    
    # Build WASM module
    RUSTFLAGS='-C target-feature=+atomics,+bulk-memory,+mutable-globals' \
    cargo build --target wasm32-unknown-unknown --release
    
    # Process with wasm-bindgen
    wasm-bindgen \
        --target deno \
        --out-dir "${BUILD_DIR}" \
        --out-name "$OUTPUT" \
        target/wasm32-unknown-unknown/release/${PROJECT_NAME}.wasm
        
    # Clean up
    cd "${BUILD_DIR}"
    rm -rf "$TEMP_DIR"
    
    echo "Rust build complete!"
}

build_emscripten_wasm() {
    local SOURCE=$1
    local OUTPUT=$2
    
    echo "Building $SOURCE to $OUTPUT..."
    
    # Source Emscripten environment
    source ~/emsdk/emsdk_env.sh
    
    # Compile to WASM
    emcc "$SOURCE" \
        -s WASM=1 \
        -s ENVIRONMENT=web,worker,deno \
        -s EXPORT_ES6=1 \
        -s USE_ES6_IMPORT_META=0 \
        -s MODULARIZE=1 \
        --emit-unicode=1 \
        -o "$OUTPUT"
        
    # Create Deno wrapper
    cat > "${OUTPUT%.js}.ts" << TSFILE
import { instantiate } from "./${OUTPUT##*/}";

export async function initialize() {
    const { instance } = await instantiate();
    return instance.exports;
}
TSFILE

    echo "Build complete!"
}

case "$1" in
    build)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 build <source_file> <output_name>"
            exit 1
        fi
        build_wasm "$2" "$3"
        ;;
    serve)
        echo "Starting Deno server..."
        $DENO run --allow-net --allow-read ${BUILD_DIR}/server.ts
        ;;
    *)
        echo "Usage: $0 {build|serve}"
        echo "  build <src> <out> - Build WASM module"
        echo "  serve             - Start Deno server"
        exit 1
        ;;
esac
EOF

chmod +x ${BUILD_DIR}/build-and-run.sh

# Create test file
cat > ${BUILD_DIR}/test.c << 'EOF'
#include <emscripten.h>
#include <stdio.h>

EMSCRIPTEN_KEEPALIVE
int add(int a, int b) {
    return a + b;
}

EMSCRIPTEN_KEEPALIVE
int factorial(int n) {
    if (n <= 1) return 1;
    return n * factorial(n - 1);
}
EOF

# Create Rust test file
cat > ${BUILD_DIR}/test.rs << 'EOF'
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[wasm_bindgen]
pub fn factorial(n: i32) -> i32 {
    if n <= 1 {
        1
    } else {
        n * factorial(n - 1)
    }
}

#[wasm_bindgen]
pub struct Complex {
    real: f64,
    imag: f64,
}

#[wasm_bindgen]
impl Complex {
    #[wasm_bindgen(constructor)]
    pub fn new(real: f64, imag: f64) -> Complex {
        Complex { real, imag }
    }

    #[wasm_bindgen]
    pub fn add(&self, other: &Complex) -> Complex {
        Complex {
            real: self.real + other.real,
            imag: self.imag + other.imag,
        }
    }
}
EOF

echo "Environment setup complete!"
EOF

chmod +x setup-environment.sh
