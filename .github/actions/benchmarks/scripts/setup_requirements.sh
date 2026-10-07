#!/usr/bin/env bash
# One-time (or any-time) setup of a self-hosted runner. Everything it installs lives under
# the runner's _work folder (see state_dir in common.sh); nothing is installed globally:
#
#   - Miniforge into <state>/miniforge3 when no conda installation is found
#   - macOS: Wireshark.app, which contains tshark, into <state>/tools when tshark is not found
#   - Linux and Windows: tshark cannot be installed without touching the system, so the
#     script only reports what to do
#
# It then reports git, conda, tshark, passwordless sudo, the default network interface and
# disk space, together with the lines to add to the runner's workflow file. Safe to re-run;
# it only installs what is missing.
#
# Used by .github/workflows/setup-runner.yml, not by the benchmarks action.
#
# Inputs (environment variables):
#   INSTALL_CONDA       "true" (default) installs Miniforge when no conda installation is found
#   INSTALL_TSHARK      "true" (default) installs tshark on macOS when it is not found
#   WIRESHARK_DMG_URL   override for the macOS disk image URL (default: Wireshark's "Latest" link)
#   RUNNER_LABEL        label of this runner, for the summary
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

INSTALL_CONDA="$(normalize_bool "${INSTALL_CONDA:-}" true)"
INSTALL_TSHARK="$(normalize_bool "${INSTALL_TSHARK:-}" true)"
LABEL="${RUNNER_LABEL:-${RUNNER_NAME:-$(hostname)}}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
TEMP_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
USER_NAME="$(id -un)"
STATE_DIR="$(state_dir)"
mkdir -p "$STATE_DIR"

# Recommendations collected along the way and printed in the summary.
NOTES=()
note() { NOTES+=("$*"); }

HAVE_SUDO=false
if ! is_windows && sudo -n true 2> /dev/null; then
  HAVE_SUDO=true
fi

log "State directory (everything below lives here): $STATE_DIR"

# --- git ----------------------------------------------------------------------------
group_start "git"
if command -v git > /dev/null 2>&1; then
  GIT_STATUS="$(git --version)"
  log "$GIT_STATUS"
else
  die "git is not installed. On macOS run 'xcode-select --install'; on Linux install it with the package manager. Then re-run this workflow."
fi
group_end

# --- conda --------------------------------------------------------------------------
group_start "conda"
conda_root=""
if conda_root="$(find_conda_root 2> /dev/null)"; then
  log "Found conda installation at $conda_root"
elif [ "$INSTALL_CONDA" = true ]; then
  if is_windows; then
    die "No conda installation found. Automatic installation is not supported on Windows; install Miniforge (https://github.com/conda-forge/miniforge) and re-run."
  fi
  conda_root="$STATE_DIR/miniforge3"
  installer="Miniforge3-$(uname -s)-$(uname -m).sh"
  url="https://github.com/conda-forge/miniforge/releases/latest/download/$installer"
  log "No conda installation found; installing Miniforge into $conda_root from $url"
  curl -fsSL -o "$TEMP_DIR/$installer" "$url"
  # -b: batch (accept the license, no prompts); -u: update an existing directory; -p: prefix
  bash "$TEMP_DIR/$installer" -b -u -p "$conda_root"
  rm -f "${TEMP_DIR:?}/${installer:?}"
  [ -f "$conda_root/etc/profile.d/conda.sh" ] || die "The Miniforge installer finished but $conda_root/etc/profile.d/conda.sh is missing."
  note "Miniforge was installed into \`$conda_root\`; the benchmarks action finds it there by itself."
else
  warn "No conda installation found and install_conda is false."
fi

CONDA_STATUS="not found"
if [ -n "$conda_root" ]; then
  load_conda "$conda_root"
  CONDA_STATUS="$(conda --version) at \`$conda_root\`"
  log "$CONDA_STATUS"
  # The action finds conda under the state directory, on PATH, and in common locations;
  # anything else needs the conda_root input.
  if ! detected="$(CONDA_ROOT="" find_conda_root 2> /dev/null)" || [ "$detected" != "$conda_root" ]; then
    note "conda lives in a location the action does not search. Add \`conda_root: $conda_root\` to the runner's workflow file."
  fi
fi
group_end

# --- tshark -------------------------------------------------------------------------
install_wireshark_app_macos() {
  local arch url dmg mount_point tools_dir
  case "$(uname -m)" in
    arm64) arch="Arm" ;;
    x86_64) arch="Intel" ;;
    *) die "Unsupported macOS architecture $(uname -m)." ;;
  esac
  url="${WIRESHARK_DMG_URL:-https://2.na.dl.wireshark.org/osx/Wireshark%20Latest%20${arch}%2064.dmg}"
  dmg="$TEMP_DIR/wireshark.dmg"
  tools_dir="$STATE_DIR/tools"
  log "Downloading Wireshark from $url"
  if ! curl -fsSL -o "$dmg" "$url"; then
    die "Could not download Wireshark from $url. Take the current macOS ${arch} disk image link from https://www.wireshark.org/download.html and re-run with wireshark_dmg_url set to it."
  fi
  mount_point="$(mktemp -d "$TEMP_DIR/wireshark-dmg.XXXXXX")"
  hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$dmg" > /dev/null
  mkdir -p "$tools_dir"
  rm -rf "${tools_dir:?}/Wireshark.app"
  cp -R "$mount_point/Wireshark.app" "$tools_dir/Wireshark.app"
  hdiutil detach "$mount_point" > /dev/null || true
  rm -f "${dmg:?}"
  # Files copied from a downloaded image carry the quarantine attribute; Wireshark is signed
  # and notarized, but clearing it avoids any Gatekeeper prompt for the command-line tools.
  xattr -dr com.apple.quarantine "$tools_dir/Wireshark.app" 2> /dev/null || true
  note "Wireshark.app was copied to \`$tools_dir\`; the benchmarks action uses its tshark by itself."
}

group_start "tshark"
tshark_bin="$(find_tshark || true)"
if [ -z "$tshark_bin" ] && [ "$INSTALL_TSHARK" = true ]; then
  if is_macos; then
    install_wireshark_app_macos
    tshark_bin="$(find_tshark || true)"
  elif is_windows; then
    note "tshark is not installed. Install Wireshark (https://www.wireshark.org/download.html) and add \`tshark_path: C:\\\\Program Files\\\\Wireshark\\\\tshark.exe\` to the runner's workflow file."
  else
    note "tshark is not installed and has no portable Linux build, so this workflow does not install it. Install the distribution package if you want the network tracking benchmarks (Debian/Ubuntu: \`sudo apt-get install tshark\`, Fedora: \`sudo dnf install wireshark-cli\`), then re-run this workflow."
  fi
fi

TSHARK_STATUS="not found"
if [ -n "$tshark_bin" ]; then
  TSHARK_STATUS="$("$tshark_bin" --version 2> /dev/null | head -n 1) at \`$tshark_bin\`"
  log "$TSHARK_STATUS"
  if [ -n "${TSHARK_PATH:-}" ]; then
    :
  elif [ "$tshark_bin" != "$(TSHARK_PATH="" find_tshark 2> /dev/null || true)" ]; then
    note "Add \`tshark_path: $tshark_bin\` to the runner's workflow file."
  fi
else
  warn "tshark was not found; the network tracking benchmarks will be skipped until it is installed."
fi
group_end

# --- sudo ---------------------------------------------------------------------------
if is_windows; then
  SUDO_STATUS="not applicable on Windows"
elif [ "$HAVE_SUDO" = true ]; then
  SUDO_STATUS="passwordless sudo works for $USER_NAME"
else
  SUDO_STATUS="not available for $USER_NAME"
  note "Passwordless sudo is not available, so the network tracking benchmarks will fail or be skipped. See \"Root and sudo\" in the README; the usual fix is a sudoers line \`$USER_NAME ALL=(ALL) NOPASSWD: ALL\`."
fi
log "sudo: $SUDO_STATUS"

# --- network interface --------------------------------------------------------------
IFACE=""
if is_macos; then
  IFACE="$(route -n get default 2> /dev/null | awk '/interface:/ { print $2 }' || true)"
elif ! is_windows; then
  IFACE="$(ip -o route show default 2> /dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }' || true)"
fi
if [ -n "$IFACE" ]; then
  log "Default network interface: $IFACE"
else
  note "The default network interface could not be detected. Add \`network_interface: <name>\` (e.g. en0, eth0, Ethernet) to the runner's workflow file."
fi

# --- disk ---------------------------------------------------------------------------
DISK_STATUS="$(df -h "$STATE_DIR" | awk 'NR == 2 { print $4 " free on " $1 }')"
log "Disk: $DISK_STATUS"

# --- summary ------------------------------------------------------------------------
SECRET_NAME="RESULTS_UPLOAD_TOKEN_$(printf '%s' "$LABEL" | tr 'a-z-' 'A-Z_')"
{
  echo "### Requirements on runner \`$LABEL\`"
  echo ""
  echo "| Requirement | Status |"
  echo "| --- | --- |"
  echo "| System | $(uname -s) $(uname -m), $(uname -r) |"
  echo "| Runner user | $USER_NAME |"
  echo "| State directory | \`$STATE_DIR\` |"
  echo "| git | $GIT_STATUS |"
  echo "| conda | $CONDA_STATUS |"
  echo "| tshark | $TSHARK_STATUS |"
  echo "| Passwordless sudo | $SUDO_STATUS |"
  echo "| Default network interface | ${IFACE:-not detected} |"
  echo "| Disk | $DISK_STATUS |"
  echo ""
  if [ "${#NOTES[@]}" -gt 0 ]; then
    echo "**Next steps**"
    echo ""
    for entry in "${NOTES[@]}"; do
      echo "- $entry"
    done
    echo ""
  fi
  echo "This runner's workflow file is \`.github/workflows/runner-$LABEL.yml\` and its secret is \`$SECRET_NAME\`."
} | tee -a "$SUMMARY"
