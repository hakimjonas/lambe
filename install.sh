#!/bin/sh
#
# Lambë installer. Downloads the latest release binaries for your
# platform, verifies SHA256 checksums against the published
# `checksums.txt`, and installs to `~/.local/bin/`.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hakimjonas/lambe/main/install.sh | sh
#
# Or clone and run:
#   ./install.sh
#
# Environment variables (all optional):
#   LAMBE_VERSION    — pin a specific release (default: latest). Example: v0.9.0
#   LAMBE_PREFIX     — installation prefix (default: $HOME/.local)
#   LAMBE_NO_MAN     — skip man page install when non-empty
#   LAMBE_BASE_URL   — override the release asset base URL. For testing
#                      against a mirror or staged release. Default:
#                      https://github.com/hakimjonas/lambe/releases/download
#
# Installs (under $LAMBE_PREFIX):
#   bin/lam          — the CLI binary
#   bin/lam-mcp      — the MCP server binary
#   share/man/man1/lam.1  — man page, when a `man` command is present
#
# Does NOT modify shell rc files. Prints a PATH reminder if needed.

set -eu

REPO="hakimjonas/lambe"
VERSION="${LAMBE_VERSION:-}"
PREFIX="${LAMBE_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
MAN_DIR="$PREFIX/share/man/man1"

# ---- pretty ---------------------------------------------------------

# Detect whether stdout is a terminal (so we don't emit ANSI to pipes).
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold)
  DIM=$(tput dim)
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  RESET=$(tput sgr0)
else
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  RESET=""
fi

info()  { printf "%s==>%s %s\n" "${BOLD}" "${RESET}" "$*"; }
ok()    { printf "%s✓%s   %s\n" "${GREEN}" "${RESET}" "$*"; }
warn()  { printf "%s!%s   %s\n" "${YELLOW}" "${RESET}" "$*"; }
fail()  { printf "%sx%s   %s\n" "${RED}" "${RESET}" "$*" >&2; exit 1; }

# ---- platform detection --------------------------------------------

detect_platform() {
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)   platform_os="linux" ;;
    Darwin)  platform_os="macos" ;;
    *) fail "Unsupported OS: $os. On Windows, download lam-windows-x64.exe from https://github.com/$REPO/releases." ;;
  esac
  case "$arch" in
    x86_64|amd64)  platform_arch="x64" ;;
    aarch64|arm64) platform_arch="arm64" ;;
    *) fail "Unsupported arch: $arch." ;;
  esac
  printf "%s-%s" "$platform_os" "$platform_arch"
}

# ---- version resolution --------------------------------------------

resolve_version() {
  if [ -n "$VERSION" ]; then
    printf "%s" "$VERSION"
    return
  fi
  # Ask GitHub for the latest tag via the API. No JSON parser
  # required: grep+sed is sufficient.
  tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
    | head -n1)
  if [ -z "$tag" ]; then
    fail "Could not resolve the latest release tag from GitHub API."
  fi
  printf "%s" "$tag"
}

# ---- download + verify ---------------------------------------------

download() {
  url="$1"
  dest="$2"
  if ! curl -fsSL --retry 3 "$url" -o "$dest"; then
    fail "Failed to download $url"
  fi
}

verify_checksum() {
  # $1 = filename in checksums.txt  $2 = local path
  name="$1"
  path="$2"
  expected=$(grep "  $name\$" "$CHECKSUMS" | awk '{print $1}')
  if [ -z "$expected" ]; then
    fail "No checksum found for $name in checksums.txt"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$path" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$path" | awk '{print $1}')
  else
    fail "Neither sha256sum nor shasum is available for checksum verification."
  fi
  if [ "$expected" != "$actual" ]; then
    fail "Checksum mismatch for $name: expected $expected, got $actual"
  fi
}

# ---- main ----------------------------------------------------------

main() {
  info "Detecting platform..."
  PLATFORM=$(detect_platform)
  ok "platform: $PLATFORM"

  if [ -n "${LAMBE_BASE_URL:-}" ]; then
    BASE_URL="$LAMBE_BASE_URL"
    ok "base URL: $BASE_URL (override)"
  else
    info "Resolving version..."
    TAG=$(resolve_version)
    ok "version: $TAG"
    BASE_URL="https://github.com/$REPO/releases/download/$TAG"
  fi
  LAM_ASSET="lam-$PLATFORM"
  MCP_ASSET="lam-mcp-$PLATFORM"

  TMP=$(mktemp -d 2>/dev/null || mktemp -d -t lambe-install)
  # Cleanup even on unexpected exit.
  trap 'rm -rf "$TMP"' EXIT

  info "Downloading checksums..."
  CHECKSUMS="$TMP/checksums.txt"
  download "$BASE_URL/checksums.txt" "$CHECKSUMS"
  ok "checksums.txt"

  info "Downloading $LAM_ASSET..."
  download "$BASE_URL/$LAM_ASSET" "$TMP/lam"
  verify_checksum "$LAM_ASSET" "$TMP/lam"
  ok "$LAM_ASSET (verified)"

  info "Downloading $MCP_ASSET..."
  download "$BASE_URL/$MCP_ASSET" "$TMP/lam-mcp"
  verify_checksum "$MCP_ASSET" "$TMP/lam-mcp"
  ok "$MCP_ASSET (verified)"

  info "Installing to $BIN_DIR..."
  mkdir -p "$BIN_DIR"
  install -m 0755 "$TMP/lam" "$BIN_DIR/lam"
  install -m 0755 "$TMP/lam-mcp" "$BIN_DIR/lam-mcp"
  ok "installed lam and lam-mcp"

  if [ -z "${LAMBE_NO_MAN:-}" ] && command -v man >/dev/null 2>&1; then
    # Release artifacts don't include the man page today, so we skip
    # gracefully when it's not in the tarball. Placeholder for a
    # future release that ships the man page as an asset.
    MAN_URL="$BASE_URL/lam.1"
    if curl -fsSL --head "$MAN_URL" >/dev/null 2>&1; then
      info "Installing man page to $MAN_DIR..."
      mkdir -p "$MAN_DIR"
      download "$MAN_URL" "$MAN_DIR/lam.1"
      ok "installed man page (run: man lam)"
    fi
  fi

  info "Done."
  printf "\n"

  # PATH reminder. Use `case` on :$PATH: to match start/middle/end
  # of a colon-separated list without matching partial paths.
  case ":${PATH:-}:" in
    *":$BIN_DIR:"*)
      ok "$BIN_DIR is on PATH. Try: lam --help"
      ;;
    *)
      warn "$BIN_DIR is not on PATH."
      printf "    Add it by appending this to your shell rc (~/.bashrc, ~/.zshrc, ~/.config/fish/config.fish, etc.):\n"
      printf "      %sexport PATH=\"\$PATH:%s\"%s\n" "${DIM}" "$BIN_DIR" "${RESET}"
      ;;
  esac
}

main "$@"
