#!/usr/bin/env bash
# Creates a fresh conda environment for the nwb-benchmarks checkout and records its
# location for the later steps of the job.
#
# A fresh environment every run is deliberate: the benchmarks track performance against
# the current versions of their dependencies, and the environment id stored with each
# result is derived from the installed packages.
#
# Inputs (environment variables):
#   NWB_BENCHMARKS_CLONE_DIR   path to the nwb-benchmarks checkout (required)
#   NWB_BENCHMARKS_CONDA_ENV   name of the conda environment to (re)create (default: nwb_benchmarks_runner)
#   CONDA_ROOT                 conda installation to use (optional; auto-detected otherwise)
#   TSHARK_PATH                explicit path to tshark (optional)
#
# Outputs (GITHUB_ENV): CONDA_ROOT, NWB_BENCHMARKS_CONDA_ENV
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"

CLONE_DIR="${NWB_BENCHMARKS_CLONE_DIR:?NWB_BENCHMARKS_CLONE_DIR must point at a checkout of nwb-benchmarks}"
ENV_NAME="${NWB_BENCHMARKS_CONDA_ENV:-nwb_benchmarks_runner}"
ENVIRONMENT_FILE="$CLONE_DIR/environments/nwb_benchmarks.yaml"

[ -f "$ENVIRONMENT_FILE" ] || die "Environment file not found: $ENVIRONMENT_FILE"

if ! CONDA_ROOT="$(find_conda_root)"; then
  die "No conda installation was found. Install Miniforge or Miniconda for the user running the GitHub Actions runner, or set the 'conda_root' input in this runner's workflow file to the installation directory."
fi
export CONDA_ROOT
log "conda installation: $CONDA_ROOT"

load_conda "$CONDA_ROOT"
export CONDA_ALWAYS_YES=true
conda --version

group_start "Create conda environment '$ENV_NAME' from $ENVIRONMENT_FILE"
if list_conda_env_names | grep -qx -- "$ENV_NAME"; then
  log "Removing the existing '$ENV_NAME' environment so this run starts from current package versions"
  conda env remove --name "$ENV_NAME"
fi
conda env create --file "$ENVIRONMENT_FILE" --name "$ENV_NAME" --no-default-packages
group_end

group_start "Installed packages"
conda list --name "$ENV_NAME"
group_end

set +u
conda activate "$ENV_NAME"
set -u
log "python:         $(command -v python)"
log "nwb_benchmarks: $(command -v nwb_benchmarks)"
python -c "import nwb_benchmarks" > /dev/null

if [ -n "${TSHARK_PATH:-}" ]; then
  if [ ! -x "$TSHARK_PATH" ]; then
    warn "TSHARK_PATH='$TSHARK_PATH' is not an executable file; network tracking benchmarks will fail."
  fi
elif ! command -v tshark > /dev/null 2>&1; then
  warn "tshark was not found on PATH, so the network tracking benchmarks will be skipped. Install Wireshark/tshark on this machine or set the 'tshark_path' input in this runner's workflow file."
fi

{
  echo "CONDA_ROOT=$CONDA_ROOT"
  echo "NWB_BENCHMARKS_CONDA_ENV=$ENV_NAME"
} >> "${GITHUB_ENV:-/dev/null}"
