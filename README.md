# geneia-release (public distribution)

Public distribution repo for the **geneia CLI** — no source code lives here.
The generator source stays private; this repo carries only what the
installer and the auto-updater need:

| File | Rol |
|---|---|
| `install.sh` | First-install entrypoint (checksum + Ed25519 gates before installing) |
| `manifest.json` | Latest version manifest (browsable copy; the installer fetches the release asset) |
| Binaries (`geneia-<triple>[.exe]` + `.sig`) | Attached as **GitHub Release assets**, never committed to git |

## Install

```bash
# macOS / Linux / Windows-vía-WSL (un solo comando)
curl -fsSL https://github.com/jhonesis/geneia-release/releases/latest/download/install.sh | sh

# Pinear una versión exacta (mismos gates de verificación)
GENEIA_VERSION=1.0.0 curl -fsSL https://github.com/jhonesis/geneia-release/releases/latest/download/install.sh | sh

# Cambiar el destino (default ~/.local/bin)
INSTALL_DIR=/usr/local/bin curl -fsSL https://github.com/jhonesis/geneia-release/releases/latest/download/install.sh | sh
```

- **macOS** (x86_64 + arm64) y **Linux** (x86_64 + aarch64): el comando de arriba basta.
- **Windows**: vía oficial = **WSL2 Ubuntu** (reporta Linux x86_64 y resuelve el triple linux). Windows ARM64 no soportado.

## Trust model

1. The installer verifies **SHA-256** against the manifest (mandatory — aborts on mismatch, the binary is never touched before this passes).
2. When `node` is available it also verifies the detached **Ed25519** signature (aborts on failure); without node it warns that only SHA-256 ran.
3. Every later `geneia update` re-verifies hash + signature against the embedded trusted key before replacing anything.

## Releases

Each `vX.Y.Z` GitHub Release carries, per platform: the binary, its detached
`.sig` sidecar, the signed `manifest.json`, and `install.sh`. The
`.../releases/latest/download/<file>` URLs always resolve to the newest
stable release.

`manifest.json` here is a convenience copy — `install.sh` and
`geneia update` consume the release-asset manifest, and
`https://geneia.4udev.download/api/v1/cli/version` serves the same content.
