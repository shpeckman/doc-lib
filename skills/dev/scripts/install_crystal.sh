#!/bin/sh
# Idempotent Crystal installer for this sandbox.
# - No root required; installs into $HOME (NOT /mnt/agents: that mount is noexec).
# - $HOME is wiped when the sandbox is released, so re-run this every session.
# - Direct GitHub downloads are ~KB/s here; probes speed and falls back to a proxy.
set -eu

CRYSTAL_HOME="${CRYSTAL_HOME:-$HOME/crystal}"
VERSION="${CRYSTAL_VERSION:-1.21.0}"
TARBALL="crystal-${VERSION}-1-linux-x86_64-bundled.tar.gz"
GH_URL="https://github.com/crystal-lang/crystal/releases/download/${VERSION}/${TARBALL}"

# Already installed?
if [ -x "$CRYSTAL_HOME/bin/crystal" ]; then
  echo "Crystal already installed at $CRYSTAL_HOME"
  "$CRYSTAL_HOME/bin/crystal" --version | head -1
  echo "export PATH=\"$CRYSTAL_HOME/bin:\$PATH\""
  exit 0
fi

# Probe direct GitHub speed (10s cap); use proxy if it looks slower than ~1 MB/s.
URL="$GH_URL"
SPEED=$(curl -sL -o /dev/null --max-time 10 -w '%{speed_download}' "$GH_URL" || echo 0)
if [ "${SPEED%.*}" -lt 1000000 ] 2>/dev/null; then
  echo "Direct GitHub too slow (${SPEED%.*} B/s) — using gh-proxy.com mirror"
  URL="https://gh-proxy.com/$GH_URL"
fi

TMP="$(mktemp -d)"
echo "Downloading $URL"
curl -sL --fail --max-time 300 -o "$TMP/$TARBALL" "$URL"

mkdir -p "$CRYSTAL_HOME"
tar xzf "$TMP/$TARBALL" -C "$TMP"
# Tarball top-level dir is crystal-<version>-1; move contents up into CRYSTAL_HOME.
SRC="$(find "$TMP" -maxdepth 1 -type d -name 'crystal-*' | head -1)"
cp -r "$SRC"/. "$CRYSTAL_HOME"/
rm -rf "$TMP"

export PATH="$CRYSTAL_HOME/bin:$PATH"
crystal --version | head -1

# Verify a real compile+run (catches missing linker/libs immediately).
echo 'puts "crystal ok #{Crystal::VERSION}"' > "$HOME/.crystal_smoke.cr"
crystal run "$HOME/.crystal_smoke.cr"
rm -f "$HOME/.crystal_smoke.cr"

echo
echo "Add to PATH for this session:"
echo "export PATH=\"$CRYSTAL_HOME/bin:\$PATH\""
