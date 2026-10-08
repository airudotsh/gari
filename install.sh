#!/bin/bash
# Gari installer — safe to re-run.
set -e
GARI="${GARI_HOME:-$(cd "$(dirname "$0")" && pwd)}"
export GARI_HOME="$GARI"
echo "── Installing Gari (GARI_HOME=$GARI) ──"

# 0. Prerequisites
command -v python3 >/dev/null || { echo "✗ python3 is required."; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "✗ Command Line Tools are required: run 'xcode-select --install' and retry."; exit 1; }
if [ -z "$ANTHROPIC_API_KEY" ] && ! grep -q '^ANTHROPIC_API_KEY=.' "$GARI/secrets.env" 2>/dev/null; then
  echo "! No Claude API key yet. Create one at https://console.anthropic.com/ and add it to:"
  echo "    $GARI/secrets.env   →   ANTHROPIC_API_KEY=sk-ant-..."
fi
command -v claude >/dev/null || echo "! Claude Code CLI not found — 'gari do' and document search need it (https://claude.com/claude-code)."

# 1. Config + secrets (never overwritten)
[ -f "$GARI/config.json" ] || cp "$GARI/config.example.json" "$GARI/config.json"
if [ ! -f "$GARI/secrets.env" ]; then
  printf '# Gari secrets — never commit this file\nANTHROPIC_API_KEY=\n' > "$GARI/secrets.env"
fi
chmod 600 "$GARI/secrets.env"
mkdir -p "$GARI/store" "$GARI/queue" "$GARI/reports"

# 2. Command on PATH
mkdir -p "$HOME/.local/bin"
ln -sf "$GARI/bin/gari" "$HOME/.local/bin/gari"

# 3. Desktop pet
cd "$GARI/pet"
clang -fobjc-arc -framework Cocoa -O2 -o gari-pet GariPet.m
DEST="/Applications/Gari.app"; [ -w /Applications ] || DEST="$HOME/Applications/Gari.app"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
[ -f "$DEST/Contents/Info.plist" ] || cp "$GARI/pet/app/Info.plist" "$DEST/Contents/Info.plist" 2>/dev/null || true
cp gari-pet "$DEST/Contents/MacOS/gari"
[ -f "$GARI/pet/app/gari.icns" ] && cp "$GARI/pet/app/gari.icns" "$DEST/Contents/Resources/"
codesign --force --deep -s - "$DEST" 2>/dev/null || true

# 4. Onboarding (questions → hooks + schedules → diagnostics)
"$GARI/bin/gari" init
echo "── Done. Wake the pet from Spotlight ('Gari') or run: gari pet ──"
