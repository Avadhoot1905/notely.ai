#!/usr/bin/env bash
# Remove local, user-generated Notely data (meetings, database) to start fresh.
# Does NOT touch source, fixtures, or downloaded models.
set -euo pipefail

# Local-first data lives outside the repo, in an OS-appropriate app data dir.
case "$(uname -s)" in
  Darwin) DATA_DIR="${HOME}/Library/Application Support/ai.notely" ;;
  *)      DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/notely" ;;
esac

if [ -d "$DATA_DIR" ]; then
  read -r -p "Delete all Notely data at '$DATA_DIR'? [y/N] " ans
  case "$ans" in
    [yY]*) rm -rf "$DATA_DIR" && echo "Removed $DATA_DIR" ;;
    *)     echo "Aborted." ;;
  esac
else
  echo "No data directory found at '$DATA_DIR' — nothing to do."
fi
