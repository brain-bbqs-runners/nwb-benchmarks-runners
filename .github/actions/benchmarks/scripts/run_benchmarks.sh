#!/usr/bin/env bash
# Runs the NWB Benchmarks suite inside the conda environment prepared by
# setup_environment.sh, then stages the new result files for upload.
#
# `nwb_benchmarks run` writes its reduced results to ~/.nwb_benchmarks/{results,machines,
# environments}. The files produced by this run are moved (results) or copied (machine and
# environment provenance) into a runner-owned staging directory, from which
# upload_results.sh commits them. Files whose upload fails stay staged and are retried by
# the next run.
#
# Inputs (environment variables):
#   NWB_BENCHMARKS_CLONE_DIR            path to the nwb-benchmarks checkout (required)
#   CONDA_ROOT, NWB_BENCHMARKS_CONDA_ENV  written by setup_environment.sh (required)
#   BENCHMARK_PATTERN                   optional `--bench` pattern; empty runs the full suite
#   DEBUG_MODE                          "true" passes `--debug`; nothing is staged for upload
#   NWB_BENCHMARKS_USE_SUDO             auto (default) | true | false
#   NWB_BENCHMARKS_NETWORK_INTERFACE    interface to monitor; auto-detected on macOS/Linux when empty
#   TSHARK_PATH                         explicit path to tshark; auto-detected when empty
#   NWB_BENCHMARKS_CACHE_DIRECTORY      optional directory passed to `nwb_benchmarks config_set_cache`
#   RUNNER_LOG_FILE                     where to save the console output
#   RUNNER_ARTIFACT_DIR                 where to copy the new files for the workflow artifact
#   RUNNER_PENDING_DIR                  staging directory (default: ~/.nwb_benchmarks/runner/pending)
#
# Outputs (GITHUB_OUTPUT): results_count, used_sudo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

CLONE_DIR="${NWB_BENCHMARKS_CLONE_DIR:?NWB_BENCHMARKS_CLONE_DIR must point at a checkout of nwb-benchmarks}"
CONDA_ROOT="${CONDA_ROOT:?CONDA_ROOT is not set; run setup_environment.sh first}"
ENV_NAME="${NWB_BENCHMARKS_CONDA_ENV:?NWB_BENCHMARKS_CONDA_ENV is not set; run setup_environment.sh first}"
DEBUG_MODE="$(normalize_bool "${DEBUG_MODE:-}" false)"
BENCHMARK_PATTERN="${BENCHMARK_PATTERN:-}"
TEMP_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
LOG_FILE="${RUNNER_LOG_FILE:-$TEMP_DIR/nwb-benchmarks-run.log}"
ARTIFACT_DIR="${RUNNER_ARTIFACT_DIR:-$TEMP_DIR/nwb-benchmarks-artifact}"
BENCHMARKS_HOME="$HOME/.nwb_benchmarks"
PENDING_DIR="${RUNNER_PENDING_DIR:-$BENCHMARKS_HOME/runner/pending}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

mkdir -p "$BENCHMARKS_HOME/results" "$BENCHMARKS_HOME/machines" "$BENCHMARKS_HOME/environments" \
  "$PENDING_DIR/results" "$PENDING_DIR/machines" "$PENDING_DIR/environments" \
  "$ARTIFACT_DIR" "$(dirname "$LOG_FILE")"

activate_conda_env "$CONDA_ROOT" "$ENV_NAME"

# --- Network tracking configuration -------------------------------------------------
# nwb_benchmarks treats an empty value as "set", so these are only exported when non-empty.
if tshark_bin="$(find_tshark)"; then
  export TSHARK_PATH="$tshark_bin"
  log "tshark: $TSHARK_PATH"
else
  unset TSHARK_PATH
  warn "tshark was not found; the network tracking benchmarks will be skipped."
fi

if [ -z "${NWB_BENCHMARKS_NETWORK_INTERFACE:-}" ]; then
  unset NWB_BENCHMARKS_NETWORK_INTERFACE
  # `|| true`: a missing route/ip command must not abort the run under `set -o pipefail`.
  detected=""
  if is_macos; then
    detected="$(route -n get default 2> /dev/null | awk '/interface:/ { print $2 }' || true)"
  elif ! is_windows; then
    detected="$(ip -o route show default 2> /dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }' || true)"
  fi
  if [ -n "$detected" ]; then
    export NWB_BENCHMARKS_NETWORK_INTERFACE="$detected"
    log "Network interface (auto-detected): $detected"
  else
    warn "NWB_BENCHMARKS_NETWORK_INTERFACE is not set and could not be detected. Set the 'network_interface' input in this runner's workflow file (e.g. en0, eth0, Ethernet)."
  fi
else
  log "Network interface: $NWB_BENCHMARKS_NETWORK_INTERFACE"
fi

# --- Cache directory ----------------------------------------------------------------
if [ -n "${NWB_BENCHMARKS_CACHE_DIRECTORY:-}" ]; then
  mkdir -p "$NWB_BENCHMARKS_CACHE_DIRECTORY"
  nwb_benchmarks config_set_cache "$NWB_BENCHMARKS_CACHE_DIRECTORY"
  log "Cache directory: $NWB_BENCHMARKS_CACHE_DIRECTORY"
fi

# --- sudo ---------------------------------------------------------------------------
# The network tracking benchmarks need root on macOS and Linux (psutil.net_connections).
USE_SUDO=false
sudo_mode="$(printf '%s' "${NWB_BENCHMARKS_USE_SUDO:-auto}" | tr '[:upper:]' '[:lower:]')"
case "$sudo_mode" in
  auto | "")
    if is_windows; then
      :
    elif sudo -n true 2> /dev/null; then
      USE_SUDO=true
    else
      warn "Passwordless sudo is not available for $(id -un), so the network tracking benchmarks will fail or be skipped. Grant passwordless sudo to this user, or set NWB_BENCHMARKS_USE_SUDO=false to silence this warning."
    fi
    ;;
  true | yes | 1)
    if is_windows; then
      die "NWB_BENCHMARKS_USE_SUDO=true is not supported on Windows."
    fi
    sudo -n true 2> /dev/null || die "NWB_BENCHMARKS_USE_SUDO=true but passwordless sudo is not available for $(id -un)."
    USE_SUDO=true
    ;;
  false | no | 0) ;;
  *) die "Unrecognized NWB_BENCHMARKS_USE_SUDO value '$NWB_BENCHMARKS_USE_SUDO' (expected auto, true, or false)." ;;
esac
echo "used_sudo=$USE_SUDO" >> "$GITHUB_OUTPUT"
log "Run with sudo: $USE_SUDO"

# --- Run ----------------------------------------------------------------------------
list_results() {
  find "$BENCHMARKS_HOME/results" -maxdepth 1 -type f -name '*_results.json' -exec basename {} ';' | sort
}
before="$(list_results)"

command=(nwb_benchmarks run)
if [ -n "$BENCHMARK_PATTERN" ]; then
  command+=(--bench "$BENCHMARK_PATTERN")
fi
if [ "$DEBUG_MODE" = true ]; then
  command+=(--debug)
fi
if [ "$USE_SUDO" = true ]; then
  nwb_benchmarks_bin="$(command -v nwb_benchmarks)"
  # `sudo -E` keeps the activated environment. PATH and HOME are passed explicitly because
  # common sudoers policies (secure_path, always_set_home) would otherwise replace them,
  # which would hide `conda` from nwb_benchmarks and move its home directory to root's.
  command=(sudo -E env "PATH=$PATH" "HOME=$HOME" "$nwb_benchmarks_bin" "${command[@]:1}")
fi

cd "$CLONE_DIR"
log "Working directory: $PWD"
log "Command: ${command[*]}"
log "Console output is also saved to: $LOG_FILE"
group_start "nwb_benchmarks run"
set +e
"${command[@]}" 2>&1 | tee "$LOG_FILE"
status=${PIPESTATUS[0]}
set -e
group_end
log "nwb_benchmarks exited with status $status"

if [ "$USE_SUDO" = true ]; then
  repair_ownership
fi

if [ "$DEBUG_MODE" = true ]; then
  log "Debug mode: result files are not staged for upload."
  echo "results_count=0" >> "$GITHUB_OUTPUT"
  exit "$status"
fi

# --- Stage the new files for upload -------------------------------------------------
after="$(list_results)"
new_results="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')"

if [ -z "$new_results" ]; then
  die "No new results file appeared in $BENCHMARKS_HOME/results (nwb_benchmarks exit status: $status). Check the console output above."
fi
if [ "$status" -ne 0 ]; then
  warn "nwb_benchmarks exited with status $status but did write results. Versions of nwb-benchmarks that still POST results to the retired upload server fail at that final step; this workflow uploads the files instead."
fi

count=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  mv "$BENCHMARKS_HOME/results/$name" "$PENDING_DIR/results/$name"
  cp "$PENDING_DIR/results/$name" "$ARTIFACT_DIR/"
  count=$((count + 1))
  log "Staged: results/$name"

  # Result files are named timestamp-<...>_environment-<id>_machine-<id>_results.json; the
  # matching provenance files are kept in place and copied so they travel with the result.
  environment_id="$(printf '%s' "$name" | sed -n 's/.*_environment-\([^_]*\)_machine-.*/\1/p')"
  machine_id="$(printf '%s' "$name" | sed -n 's/.*_machine-\([^_]*\)_results\.json$/\1/p')"
  for pair in "environments:environment-$environment_id.json" "machines:machine-$machine_id.json"; do
    subdir="${pair%%:*}"
    file="${pair#*:}"
    if [ -f "$BENCHMARKS_HOME/$subdir/$file" ]; then
      cp "$BENCHMARKS_HOME/$subdir/$file" "$PENDING_DIR/$subdir/$file"
      cp "$BENCHMARKS_HOME/$subdir/$file" "$ARTIFACT_DIR/"
      log "Staged: $subdir/$file"
    else
      warn "Expected provenance file $subdir/$file was not found next to $name."
    fi
  done
done <<< "$new_results"

echo "results_count=$count" >> "$GITHUB_OUTPUT"
log "$count result file(s) staged in $PENDING_DIR"

{
  echo "### Benchmark run on \`${RUNNER_LABEL:-$(hostname)}\`"
  echo ""
  echo "- nwb-benchmarks commit: \`$(git -C "$CLONE_DIR" rev-parse --short HEAD)\`"
  echo "- benchmark pattern: \`${BENCHMARK_PATTERN:-<full suite>}\`"
  echo "- new result files: $count"
  echo "- ran with sudo: $USE_SUDO"
  echo "- nwb_benchmarks exit status: $status"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
