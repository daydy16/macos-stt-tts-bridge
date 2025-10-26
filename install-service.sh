#!/bin/bash

# STTBridge Service Installer
# Installiert STTBridge als automatisch startenden Dienst

set -e

PLIST_NAME="io.github.daydy16.sttbridge.plist"
PLIST_SOURCE="$(dirname "$0")/$PLIST_NAME"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "🔧 STTBridge Service Installer"
echo "================================"

# Check if app exists
if [ ! -d "/Applications/STTBridge.app" ]; then
    echo "❌ STTBridge.app nicht gefunden in /Applications"
    echo "   Bitte erst die App nach /Applications kopieren!"
    exit 1
fi

# Create LaunchAgents directory if it doesn't exist
mkdir -p "$HOME/Library/LaunchAgents"

# Copy plist
echo "📋 Kopiere Launch Agent..."
cp "$PLIST_SOURCE" "$PLIST_DEST"

# Unload if already loaded
if launchctl list | grep -q "io.github.daydy16.sttbridge"; then
    echo "⏸  Stoppe existierenden Service..."
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

# Load the new one
echo "▶️  Starte Service..."
launchctl load "$PLIST_DEST"

echo ""
echo "✅ STTBridge Service installiert!"
echo ""
echo "📝 Befehle:"
echo "   Service stoppen:   launchctl unload $PLIST_DEST"
echo "   Service starten:   launchctl load $PLIST_DEST"
echo "   Service status:    launchctl list | grep sttbridge"
echo "   Logs anzeigen:     tail -f /tmp/sttbridge.log"
echo ""
echo "🌐 Server läuft auf: http://127.0.0.1:8787"
