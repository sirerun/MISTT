#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
command -v protoc >/dev/null 2>&1 || { echo 'protoc is required' >&2; exit 1; }
command -v protoc-gen-go >/dev/null 2>&1 || { echo 'protoc-gen-go is required' >&2; exit 1; }
command -v protoc-gen-go-grpc >/dev/null 2>&1 || { echo 'protoc-gen-go-grpc is required' >&2; exit 1; }
protoc -I . --go_out=. --go_opt=module=github.com/sirerun/MISTT \
  --go-grpc_out=. --go-grpc_opt=module=github.com/sirerun/MISTT proto/mistt/v1/mistt.proto
