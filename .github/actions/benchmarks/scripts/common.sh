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

# Prints the root directory of the conda installation to use.
# Honors CONDA_ROOT, then `conda` on PATH, then common installation locations.
find_conda_root() {
  if [ -n "${CONDA_ROOT:-}" ]; then
    if [ -f "$CONDA_ROOT/etc/profile.d/conda.sh" ]; then
      printf '%s\n' "$CONDA_ROOT"
      return 0
    fi
    die "CONDA_ROOT is set to '$CONDA_ROOT' but '$CONDA_ROOT/etc/profile.d/conda.sh' does not exist."
  fi

  if command -v conda > /dev/null 2>&1; then
    local base
    if base="$(conda info --base 2> /dev/null)" && [ -f "$base/etc/profile.d/conda.sh" ]; then
      printf '%s\n' "$base"
      return 0
    fi
  fi

  local candidate
  for candidate in \
    "$HOME/miniforge3" "$HOME/mambaforge" "$HOME/miniconda3" "$HOME/anaconda3" \
    "$HOME/opt/miniconda3" "$HOME/opt/anaconda3" \
    /opt/homebrew/Caskroom/miniforge/base /opt/homebrew/Caskroom/miniconda/base \
    /opt/homebrew/Caskroom/mambaforge/base /opt/homebrew/Caskroom/anaconda/base \
    /usr/local/Caskroom/miniforge/base /usr/local/Caskroom/miniconda/base \
    /opt/miniforge3 /opt/miniconda3 /opt/anaconda3 /opt/conda \
    /usr/local/miniforge3 /usr/local/miniconda3 /usr/local/anaconda3 \
    "$HOME/Miniforge3" "$HOME/Miniconda3" "$HOME/Anaconda3" \
    "$HOME/AppData/Local/miniforge3" "$HOME/AppData/Local/miniconda3" \
    /c/ProgramData/miniforge3 /c/ProgramData/miniconda3 /c/ProgramData/Anaconda3; do
    if [ -f "$candidate/etc/profile.d/conda.sh" ]; then
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
  printf '%s\n' "$HOME/.nwb_benchmarks" "$HOME/.asv-machine.json" "$HOME/.conda" "$HOME/.cache/nwb_benchmarks"
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
