#!/usr/bin/env bash
# install.sh — installs `raindrop` into ~/.raindrop/bin/raindrop.
#
# Pulled by users via:
#   curl -fsSL https://raw.githubusercontent.com/invisible-tools/workshop-releases/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/invisible-tools/workshop-releases/main/install.sh | bash -s -- --channel=beta
# (Once we own a brand-aligned domain, the URL above will move.)
#
# Naming: the binary is `raindrop` because it's the umbrella CLI for raindrop
# tooling. The local-debugger product underneath is `workshop`, accessed via
# `raindrop workshop <verb>`. Today workshop is the only product, but the
# install path is forward-compatible with multi-product raindrop tooling.
#
# Design notes (mirrors docs/specs/2026-04-29-packaging-design.md):
#   - Reads the manifest from $RAINDROP_MANIFEST_URL
#     (default: raw.githubusercontent.com/invisible-tools/workshop-releases/main/latest.json)
#   - Picks the entry for $RAINDROP_CHANNEL (default stable)
#   - Downloads the platform-appropriate binary to a temp file
#   - Verifies sha256 against the manifest
#   - Atomically renames into ~/.raindrop/bin/raindrop
#   - Critically: uses curl, NOT a browser/AirDrop/email — so the binary
#     does NOT carry the com.apple.quarantine xattr, so Gatekeeper does not
#     enforce notarization. Ad-hoc signing alone is sufficient.

set -euo pipefail

# Track whether the channel was set explicitly (env var or --channel flag).
# If the user took the default and it turns out the manifest has no entry
# for that channel (e.g. early-stage repo with only betas published), we
# fall back to beta with a clear message instead of failing dead. Explicit
# requests still fail loud — if a customer asked for stable and we don't
# have one, that's a real signal, not something to paper over.
if [ -n "${RAINDROP_CHANNEL+x}" ]; then
  RAINDROP_CHANNEL_EXPLICIT=1
else
  RAINDROP_CHANNEL_EXPLICIT=0
fi
RAINDROP_CHANNEL="${RAINDROP_CHANNEL:-stable}"
# Manifest URL: served from main of the releases repo via raw.githubusercontent.
# release.yml commits a fresh latest.json there on every release, so this URL
# always works regardless of channel/prerelease semantics.
RAINDROP_MANIFEST_URL="${RAINDROP_MANIFEST_URL:-https://raw.githubusercontent.com/invisible-tools/workshop-releases/main/latest.json}"
RAINDROP_INSTALL_DIR="${RAINDROP_INSTALL_DIR:-$HOME/.raindrop/bin}"

while [ $# -gt 0 ]; do
  case "$1" in
    --channel=*) RAINDROP_CHANNEL="${1#*=}"; RAINDROP_CHANNEL_EXPLICIT=1 ;;
    --channel) shift; RAINDROP_CHANNEL="$1"; RAINDROP_CHANNEL_EXPLICIT=1 ;;
    --manifest=*) RAINDROP_MANIFEST_URL="${1#*=}" ;;
    --install-dir=*) RAINDROP_INSTALL_DIR="${1#*=}" ;;
    -h|--help)
      cat <<'USAGE'
Usage: install.sh [--channel=stable|beta] [--manifest=URL] [--install-dir=DIR]

Environment overrides:
  RAINDROP_CHANNEL         stable | beta            (default: stable)
  RAINDROP_MANIFEST_URL    URL of latest.json
                           (default: https://raw.githubusercontent.com/invisible-tools/workshop-releases/main/latest.json)
  RAINDROP_INSTALL_DIR     install dir              (default: ~/.raindrop/bin)
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

if [ "$RAINDROP_CHANNEL" != "stable" ] && [ "$RAINDROP_CHANNEL" != "beta" ]; then
  echo "Invalid channel: $RAINDROP_CHANNEL (expected stable|beta)" >&2
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
echo "[install] platform=$PLATFORM channel=$RAINDROP_CHANNEL"

# ── Tooling: prefer curl, fall back to wget ──────────────────
need() { command -v "$1" >/dev/null 2>&1; }

fetch() {
  # fetch <url> <out-path>
  # Production: hard-pin to https + tls1.2+. Set RAINDROP_INSECURE_PROTO=1 only
  # in tests against a local HTTP server.
  if need curl; then
    if [ "${RAINDROP_INSECURE_PROTO:-0}" = "1" ]; then
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
TMP_DIR="$(mktemp -d -t raindrop-install-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

MANIFEST="$TMP_DIR/manifest.json"
echo "[install] fetching manifest: $RAINDROP_MANIFEST_URL"
fetch "$RAINDROP_MANIFEST_URL" "$MANIFEST"

# Tiny JSON parser via python3 (preinstalled on macOS+most Linux).
# We parse two strings (url, sha256) and one int (size). No jq dep.
parse_field() {
  python3 -c "
import json, sys
m = json.load(open('$MANIFEST'))
ch = m.get('$RAINDROP_CHANNEL') or {}
plats = ch.get('platforms') or {}
entry = plats.get('$PLATFORM') or {}
print(entry.get('$1') or '')
"
}

read_version() {
  python3 -c "import json; print(json.load(open('$MANIFEST')).get('$RAINDROP_CHANNEL', {}).get('version', ''))"
}

VERSION="$(read_version)"
URL="$(parse_field url)"
EXPECTED_SHA="$(parse_field sha256)"
EXPECTED_SIZE="$(parse_field size)"

# Implicit-default fallback: if the user didn't ask for a specific channel
# and the default (stable) has no entry for this platform, try beta before
# bailing. Keeps `curl … | bash` working in early-stage projects that ship
# only betas. See the RAINDROP_CHANNEL_EXPLICIT comment block above.
if [ -z "$URL" ] || [ -z "$EXPECTED_SHA" ] || [ -z "$EXPECTED_SIZE" ]; then
  if [ "$RAINDROP_CHANNEL_EXPLICIT" = "0" ] && [ "$RAINDROP_CHANNEL" = "stable" ]; then
    echo "[install] no stable release published yet — falling back to beta channel"
    RAINDROP_CHANNEL=beta
    VERSION="$(read_version)"
    URL="$(parse_field url)"
    EXPECTED_SHA="$(parse_field sha256)"
    EXPECTED_SIZE="$(parse_field size)"
  fi
fi

if [ -z "$URL" ] || [ -z "$EXPECTED_SHA" ] || [ -z "$EXPECTED_SIZE" ]; then
  echo "[install] manifest missing entry for channel=$RAINDROP_CHANNEL platform=$PLATFORM" >&2
  exit 1
fi

echo "[install] version=$VERSION"
echo "[install] url=$URL"
echo "[install] expected sha256=$EXPECTED_SHA"

# ── Download + verify ────────────────────────────────────────
DOWNLOAD="$TMP_DIR/raindrop"
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
mkdir -p "$RAINDROP_INSTALL_DIR"
chmod +x "$DOWNLOAD"

DEST="$RAINDROP_INSTALL_DIR/raindrop"
if [ "$PLATFORM" = "windows-x64" ]; then
  DEST="${DEST}.exe"
fi

# Atomic rename. If a previous binary exists, keep it as raindrop.prev for rollback.
if [ -e "$DEST" ]; then
  mv -f "$DEST" "${DEST}.prev" || true
fi
mv -f "$DOWNLOAD" "$DEST"
chmod +x "$DEST"

echo "[install] installed: $DEST"

# ── Next steps ───────────────────────────────────────────────
# Pick the bare command if it's already on PATH, else the full path,
# so copy-paste works either way.
case ":$PATH:" in
  *":$RAINDROP_INSTALL_DIR:"*) CMD="raindrop" ;;
  *) CMD="$DEST" ;;
esac

echo ""
echo "  Raindrop $VERSION is installed."
echo ""
echo "  In a project that uses @raindrop-ai/* SDKs, bootstrap it:"
echo "      $CMD workshop init"
echo ""
echo "  This writes RAINDROP_LOCAL_DEBUGGER into ./.env, starts the daemon,"
echo "  and opens the UI at http://localhost:5899."
echo ""
echo "  Already-bootstrapped projects:"
echo "      $CMD workshop          # start daemon + open UI"
echo "      $CMD workshop status   # check whether it's running"
echo "      $CMD workshop stop     # stop the daemon"
echo ""

# Path hint goes last so it doesn't bury the actual call-to-action.
case ":$PATH:" in
  *":$RAINDROP_INSTALL_DIR:"*) ;;
  *)
    SHELL_NAME="$(basename "${SHELL:-bash}")"
    HINT="export PATH=\"$RAINDROP_INSTALL_DIR:\$PATH\""
    echo "  To use 'raindrop' as a bare command, add this to your ~/.${SHELL_NAME}rc:"
    echo "      $HINT"
    echo ""
    ;;
esac
