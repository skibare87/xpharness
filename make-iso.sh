#!/usr/bin/env bash
# Build xpharness.iso (burn to DVD). Stages the tree minus secrets/cruft, adds
# an autorun.inf that sets the Clippy drive icon and a double-click launch
# action, then makes a Joliet+RockRidge ISO. Needs: rsync, xorriso.
#
#   ./make-iso.sh            # -> xpharness.iso
#
# Run setup.sh first so the binaries/models exist. config.ps1 is NOT included;
# on the XP box put it at %USERPROFILE%\xpharness\config.ps1 (the harness looks
# there when it's running from read-only media).
set -e
cd "$(dirname "$0")"
command -v xorriso >/dev/null || { echo "need xorriso (apt install xorriso)"; exit 1; }
command -v rsync   >/dev/null || { echo "need rsync"; exit 1; }

STAGE="$(mktemp -d)"
rsync -a --exclude='.git' --exclude='config.ps1' --exclude='*.bak' \
  --exclude='xph_session.json' --exclude='xph_transcript.txt' --exclude='*.iso' \
  --exclude='llm/__pycache__' --exclude='llm/export.log' \
  ./ "$STAGE/"
cp images/clippy-xp.ico "$STAGE/clippy-xp.ico"   # root copy for autorun icon

xorriso -as mkisofs -J -joliet-long -R -V CLIPPY_XP -o xpharness.iso "$STAGE"
rm -rf "$STAGE"
echo "wrote xpharness.iso ($(du -h xpharness.iso | cut -f1))"
