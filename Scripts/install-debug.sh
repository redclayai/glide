#!/usr/bin/env bash
#
# Install a locally built Glide.app over /Applications/Glide.app, in place.
#
# "In place" is the whole point. `rm -rf` followed by `cp -R` gives the bundle a new directory
# identity, and the system's privacy database treats that as a different app: Accessibility and
# Input Monitoring come back revoked, and Glide cannot read a selection or see an accept key until
# the user re-grants both by hand (ADR-152). `rsync --delete` writes into the existing directory,
# so the grants survive.
set -euo pipefail

DERIVED="$(xcodebuild -scheme KeyType -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR /{print $2; exit}')"
SOURCE="${1:-$DERIVED/Glide.app}"
DEST="${2:-/Applications/Glide.app}"

[[ -d "$SOURCE" ]] || { echo "error: no app at $SOURCE" >&2; exit 1; }

osascript -e 'tell application "Glide" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x Glide >/dev/null || break; sleep 1; done
pgrep -x Glide >/dev/null && pkill -x Glide || true
sleep 1

rsync -a --delete "$SOURCE/" "$DEST/"
touch "$DEST"
open -a "$DEST"
echo "Installed $DEST"
