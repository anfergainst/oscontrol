#!/usr/bin/env bash
# Build oscontrol in release mode and install it to a stable path that every harness can launch.
#
#   scripts/install.sh                 # installs to ~/.local/bin/oscontrol
#   PREFIX=/usr/local scripts/install.sh   # installs to /usr/local/bin/oscontrol (may need sudo)
#
# The binary is COPIED (not symlinked) so MCP configs keep working after you rebuild or move the repo.
# Re-run this script after pulling changes to update the installed copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
DEST="$PREFIX/bin/oscontrol"

cd "$ROOT"
echo "Building oscontrol (release)..."
swift build -c release --product oscontrol

mkdir -p "$PREFIX/bin"
install -m 0755 ".build/release/oscontrol" "$DEST"
echo "Installed: $DEST"
"$DEST" --version

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "Note: $PREFIX/bin is not on your PATH. Harness configs use the absolute path, so this is optional." ;;
esac

echo
echo "Next steps:"
echo "  1. $DEST doctor        # must show all three permissions as true"
echo "  2. scripts/register-harnesses.sh --dry-run   # review, then run without --dry-run"
