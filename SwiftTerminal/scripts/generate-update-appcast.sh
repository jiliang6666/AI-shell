#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

UPDATE_REPOSITORY="${ZHANQIAO_UPDATE_REPOSITORY:-jiliang6666/AI-shell}"
APP_VERSION="${ZHANQIAO_APP_VERSION:-1.0.6}"
UPDATE_REVISION="${ZHANQIAO_UPDATE_REVISION:-106}"
ARCHIVE_DIR="${1:-$ROOT/build/update-assets}"

UPDATE_OWNER=${UPDATE_REPOSITORY%%/*}
UPDATE_NAME=${UPDATE_REPOSITORY#*/}
case "$UPDATE_OWNER" in ''|*[!A-Za-z0-9_-]*) echo "Invalid GitHub update owner." >&2; exit 2 ;; esac
case "$UPDATE_NAME" in ''|*[!A-Za-z0-9._-]*|*/*|.|..) echo "Invalid GitHub update repository." >&2; exit 2 ;; esac
case "$APP_VERSION" in ''|*[!0-9.]*) echo "Invalid ZHANQIAO_APP_VERSION." >&2; exit 2 ;; esac
case "$UPDATE_REVISION" in ''|*[!0-9]*) echo "Invalid ZHANQIAO_UPDATE_REVISION." >&2; exit 2 ;; esac
if [ ! -d "$ARCHIVE_DIR" ]; then
    echo "Update archive directory not found: $ARCHIVE_DIR" >&2
    exit 2
fi

SPARKLE_TOOL="$(find "$ROOT/.build/artifacts/sparkle" -type f -name generate_appcast -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_TOOL" ]; then
    echo "Build SwiftTerminal first so Sparkle's generate_appcast tool is available." >&2
    exit 1
fi

DOWNLOAD_URL_PREFIX="https://github.com/$UPDATE_REPOSITORY/releases/download/v$APP_VERSION/"
"$SPARKLE_TOOL" \
    --account com.zhanqiao.sparkle \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --versions "$UPDATE_REVISION" \
    --maximum-deltas 5 \
    "$ARCHIVE_DIR"
