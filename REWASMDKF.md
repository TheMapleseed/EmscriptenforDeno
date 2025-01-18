# Kata-Firecracker WASM/Deno Build Environment

A complete environment for building and hosting WebAssembly modules using Kata Containers with Firecracker, supporting both Rust and C/C++ through Emscripten, with Deno hosting capabilities.

## Prerequisites

- Linux host with KVM support
- Kata Containers installed
- Firecracker configured
- kubectl installed
- At least 8GB RAM
- 20GB free disk space

## Quick Start

1. Clone the repository:
```bash
git clone [your-repo]
cd [your-repo]
```

2. Configure environment variables (optional):
```bash
export KATA_NAME="deno-wasm-env"  # Default: deno-wasm-env
export BUILD_DIR="/opt/wasm"      # Default: /opt/wasm
export DENO_PORT="8000"          # Default: 8000
```

3. Start the environment:
```bash
sudo mkdir -p ${BUILD_DIR}
sudo chmod 755 ${BUILD_DIR}
kubectl apply -f deno-wasm-pod.yaml
```

4. Set up the build environment:
```bash
kubectl cp setup-environment.sh ${KATA_NAME}:${BUILD_DIR}/
kubectl exec -it ${KATA_NAME} -- bash -c "cd ${BUILD_DIR} && chmod +x setup-environment.sh && ./setup-environment.sh"
```

## Building WASM Modules

### From Rust
```bash
# Copy your Rust source file
kubectl cp your_module.rs ${KATA_NAME}:${BUILD_DIR}/

# Build the module
kubectl exec -it ${KATA_NAME} -- ${BUILD_DIR}/build-and-run.sh build your_module.rs output_name

# The following files will be generated:
# - output_name.wasm
# - output_name.js
# - output_name.ts
```

### From C/C++
```bash
# Copy your C/C++ source file
kubectl cp your_module.c ${KATA_NAME}:${BUILD_DIR}/

# Build the module
kubectl exec -it ${KATA_NAME} -- ${BUILD_DIR}/build-and-run.sh build your_module.c output_name

# The following files will be generated:
# - output_name.wasm
# - output_name.js
# - output_name.ts
```

## Running the Deno Server

```bash
kubectl exec -it ${KATA_NAME} -- ${BUILD_DIR}/build-and-run.sh serve
```

The server will be available at `http://localhost:8000` with:
- Index page listing all WASM modules
- Automatic MIME type detection
- Direct module downloads

## Using WASM Modules

### In Deno
```typescript
// For Rust modules
import { functionName } from "http://localhost:8000/output_name.js";

// For C/C++ modules
import { initialize } from "http://localhost:8000/output_name.js";
const instance = await initialize();
```

### In Browser
```html
<script type="module">
  import { initialize } from "http://localhost:8000/output_name.js";
  
  async function run() {
    const instance = await initialize();
    console.log(instance.exports.functionName());
  }
  
  run();
</script>
```

## Directory Structure

```
/opt/wasm/
├── server.ts              # Deno server
├── build-and-run.sh      # Build script
├── wasm-config.toml      # Rust WASM configuration
├── test.c                # C test file
├── test.rs               # Rust test file
└── built_modules/        # Output directory
```

## Configuration Files

### Rust WASM Configuration (wasm-config.toml)
```toml
[build]
target = "wasm32-unknown-unknown"

[target.wasm32-unknown-unknown]
rustflags = [
    "-C", "link-arg=-s",
    "-C", "opt-level=3",
    "-C", "target-feature=+bulk-memory,+mutable-globals,+reference-types,+simd128"
]
```

### Emscripten Configuration (~/.emscripten)
```python
COMPILER_OPTS = [
    '-s', 'ENVIRONMENT=web,worker,deno',
    '-s', 'EXPORT_ES6=1',
    '-s', 'USE_ES6_IMPORT_META=0',
    '-s', 'MODULARIZE=1',
    '--emit-unicode=1'
]
```

## Resource Management

The Kata container is configured with:
- Memory: 8GB
- CPU: 4 cores
- Privileged mode for build tools
- Shared volume for build outputs

## Troubleshooting

### Common Issues

1. Build Failures
```bash
# Check build logs
kubectl logs ${KATA_NAME}

# Verify environment
kubectl exec -it ${KATA_NAME} -- bash -c "source ~/.cargo/env && cargo --version"
kubectl exec -it ${KATA_NAME} -- bash -c "source ~/emsdk/emsdk_env.sh && emcc --version"
```

2. Server Issues
```bash
# Check server logs
kubectl exec -it ${KATA_NAME} -- tail -f /var/log/deno.log

# Restart server
kubectl exec -it ${KATA_NAME} -- pkill -f "deno run"
kubectl exec -it ${KATA_NAME} -- ${BUILD_DIR}/build-and-run.sh serve
```

3. Permission Issues
```bash
# Fix build directory permissions
sudo chown -R 1000:1000 ${BUILD_DIR}
```

### Health Check
```bash
# Check Kata container status
kubectl describe pod ${KATA_NAME}

# Verify services
kubectl exec -it ${KATA_NAME} -- bash -c "ps aux | grep deno"
```

## Cleanup

```bash
# Stop the environment
kubectl delete pod ${KATA_NAME}

# Clean build directory
sudo rm -rf ${BUILD_DIR}/*
```

## Security Notes

1. The container runs in privileged mode for build tools
2. Port 8000 is exposed to the host
3. Build directory is mounted from host
4. Consider adding TLS for production use

## Advanced Usage

### Custom Build Configurations

1. Modify Rust WASM settings:
```bash
kubectl exec -it ${KATA_NAME} -- vi ${BUILD_DIR}/wasm-config.toml
```

2. Update Emscripten settings:
```bash
kubectl exec -it ${KATA_NAME} -- vi ~/.emscripten
```

### Adding Dependencies

```bash
# Install additional packages
kubectl exec -it ${KATA_NAME} -- apt-get update
kubectl exec -it ${KATA_NAME} -- apt-get install -y your-package

# Add Rust crates
kubectl exec -it ${KATA_NAME} -- bash -c "cd /app && cargo add your-crate"
```

## Support

For issues and questions:
1. Check the troubleshooting guide
2. Review container logs
3. Submit an issue on GitHub
