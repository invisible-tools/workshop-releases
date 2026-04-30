#!/usr/bin/env bash
# install.sh — installs Workshop into ~/.workshop/bin/workshop.
#
# Pulled by users via:
#   curl -fsSL https://workshop.dev/install.sh | bash
#   curl -fsSL https://workshop.dev/install.sh | bash -s -- --channel=beta
#
# Design notes (matches docs/specs/2026-04-29-packaging-design.md):
#   - Reads the manifest from $WORKSHOP_MANIFEST_URL (default workshop.dev/latest.json)
#   - Picks the entry for $WORKSHOP_CHANNEL (default stable)
#   - Downloads the platform-appropriate binary to a temp file
#   - Verifies sha256 against the manifest
#   - Atomically renames into ~/.workshop/bin/workshop
#   - Critically: uses curl, NOT a browser/AirDrop/email — so the binary
#     does NOT carry the com.apple.quarantine xattr, so Gatekeeper does not
#     enforce notarization. Ad-hoc signing alone is sufficient.

set -euo pipefail

WORKSHOP_CHANNEL="${WORKSHOP_CHANNEL:-stable}"
WORKSHOP_MANIFEST_URL="${WORKSHOP_MANIFEST_URL:-https://workshop.dev/latest.json}"
WORKSHOP_INSTALL_DIR="${WORKSHOP_INSTALL_DIR:-$HOME/.workshop/bin}"

while [ $# -gt 0 ]; do
  case "$1" in
    --channel=*) WORKSHOP_CHANNEL="${1#*=}" ;;
    --channel) shift; WORKSHOP_CHANNEL="$1" ;;
    --manifest=*) WORKSHOP_MANIFEST_URL="${1#*=}" ;;
    --install-dir=*) WORKSHOP_INSTALL_DIR="${1#*=}" ;;
    -h|--help)
      cat <<'USAGE'
Usage: install.sh [--channel=stable|beta] [--manifest=URL] [--install-dir=DIR]

Environment overrides:
  WORKSHOP_CHANNEL         stable | beta            (default: stable)
  WORKSHOP_MANIFEST_URL    URL of latest.json       (default: https://workshop.dev/latest.json)
  WORKSHOP_INSTALL_DIR     install dir              (default: ~/.workshop/bin)
USAGE
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$WORKSHOP_CHANNEL" != "stable" ] && [ "$WORKSHOP_CHANNEL" != "beta" ]; then
  echo "Invalid channel: $WORKSHOP_CHANNEL (expected stable|beta)" >&2
  exit 2
fi

# ── Detect platform ──────────────────────────────────────────
detect_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    MINGW*|MSYS*|CYGWIN*) os="windows" ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64) arch="x64" ;;
    *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
  echo "${os}-${arch}"
}

PLATFORM="$(detect_platform)"
echo "[install] platform=$PLATFORM channel=$WORKSHOP_CHANNEL"

# ── Tooling: prefer curl, fall back to wget ──────────────────
need() { command -v "$1" >/dev/null 2>&1; }

fetch() {
  # fetch <url> <out-path>
  # Production: hard-pin to https + tls1.2+. Set WORKSHOP_INSECURE_PROTO=1 only
  # in tests against a local HTTP server.
  if need curl; then
    if [ "${WORKSHOP_INSECURE_PROTO:-0}" = "1" ]; then
      curl -fsSL -o "$2" "$1"
    else
      curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
    fi
  elif need wget; then
    wget -qO "$2" "$1"
  else
    echo "Need curl or wget" >&2
    exit 1
  fi
}

if ! need shasum && ! need sha256sum; then
  echo "Need shasum or sha256sum to verify download" >&2
  exit 1
fi

sha256_of() {
  if need sha256sum; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ── Read manifest ────────────────────────────────────────────
TMP_DIR="$(mktemp -d -t workshop-install-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

MANIFEST="$TMP_DIR/manifest.json"
echo "[install] fetching manifest: $WORKSHOP_MANIFEST_URL"
fetch "$WORKSHOP_MANIFEST_URL" "$MANIFEST"

# Tiny JSON parser via python3 (preinstalled on macOS+most Linux).
# We parse two strings (url, sha256) and one int (size). No jq dep.
parse_field() {
  python3 -c "
import json, sys
m = json.load(open('$MANIFEST'))
ch = m.get('$WORKSHOP_CHANNEL') or {}
plats = ch.get('platforms') or {}
entry = plats.get('$PLATFORM') or {}
print(entry.get('$1') or '')
"
}

VERSION="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('$WORKSHOP_CHANNEL', {}).get('version', ''))")"
URL="$(parse_field url)"
EXPECTED_SHA="$(parse_field sha256)"
EXPECTED_SIZE="$(parse_field size)"

if [ -z "$URL" ] || [ -z "$EXPECTED_SHA" ] || [ -z "$EXPECTED_SIZE" ]; then
  echo "[install] manifest missing entry for channel=$WORKSHOP_CHANNEL platform=$PLATFORM" >&2
  exit 1
fi

echo "[install] version=$VERSION"
echo "[install] url=$URL"
echo "[install] expected sha256=$EXPECTED_SHA"

# ── Download + verify ────────────────────────────────────────
DOWNLOAD="$TMP_DIR/workshop"
echo "[install] downloading..."
fetch "$URL" "$DOWNLOAD"

ACTUAL_SHA="$(sha256_of "$DOWNLOAD")"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "[install] sha256 mismatch: expected $EXPECTED_SHA got $ACTUAL_SHA" >&2
  exit 1
fi
echo "[install] sha256 verified"

ACTUAL_SIZE=$(wc -c < "$DOWNLOAD" | tr -d ' ')
if [ "$ACTUAL_SIZE" != "$EXPECTED_SIZE" ]; then
  echo "[install] size mismatch: expected $EXPECTED_SIZE got $ACTUAL_SIZE" >&2
  exit 1
fi

# ── Install atomically ───────────────────────────────────────
mkdir -p "$WORKSHOP_INSTALL_DIR"
chmod +x "$DOWNLOAD"

DEST="$WORKSHOP_INSTALL_DIR/workshop"
if [ "$PLATFORM" = "windows-x64" ]; then
  DEST="${DEST}.exe"
fi

# Atomic rename. If a previous binary exists, keep it as workshop.prev for rollback.
if [ -e "$DEST" ]; then
  mv -f "$DEST" "${DEST}.prev" || true
fi
mv -f "$DOWNLOAD" "$DEST"
chmod +x "$DEST"

echo "[install] installed: $DEST"

# ── Path hint ────────────────────────────────────────────────
case ":$PATH:" in
  *":$WORKSHOP_INSTALL_DIR:"*) ;;
  *)
    SHELL_NAME="$(basename "${SHELL:-bash}")"
    HINT="export PATH=\"$WORKSHOP_INSTALL_DIR:\$PATH\""
    echo ""
    echo "Add this to your ~/.${SHELL_NAME}rc to use 'workshop' from anywhere:"
    echo "  $HINT"
    ;;
esac

echo ""
echo "Try it:  $DEST status"
