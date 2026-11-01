#!/bin/bash
# Build (only what changed) and launch Storage Manager.
#   ./start.sh            build and open the app
#   ./start.sh --check    also run the safety checks first
#   ./start.sh --install  copy the app to ~/Applications so it can be opened from Launchpad/Spotlight
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0; ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--install" ]; then INSTALL=1; else ARGS+=("$arg"); fi
done

scripts/build.sh ${ARGS[@]+"${ARGS[@]}"}

APP="build/Storage Manager.app"
if [ "$INSTALL" = 1 ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Storage Manager.app"
  cp -R "$APP" "$HOME/Applications/"
  APP="$HOME/Applications/Storage Manager.app"
  echo "✓ Installed to $APP"
fi
open "$APP"
