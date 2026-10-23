#!/bin/sh
# Runs KoPlay in the KOReader emulator on macOS, at Kindle Paperwhite 3 resolution
# (536x724 points = 1072x1448 pixels on a Retina screen, 300 dpi).
#
# The plugin is symlinked, so code changes show up after restarting the emulator.
# The emulator shares tools/koplay.json, so it uses the same Spotify login.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT/.emulator"
APP="$EMU/KOReader.app"
HOME_DIR="$EMU/home"

if [ ! -d "$APP" ]; then
    echo "KOReader.app not found: $APP"
    echo "Download the macOS build from https://github.com/koreader/koreader/releases and put KOReader.app there."
    exit 1
fi
if [ ! -f "$ROOT/tools/koplay.json" ]; then
    echo "Log in first: python3 tools/koplay_auth.py <CLIENT_ID>"
    exit 1
fi

mkdir -p "$HOME_DIR/plugins" "$HOME_DIR/settings"
ln -sfn "$ROOT/koplay.koplugin" "$HOME_DIR/plugins/koplay.koplugin"
ln -sfn "$ROOT/tools/koplay.json" "$HOME_DIR/settings/koplay.json"

KO_HOME="$HOME_DIR" \
EMULATE_READER_W=536 EMULATE_READER_H=724 EMULATE_READER_DPI=300 \
exec "$APP/Contents/MacOS/koreader"
