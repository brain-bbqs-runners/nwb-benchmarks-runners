#!/usr/bin/env bash
# Shared helpers for the nwb-benchmarks-runner scripts. Source this file; do not run it.
#
# Everything here must work with the stock bash 3.2 that ships with macOS as well as
# modern bash on Linux and Git Bash on Windows.

log() { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
die() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}
group_start() { printf '::group::%s\n' "$*"; }
group_end() { printf '::endgroup::\n'; }

is_windows() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

is_macos() { [ "$(uname -s)" = "Darwin" ]; }

# Prints "true" or "false" for yes/no style values. Usage: normalize_bool "$value" "<default>"
normalize_bool() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    true | yes | y | 1 | on) printf 'true\n' ;;
    false | no | n | 0 | off) printf 'false\n' ;;
    "") printf '%s\n' "${2:-false}" ;;
    *) die "Expected a boolean value but got '$1'." ;;
  esac
}

# Everything the runner keeps between jobs lives in one directory under the runner's
# _work folder (a sibling of _temp and _tool), never in the real home directory:
#
#   <runner>/_work/_nwb_benchmarks/home        HOME for every step: ~/.nwb_benchmarks, caches, ~/.asv-machine.json
#   <runner>/_work/_nwb_benchmarks/miniforge3  conda installed by the Set up runner workflow
#   <runner>/_work/_nwb_benchmarks/tools       Wireshark.app (macOS), copied by that workflow for its tshark
#
# NWB_BENCHMARKS_STATE_DIR overrides the location. Outside a runner (local testing) it
# falls back to ~/.nwb_benchmarks_runner.
state_dir() {
  if [ -n "${NWB_BENCHMARKS_STATE_DIR:-}" ]; then
    printf '%s\n' "$NWB_BENCHMARKS_STATE_DIR"
  elif [ -n "${RUNNER_WORKSPACE:-}" ]; then
    printf '%s\n' "$(dirname "$RUNNER_WORKSPACE")/_nwb_benchmarks"
  else
    printf '%s\n' "$HOME/.nwb_benchmarks_runner"
  fi
}

# Prints the root directory of the conda installation to use: CONDA_ROOT when set, else the
# Miniforge under the state directory. A conda found on PATH or in the user's home is
# deliberately ignored, because its environments would live outside _work; the Set up
# runner workflow installs the one under _work.
find_conda_root() {
  if [ -n "${CONDA_ROOT:-}" ]; then
    if [ -f "$CONDA_ROOT/etc/profile.d/conda.sh" ]; then
      printf '%s\n' "$CONDA_ROOT"
      return 0
    fi
    die "CONDA_ROOT is set to '$CONDA_ROOT' but '$CONDA_ROOT/etc/profile.d/conda.sh' does not exist."
  fi

  local local_root
  local_root="$(state_dir)/miniforge3"
  if [ -f "$local_root/etc/profile.d/conda.sh" ]; then
    printf '%s\n' "$local_root"
    return 0
  fi
  return 1
}

# Prints the tshark executable to use: TSHARK_PATH, then the tools environment under the
# state directory, then `tshark` on PATH, then common install locations.
find_tshark() {
  if [ -n "${TSHARK_PATH:-}" ]; then
    printf '%s\n' "$TSHARK_PATH"
    return 0
  fi
  local candidate
  for candidate in "$(state_dir)/tools/Wireshark.app/Contents/MacOS/tshark" "$(state_dir)/tools/bin/tshark" \
    "$(command -v tshark 2> /dev/null || true)" \
    /opt/homebrew/bin/tshark /usr/local/bin/tshark /Applications/Wireshark.app/Contents/MacOS/tshark \
    /usr/bin/tshark "/c/Program Files/Wireshark/tshark.exe"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Makes `conda activate` available in this non-interactive shell.
load_conda() {
  local root="$1"
  # conda.sh is not clean under `set -u`.
  set +u
  # shellcheck disable=SC1091
  . "$root/etc/profile.d/conda.sh"
  set -u
}

activate_conda_env() {
  local root="$1" env_name="$2"
  load_conda "$root"
  set +u
  conda activate "$env_name"
  set -u
}

# Prints the first-column names of all conda environments.
list_conda_env_names() {
  conda env list | awk 'NF && $1 !~ /^#/ { print $1 }'
}

# Paths a benchmark run writes to. Used to repair ownership after running with sudo.
benchmark_state_paths() {
  printf '%s\n' "$(state_dir)" "$HOME/.nwb_benchmarks" "$HOME/.asv-machine.json" "$HOME/.conda" "$HOME/.cache/nwb_benchmarks"
  if [ -n "${NWB_BENCHMARKS_CACHE_DIRECTORY:-}" ]; then
    printf '%s\n' "$NWB_BENCHMARKS_CACHE_DIRECTORY"
  fi
  if [ -n "${NWB_BENCHMARKS_CLONE_DIR:-}" ]; then
    printf '%s\n' "$NWB_BENCHMARKS_CLONE_DIR/.asv"
  fi
}

# Gives every path written by a `sudo` run back to the runner's own user so later steps
# (and later runs without sudo) can read, move, and delete them.
repair_ownership() {
  local owner path
  owner="$(id -u):$(id -g)"
  while IFS= read -r path; do
    [ -e "$path" ] || continue
    if ! sudo -n chown -R "$owner" "$path"; then
      warn "Could not restore ownership of $path"
    fi
  done < <(benchmark_state_paths)
}
