#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-0.1.0}"
bash scripts/build-app.sh
archive="$PWD/dist/SnapShelf-v${version}-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$PWD/dist/截图暂存.app" "$archive"
(cd "$PWD/dist" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf '\nRelease 文件：\n%s\n%s\n' "$archive" "$archive.sha256"
