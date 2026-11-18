#!/usr/bin/env bash
# Register oscontrol as an MCP server in each installed harness, using that harness's own `mcp add` command.
#
#   scripts/register-harnesses.sh --dry-run          # print what would run
#   scripts/register-harnesses.sh                    # register every harness found on PATH
#   scripts/register-harnesses.sh claude pi          # register only the named harnesses
#   scripts/register-harnesses.sh --remove           # unregister oscontrol from every harness
#
# Supported harnesses: kiro-cli, claude, pi, agy, grok
# The command used for each harness is printed before it runs. Existing "oscontrol" entries are replaced.
set -uo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN="${OSCONTROL_BIN:-$PREFIX/bin/oscontrol}"
DRY=0
REMOVE=0
TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --remove) REMOVE=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) TARGETS+=("$arg") ;;
  esac
done

if [ ! -x "$BIN" ]; then
  echo "oscontrol not found at $BIN. Run scripts/install.sh first." >&2
  exit 1
fi
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(kiro-cli claude pi agy grok)

# Each entry: harness name, then the exact command to run. Scope is chosen so the server is available in
# every project (user/global), not just one directory.
command_for() {
  case "$1" in
    kiro-cli) echo "kiro-cli mcp add --name oscontrol --scope global --command $BIN --args mcp" ;;
    claude)   echo "claude mcp add --scope user oscontrol -- $BIN mcp" ;;
    pi)       echo "pi mcp add oscontrol -- $BIN mcp" ;;
    agy)      echo "agy mcp add oscontrol $BIN mcp" ;;
    grok)     echo "grok mcp add --scope user oscontrol $BIN -- mcp" ;;
    *)        return 1 ;;
  esac
}

remove_for() {
  case "$1" in
    kiro-cli) echo "kiro-cli mcp remove --name oscontrol --scope global" ;;
    claude)   echo "claude mcp remove oscontrol --scope user" ;;
    pi)       echo "pi mcp remove oscontrol" ;;
    agy)      echo "agy mcp remove oscontrol" ;;
    grok)     echo "grok mcp remove oscontrol --scope user" ;;
    *)        return 1 ;;
  esac
}

failed=0
for h in "${TARGETS[@]}"; do
  if [ "$REMOVE" -eq 1 ]; then
    cmd="$(remove_for "$h")" || { echo "[$h] unknown harness"; failed=1; continue; }
  else
    cmd="$(command_for "$h")" || { echo "[$h] unknown harness"; failed=1; continue; }
  fi
  bin_name="${cmd%% *}"
  if ! command -v "$bin_name" >/dev/null 2>&1; then
    echo "[$h] skipped: '$bin_name' is not installed"
    continue
  fi
  echo "[$h] $cmd"
  if [ "$DRY" -eq 1 ]; then continue; fi
  # shellcheck disable=SC2086
  if $cmd; then
    echo "[$h] $([ "$REMOVE" -eq 1 ] && echo removed || echo registered)"
  else
    echo "[$h] FAILED (see the harness output above)"
    failed=1
  fi
done

[ "$DRY" -eq 1 ] && echo "(dry run: nothing was changed)"
exit $failed
