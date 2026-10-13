#!/bin/sh
# T016 (REQ-web-006): single install entrypoint for the geneia CLI.
#
#   curl -fsSL https://github.com/jhonesis/geneia-release/releases/latest/download/install.sh | sh
#
# Windows: official path is WSL (WSL2 Ubuntu reports Linux x86_64 glibc and
# resolves the linux triple). Native Windows ARM64 is unsupported (clear abort
# below); no install.ps1 by design.
#
# What it does:
#   1. Detects the platform (uname) and maps it to a Rust target triple
#      (the stable-channel asset keys in release/manifest.json).
#   2. Fetches the version manifest (latest, or v$GENEIA_VERSION when pinned)
#      and resolves the artifact URL + integrity data for this platform.
#   3. Downloads the artifact and its detached `.sig` sidecar to a temp dir.
#   4. Verifies SHA-256 against the manifest (mandatory — aborts on mismatch,
#      the installed binary is never touched before this passes).
#   5. Verifies the detached Ed25519 signature when node is available
#      (aborts on failure); without node it warns that only the SHA-256
#      check ran — ongoing `geneia update` runs always enforce Ed25519.
#   6. Installs to $INSTALL_DIR (default ~/.local/bin) and marks executable.
#
# Trust model: first install trusts TLS (GitHub) + manifest SHA-256 (+ Ed25519
# when node is present). Every later update is Ed25519-enforced by the CLI
# against TRUSTED_PUBLIC_KEY_B64 below (must equal the CLI's
# TRUSTED_PUBLIC_KEY_BASE64 in geneia-cli/src/auth/update.rs).
#
# Env knobs: GENEIA_VERSION (pin, default latest), INSTALL_DIR,
# GENEIA_RELEASES_BASE_URL (mirror/dev override).
set -eu

# Trust anchor: first install trusts TLS (GitHub) + manifest SHA-256 (+ Ed25519
# when node is present). Test-only override (T113 local proof installs an
# ephemeral-key test release): the default stays the production pinned key.
TRUSTED_PUBLIC_KEY_B64="${GENEIA_TRUSTED_PUBKEY_OVERRIDE:-VV78myaX8dvpZuqO1t9juYYne2oNrb9IUbrh1XgTzO0=}"
BASE_URL="${GENEIA_RELEASES_BASE_URL:-https://github.com/jhonesis/geneia-release/releases}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
PINNED_VERSION="${GENEIA_VERSION:-}"

log() { printf '%s\n' "install: $*"; }
abort() { printf '%s\n' "install: error: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || abort "curl is required"
command -v python3 >/dev/null 2>&1 || command -v node >/dev/null 2>&1 \
  || abort "python3 or node is required (manifest parsing)"

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin)
    case "$ARCH" in
      x86_64) TRIPLE="x86_64-apple-darwin" ;;
      arm64) TRIPLE="aarch64-apple-darwin" ;;
      *) abort "unsupported macOS arch: $ARCH" ;;
    esac
    ;;
  Linux)
    case "$ARCH" in
      x86_64) TRIPLE="x86_64-unknown-linux-gnu" ;;
      aarch64) TRIPLE="aarch64-unknown-linux-gnu" ;;
      *) abort "unsupported Linux arch: $ARCH" ;;
    esac
    ;;
  MINGW*|MSYS*|CYGWIN*)
    case "$ARCH" in
      x86_64) TRIPLE="x86_64-pc-windows-msvc" ;;
      *) abort "unsupported Windows arch: $ARCH" ;;
    esac
    ;;
  *) abort "unsupported OS: $OS (supported: macOS, Linux, Windows via Git Bash)" ;;
esac

if [ -n "$PINNED_VERSION" ]; then
  MANIFEST_URL="$BASE_URL/download/v$PINNED_VERSION/manifest.json"
else
  MANIFEST_URL="$BASE_URL/latest/download/manifest.json"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

log "fetching manifest $MANIFEST_URL"
curl -fsSL "$MANIFEST_URL" -o "$TMP/manifest.json" \
  || abort "cannot fetch the version manifest from $MANIFEST_URL"

if command -v python3 >/dev/null 2>&1; then
  ASSET_FIELDS="$(TRIPLE="$TRIPLE" python3 - "$TMP/manifest.json" <<'EOF'
import json, os, sys
with open(sys.argv[1]) as f:
    manifest = json.load(f)
asset = (manifest.get("assets") or {}).get(os.environ["TRIPLE"])
if not asset or not asset.get("url") or not asset.get("sha256") or not asset.get("sig"):
    print("missing asset for platform %s in manifest version %s" % (os.environ["TRIPLE"], manifest.get("version")), file=sys.stderr)
    sys.exit(1)
for field in (asset["url"], asset["sha256"], asset["sig"], str(manifest.get("version"))):
    print(field)
EOF
)" || abort "no release artifact for platform $TRIPLE"
else
  ASSET_FIELDS="$(TRIPLE="$TRIPLE" MANIFEST="$TMP/manifest.json" node -e "
const m = require(process.env.MANIFEST);
const a = (m.assets || {})[process.env.TRIPLE];
if (!a || !a.url || !a.sha256 || !a.sig) {
  console.error('missing asset for platform ' + process.env.TRIPLE);
  process.exit(1);
}
for (const field of [a.url, a.sha256, a.sig, String(m.version)]) console.log(field);
")" || abort "no release artifact for platform $TRIPLE"
fi

ARTIFACT_URL="$(printf '%s\n' "$ASSET_FIELDS" | sed -n '1p')"
EXPECTED_SHA="$(printf '%s\n' "$ASSET_FIELDS" | sed -n '2p')"
EXPECTED_SIG="$(printf '%s\n' "$ASSET_FIELDS" | sed -n '3p')"
RELEASE_VERSION="$(printf '%s\n' "$ASSET_FIELDS" | sed -n '4p')"
[ -n "$ARTIFACT_URL" ] && [ -n "$EXPECTED_SHA" ] && [ -n "$EXPECTED_SIG" ] && [ -n "$RELEASE_VERSION" ] \
  || abort "malformed asset entry for platform $TRIPLE in the manifest"

case "$TRIPLE" in
  *windows*) BIN_NAME="geneia.exe" ;;
  *) BIN_NAME="geneia" ;;
esac

log "downloading geneia $RELEASE_VERSION for $TRIPLE"
curl -fsSL "$ARTIFACT_URL" -o "$TMP/$BIN_NAME" || abort "cannot download $ARTIFACT_URL"
curl -fsSL "$ARTIFACT_URL.sig" -o "$TMP/$BIN_NAME.sig" || abort "cannot download $ARTIFACT_URL.sig"

# 1. SHA-256 gate (mandatory): nothing is installed unless the bytes match.
if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA="$(shasum -a 256 "$TMP/$BIN_NAME" | cut -d' ' -f1)"
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA="$(sha256sum "$TMP/$BIN_NAME" | cut -d' ' -f1)"
else
  abort "shasum or sha256sum is required (integrity check)"
fi
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  abort "checksum mismatch for $TRIPLE (manifest $EXPECTED_SHA, downloaded $ACTUAL_SHA) — refusing to install"
fi
log "checksum ok ($ACTUAL_SHA)"

# 2. Detached Ed25519 gate: enforced when node is present, warned otherwise.
if command -v node >/dev/null 2>&1; then
  TMP="$TMP" BIN_NAME="$BIN_NAME" EXPECTED_SIG="$EXPECTED_SIG" TRUSTED_PUBLIC_KEY_B64="$TRUSTED_PUBLIC_KEY_B64" node -e "
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const crypto = require('node:crypto');
const dir = process.env.TMP;
const artifact = readFileSync(join(dir, process.env.BIN_NAME));
const sig = Buffer.from(String(process.env.EXPECTED_SIG).trim(), 'base64');
if (sig.length !== 64) {
  console.error('install: error: malformed detached signature in manifest');
  process.exit(1);
}
const pubRaw = Buffer.from(String(process.env.TRUSTED_PUBLIC_KEY_B64).trim(), 'base64');
const key = crypto.createPublicKey({
  key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), pubRaw]),
  format: 'der',
  type: 'spki',
});
if (!crypto.verify(null, artifact, key, sig)) {
  console.error('install: error: signature verification failed — artifact is not authentic, refusing to install');
  process.exit(1);
}
" || abort "signature verification failed — artifact is not authentic, refusing to install"
  log "signature ok (Ed25519)"
else
  log "warning: node not found — installed after SHA-256 check only; 'geneia update' enforces Ed25519 signatures thereafter"
fi

# 3. Install (only reachable after both gates passed).
mkdir -p "$INSTALL_DIR"
mv "$TMP/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
chmod +x "$INSTALL_DIR/$BIN_NAME"

log "installed geneia $RELEASE_VERSION to $INSTALL_DIR/$BIN_NAME"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) log "hint: add $INSTALL_DIR to PATH (e.g. export PATH=\"\$INSTALL_DIR:\$PATH\")" ;;
esac
"$INSTALL_DIR/$BIN_NAME" --version || log "hint: run '$INSTALL_DIR/$BIN_NAME --version' to confirm"
