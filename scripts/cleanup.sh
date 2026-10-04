#!/usr/bin/env bash
# Best-effort cleanup at the end of a job: restores file ownership after a sudo run and
# removes the nwb-benchmarks checkout and conda environment created for this run.
#
# Inputs (environment variables):
#   USED_SUDO                      "true" when run_benchmarks.sh ran with sudo
#   NWB_BENCHMARKS_CLONE_DIR       checkout to delete
#   CONDA_ROOT, NWB_BENCHMARKS_CONDA_ENV  environment to delete
#   NWB_BENCHMARKS_KEEP_CONDA_ENV  "true" keeps the conda environment for inspection
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"

USED_SUDO="$(normalize_bool "${USED_SUDO:-}" false)"
KEEP_CONDA_ENV="$(normalize_bool "${NWB_BENCHMARKS_KEEP_CONDA_ENV:-}" false)"

if [ "$USED_SUDO" = true ] && sudo -n true 2> /dev/null; then
  log "Restoring ownership of files written during the sudo run"
  repair_ownership
fi

if [ -n "${NWB_BENCHMARKS_CLONE_DIR:-}" ] && [ -e "$NWB_BENCHMARKS_CLONE_DIR" ]; then
  log "Removing $NWB_BENCHMARKS_CLONE_DIR"
  if ! rm -rf "$NWB_BENCHMARKS_CLONE_DIR" 2> /dev/null; then
    sudo -n rm -rf "$NWB_BENCHMARKS_CLONE_DIR" 2> /dev/null || warn "Could not remove $NWB_BENCHMARKS_CLONE_DIR"
  fi
fi

if [ "$KEEP_CONDA_ENV" = true ]; then
  log "Keeping conda environment '${NWB_BENCHMARKS_CONDA_ENV:-}' (NWB_BENCHMARKS_KEEP_CONDA_ENV=true)"
elif [ -n "${CONDA_ROOT:-}" ] && [ -n "${NWB_BENCHMARKS_CONDA_ENV:-}" ] && [ -f "$CONDA_ROOT/etc/profile.d/conda.sh" ]; then
  load_conda "$CONDA_ROOT"
  export CONDA_ALWAYS_YES=true
  if list_conda_env_names | grep -qx -- "$NWB_BENCHMARKS_CONDA_ENV"; then
    log "Removing conda environment '$NWB_BENCHMARKS_CONDA_ENV'"
    conda env remove --name "$NWB_BENCHMARKS_CONDA_ENV" || warn "Could not remove conda environment '$NWB_BENCHMARKS_CONDA_ENV'"
  fi
fi
