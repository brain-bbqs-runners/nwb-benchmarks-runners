#!/usr/bin/env bash
# Points HOME for the rest of the job at a directory under the runner's _work folder, so
# nothing the suite or conda writes (results, caches, ~/.asv-machine.json, ~/.conda) lands
# in the runner user's real home directory, and points TMPDIR at the runner's _temp folder.
# Also exports NWB_BENCHMARKS_STATE_DIR, and puts the git and compiler that the Set up runner
# workflow installed under _work (when the machine had none) on PATH.
#
# Run it as the first step of a job (after checkout); it writes to GITHUB_ENV.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

STATE_DIR="$(state_dir)"
mkdir -p "$STATE_DIR/home"

{
  echo "NWB_BENCHMARKS_STATE_DIR=$STATE_DIR"
  echo "HOME=$STATE_DIR/home"
  # Temporary files (Python's tempfile, tshark, conda) go to the runner's _temp folder,
  # which is under _work too and is cleaned between jobs.
  if [ -n "${RUNNER_TEMP:-}" ]; then
    echo "TMPDIR=$RUNNER_TEMP"
    echo "TMP=$RUNNER_TEMP"
    echo "TEMP=$RUNNER_TEMP"
  fi
} >> "${GITHUB_ENV:-/dev/null}"

log "State directory: $STATE_DIR"
log "HOME for the remaining steps: $STATE_DIR/home"
log "Temporary files: ${RUNNER_TEMP:-system default}"

use_toolchain
if [ -d "$(toolchain_bin)" ]; then
  log "Programs installed under _work, first on PATH: $(cd "$(toolchain_bin)" && printf '%s ' *)"
fi
