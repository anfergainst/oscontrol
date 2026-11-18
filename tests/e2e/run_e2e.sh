#!/usr/bin/env bash
# Builds oscontrol and the test fixture, then runs the end-to-end suite.
# Extra arguments are passed to run_e2e.py (e.g. --only drag, --list).
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build >/dev/null
exec python3 tests/e2e/run_e2e.py "$@"
