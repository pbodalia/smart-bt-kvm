#!/bin/bash
# Builds display-watcher into the repo directory. Needs Xcode Command Line
# Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null; then
    echo "swiftc not found — install Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi

swiftc -O display-watcher.swift -o ./bin/display-watcher
echo "built ./bin/display-watcher"
