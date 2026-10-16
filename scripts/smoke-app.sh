#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/Sendpoint.app}"
scripts/check-app.sh "$APP"
python3 - "$APP/Contents/MacOS/Sendpoint" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        [sys.argv[1], "--integration-smoke"],
        capture_output=True, text=True, timeout=20,
    )
except subprocess.TimeoutExpired:
    sys.exit("Integration smoke exceeded runner's 20-second timeout")
print(result.stdout, end="")
print(result.stderr, end="", file=sys.stderr)
if result.returncode != 0:
    sys.exit(f"Integration smoke exited with status {result.returncode}")
if "Integration smoke: passed (" not in result.stdout:
    sys.exit("Integration smoke exited without a success report")
PY
