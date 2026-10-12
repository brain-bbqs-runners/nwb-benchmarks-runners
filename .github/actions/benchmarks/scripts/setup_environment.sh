#!/usr/bin/env bash
# Creates the conda environment for the nwb-benchmarks checkout and records its location
# for the later steps of the job.
#
# By default the environment is created fresh every run: the benchmarks track performance
# against the current versions of their dependencies, and the environment id stored with
# each result is derived from the installed packages. With NWB_BENCHMARKS_KEEP_CONDA_ENV
# the environment survives between runs (cleanup.sh leaves it in place) and an existing one
# is updated from the environment file instead of being rebuilt, which is much faster;
# packages the file does not pin then only change when the file does.
#
# Inputs (environment variables):
#   NWB_BENCHMARKS_CLONE_DIR       path to the nwb-benchmarks checkout (required)
#   NWB_BENCHMARKS_CONDA_ENV       name of the conda environment (default: nwb_benchmarks_runner)
#   NWB_BENCHMARKS_KEEP_CONDA_ENV  "true" reuses an existing environment of that name
#   CONDA_ROOT                     conda installation to use (optional; auto-detected otherwise)
#   TSHARK_PATH                    explicit path to tshark (optional)
#
# Outputs (GITHUB_ENV): CONDA_ROOT, NWB_BENCHMARKS_CONDA_ENV
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

CLONE_DIR="${NWB_BENCHMARKS_CLONE_DIR:?NWB_BENCHMARKS_CLONE_DIR must point at a checkout of nwb-benchmarks}"
ENV_NAME="${NWB_BENCHMARKS_CONDA_ENV:-nwb_benchmarks_runner}"
KEEP_CONDA_ENV="$(normalize_bool "${NWB_BENCHMARKS_KEEP_CONDA_ENV:-}" false)"
ENVIRONMENT_FILE="$CLONE_DIR/environments/nwb_benchmarks.yaml"

[ -f "$ENVIRONMENT_FILE" ] || die "Environment file not found: $ENVIRONMENT_FILE"

if ! CONDA_ROOT="$(find_conda_root)"; then
  die "No conda installation under $(state_dir)/miniforge3. Run the 'Set up runner' workflow for this runner to install Miniforge there, or set the 'conda_root' input in this runner's workflow file to use an installation elsewhere."
fi
export CONDA_ROOT
log "conda installation: $CONDA_ROOT"

load_conda "$CONDA_ROOT"
export CONDA_ALWAYS_YES=true
conda --version

if [ "$KEEP_CONDA_ENV" = true ] && list_conda_env_names | grep -qx -- "$ENV_NAME"; then
  # The pip section of the file installs the checkout itself (`-e ..`), so the update also
  # picks up the nwb-benchmarks ref cloned for this run.
  group_start "Update the existing conda environment '$ENV_NAME' from $ENVIRONMENT_FILE"
  conda env update --file "$ENVIRONMENT_FILE" --name "$ENV_NAME"
  group_end
else
  group_start "Create conda environment '$ENV_NAME' from $ENVIRONMENT_FILE"
  if list_conda_env_names | grep -qx -- "$ENV_NAME"; then
    log "Removing the existing '$ENV_NAME' environment so this run starts from current package versions"
    conda env remove --name "$ENV_NAME"
  fi
  conda env create --file "$ENVIRONMENT_FILE" --name "$ENV_NAME" --no-default-packages
  group_end
fi

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
