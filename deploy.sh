#!/bin/sh
# Copy the addon into the WoW Forever AddOns folder (replaces only our own Duel folder).
set -e
DEST="${WOW_ADDONS:-/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns}"
cd "$(dirname "$0")"
rm -rf "$DEST/Duel"
cp -r Duel "$DEST/Duel"
echo "Deployed to $DEST/Duel"
