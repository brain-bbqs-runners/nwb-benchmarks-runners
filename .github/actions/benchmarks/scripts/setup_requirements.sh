#!/usr/bin/env bash
# One-time (or any-time) setup of a self-hosted runner. Everything it installs lives under
# the runner's _work folder (see state_dir in common.sh); nothing is installed globally:
#
#   - Miniforge into <state>/miniforge3 when none is there yet (a conda elsewhere on the
#     machine is ignored on purpose: its environments would live outside _work)
#   - git when the machine has none, and on Linux a C and C++ compiler when it has none, from
#     conda-forge into <state>/toolchain, with only those programs linked into <state>/bin
#   - macOS: Wireshark.app, which contains tshark, into <state>/tools when tshark is not found
#
# Two things need root and are done when the job has it (passwordless sudo for the runner's
# user, or a runner running as root), otherwise listed in the summary as commands to run once
# on the machine:
#
#   - Linux: tshark from the distribution's package manager when tshark is not found
#   - Linux, optional: packet capture without root (capabilities on dumpcap plus the
#     wireshark group), so the benchmarks can run with use_sudo: false
#
# Granting passwordless sudo itself always needs a person at the machine; the summary prints
# the exact sudoers command. Windows: tshark is reported only.
#
# It then reports conda, git, the C compiler, tshark, passwordless sudo, the default network
# interface and disk space, together with the lines to add to the runner's workflow file.
# Safe to re-run; it only installs what is missing.
#
# Used by .github/workflows/setup-runner.yml, not by the benchmarks action.
#
# Inputs (environment variables):
#   INSTALL_CONDA       "true" (default) installs Miniforge under _work when it is not there yet
#   INSTALL_TOOLCHAIN   "true" (default) installs git, and on Linux a C/C++ compiler, under _work
#                       when the machine has none
#   INSTALL_TSHARK      "true" (default) installs tshark when it is not found (macOS: Wireshark.app
#                       under _work; Linux: distribution package, needs root)
#   CAPTURE_WITHOUT_ROOT "true" sets up packet capture without root on Linux (needs root once)
#   WIRESHARK_DMG_URL   override for the macOS disk image URL (default: Wireshark's "Latest" link)
#   RUNNER_LABEL        label of this runner, for the summary
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

INSTALL_CONDA="$(normalize_bool "${INSTALL_CONDA:-}" true)"
INSTALL_TOOLCHAIN="$(normalize_bool "${INSTALL_TOOLCHAIN:-}" true)"
INSTALL_TSHARK="$(normalize_bool "${INSTALL_TSHARK:-}" true)"
CAPTURE_WITHOUT_ROOT="$(normalize_bool "${CAPTURE_WITHOUT_ROOT:-}" false)"
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
IS_ROOT=false
if ! is_windows && [ "$(id -u 2> /dev/null || echo 1)" = "0" ]; then
  IS_ROOT=true
fi
# Root for the setup steps below: the runner's user with passwordless sudo, or a root runner.
HAVE_ROOT=false
if [ "$IS_ROOT" = true ] || [ "$HAVE_SUDO" = true ]; then
  HAVE_ROOT=true
fi
as_root() {
  if [ "$IS_ROOT" = true ]; then "$@"; else sudo -n "$@"; fi
}

# Commands that need root and could not be run from this job; printed in the summary as a
# block to run once on the machine.
ROOT_COMMANDS=()
root_command() { ROOT_COMMANDS+=("$*"); }

log "State directory (everything below lives here): $STATE_DIR"

# --- conda --------------------------------------------------------------------------
group_start "conda"
conda_root=""
if other_conda="$(command -v conda 2> /dev/null)"; then
  log "Ignoring the conda on PATH ($other_conda): its environments would live outside _work."
fi
if conda_root="$(find_conda_root 2> /dev/null)"; then
  log "Found conda installation at $conda_root"
elif [ "$INSTALL_CONDA" = true ]; then
  if is_windows; then
    die "No conda installation under $STATE_DIR/miniforge3. Automatic installation is not supported on Windows; install Miniforge (https://github.com/conda-forge/miniforge) there and re-run."
  fi
  conda_root="$STATE_DIR/miniforge3"
  installer="Miniforge3-$(uname -s)-$(uname -m).sh"
  url="https://github.com/conda-forge/miniforge/releases/latest/download/$installer"
  log "No conda installation under _work; installing Miniforge into $conda_root from $url"
  curl -fsSL -o "$TEMP_DIR/$installer" "$url"
  # -b: batch (accept the license, no prompts); -u: update an existing directory; -p: prefix
  bash "$TEMP_DIR/$installer" -b -u -p "$conda_root"
  rm -f "${TEMP_DIR:?}/${installer:?}"
  [ -f "$conda_root/etc/profile.d/conda.sh" ] || die "The Miniforge installer finished but $conda_root/etc/profile.d/conda.sh is missing."
  note "Miniforge was installed into \`$conda_root\`; the benchmarks action finds it there by itself."
else
  warn "No conda installation under $STATE_DIR/miniforge3 and install_conda is false."
fi

CONDA_STATUS="not found"
if [ -n "$conda_root" ]; then
  load_conda "$conda_root"
  CONDA_STATUS="$(conda --version) at \`$conda_root\`"
  log "$CONDA_STATUS"
  # The action only looks under the state directory unless conda_root is set explicitly.
  if [ "$conda_root" != "$STATE_DIR/miniforge3" ]; then
    note "conda is outside _work; keep \`conda_root: $conda_root\` in the runner's workflow file (set it if it is not there yet)."
  fi
fi
group_end

# --- git and a C compiler -------------------------------------------------------------
# What the machine lacks of these comes from conda-forge into the toolchain prefix under
# _work; only git and the compiler drivers are linked into <state>/bin, which every job puts
# first on PATH (see use_toolchain in common.sh). git is required: the jobs clone
# nwb-benchmarks and push the results with it. The compiler is insurance: pip only needs one
# for a package without a prebuilt wheel for the Python version nwb-benchmarks pins. On
# macOS it cannot come from conda-forge, because it needs Apple's SDK, which only the Xcode
# Command Line Tools provide; there the summary says how to get them if a build ever needs it.

# True when the Xcode Command Line Tools are missing. Their /usr/bin stubs (git, cc, ...)
# then only ask for the tools to be installed, so they do not count.
macos_without_clt() { is_macos && ! xcode-select -p > /dev/null 2>&1; }

# Prints the git that works on this machine, if any.
working_git() {
  local git_bin
  git_bin="$(command -v git 2> /dev/null)" || return 1
  if [ "$git_bin" = /usr/bin/git ] && macos_without_clt; then
    return 1
  fi
  "$git_bin" --version > /dev/null 2>&1 || return 1
  printf '%s\n' "$git_bin"
}

# Prints the C compiler that works on this machine, if any.
working_cc() {
  local candidate cc_bin
  macos_without_clt && return 1
  for candidate in cc gcc clang; do
    cc_bin="$(command -v "$candidate" 2> /dev/null)" || continue
    if "$cc_bin" --version > /dev/null 2>&1; then
      printf '%s\n' "$cc_bin"
      return 0
    fi
  done
  return 1
}

# Installs the given conda-forge packages into the toolchain prefix and links git and the
# compiler drivers they provide into <state>/bin.
install_toolchain() {
  local prefix bin candidate
  prefix="$(toolchain_prefix)"
  bin="$(toolchain_bin)"
  log "Installing from conda-forge into $prefix: $*"
  if [ -d "$prefix/conda-meta" ]; then
    conda install --yes --quiet --override-channels --channel conda-forge --prefix "$prefix" "$@"
  else
    conda create --yes --quiet --override-channels --channel conda-forge --prefix "$prefix" "$@"
  fi
  mkdir -p "$bin"
  if [ -x "$prefix/bin/git" ]; then
    ln -sf "$prefix/bin/git" "$bin/git"
  fi
  for candidate in "$prefix"/bin/*-conda-linux-gnu-cc; do
    [ -x "$candidate" ] || continue
    ln -sf "$candidate" "$bin/cc"
    ln -sf "$candidate" "$bin/gcc"
  done
  for candidate in "$prefix"/bin/*-conda-linux-gnu-c++; do
    [ -x "$candidate" ] || continue
    ln -sf "$candidate" "$bin/c++"
    ln -sf "$candidate" "$bin/g++"
  done
  note "Installed from conda-forge into \`$prefix\`: $*. The benchmarks action puts them on PATH by itself."
}

group_start "git and a C compiler"
# Programs installed by an earlier run of this workflow count as present.
use_toolchain
TOOLCHAIN_PACKAGES=()
if ! is_windows && ! working_git > /dev/null; then
  TOOLCHAIN_PACKAGES+=(git)
fi
if is_linux && ! working_cc > /dev/null; then
  TOOLCHAIN_PACKAGES+=(c-compiler cxx-compiler)
fi
if [ "${#TOOLCHAIN_PACKAGES[@]}" -gt 0 ]; then
  if [ "$INSTALL_TOOLCHAIN" != true ]; then
    log "Not installing ${TOOLCHAIN_PACKAGES[*]} because install_toolchain is false."
  elif [ -z "$conda_root" ]; then
    warn "Cannot install ${TOOLCHAIN_PACKAGES[*]} without a conda installation."
  else
    install_toolchain "${TOOLCHAIN_PACKAGES[@]}"
    use_toolchain
  fi
fi

if git_bin="$(working_git)"; then
  GIT_STATUS="$("$git_bin" --version) at \`$git_bin\`"
  log "$GIT_STATUS"
elif is_windows; then
  die "git was not found. Install Git for Windows (https://gitforwindows.org), which also provides the bash the jobs run in, and re-run this workflow."
else
  die "git was not found and could not be installed under _work; see the messages above. Run this workflow again with install_conda and install_toolchain ticked."
fi

if is_windows; then
  CC_STATUS="not checked on Windows"
elif cc_bin="$(working_cc)"; then
  CC_STATUS="$("$cc_bin" --version 2> /dev/null | head -n 1 || true) at \`$cc_bin\`"
elif is_macos; then
  CC_STATUS="none (the Xcode Command Line Tools are not installed)"
  note "There is no C compiler, because the Xcode Command Line Tools are not installed. Building the benchmark environment only needs one when a package has no prebuilt wheel for the Python version nwb-benchmarks pins (pip then reports \`No such file or directory: 'gcc'\` or similar). Apple's SDK cannot be installed under \`_work\`, so if that happens run \`xcode-select --install\` once on the machine."
else
  CC_STATUS="not found"
  warn "No C compiler was found or installed. Building the benchmark environment fails whenever a package has no prebuilt wheel for its Python version."
fi
log "C compiler: $CC_STATUS"
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

# Prints the command that installs tshark with this distribution's package manager.
linux_tshark_install_command() {
  if command -v apt-get > /dev/null 2>&1; then
    printf '%s\n' "apt-get install -y tshark"
  elif command -v dnf > /dev/null 2>&1; then
    printf '%s\n' "dnf install -y wireshark-cli"
  elif command -v yum > /dev/null 2>&1; then
    printf '%s\n' "yum install -y wireshark"
  elif command -v zypper > /dev/null 2>&1; then
    printf '%s\n' "zypper --non-interactive install wireshark"
  elif command -v pacman > /dev/null 2>&1; then
    printf '%s\n' "pacman -S --noconfirm wireshark-cli"
  elif command -v apk > /dev/null 2>&1; then
    printf '%s\n' "apk add tshark"
  else
    return 1
  fi
}

# Installs tshark with the package manager, as root. Non-interactive: Debian's question about
# capturing as non-superuser gets its default (no); capture_without_root covers that below.
install_tshark_linux() {
  local cmd="$1"
  log "Installing tshark with the distribution's package manager: $cmd"
  case "$cmd" in
    apt-get*)
      as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update failed; trying the install anyway."
      cmd="DEBIAN_FRONTEND=noninteractive $cmd"
      ;;
  esac
  as_root sh -c "$cmd"
}

group_start "tshark"
tshark_bin="$(find_tshark || true)"
if [ -z "$tshark_bin" ] && [ "$INSTALL_TSHARK" = true ]; then
  if is_macos; then
    install_wireshark_app_macos
    tshark_bin="$(find_tshark || true)"
  elif is_windows; then
    note "tshark is not installed. Install Wireshark (https://www.wireshark.org/download.html) and add \`tshark_path: C:\\\\Program Files\\\\Wireshark\\\\tshark.exe\` to the runner's workflow file."
  elif ! install_cmd="$(linux_tshark_install_command)"; then
    note "tshark is not installed and none of apt-get, dnf, yum, zypper, pacman or apk was found. Install tshark yourself, then re-run this workflow."
  elif [ "$HAVE_ROOT" = true ]; then
    if install_tshark_linux "$install_cmd"; then
      tshark_bin="$(find_tshark || true)"
      if [ -n "$tshark_bin" ]; then
        note "tshark was installed with the distribution's package manager."
      else
        warn "The tshark package was installed but tshark is still not on PATH; set the 'tshark_path' input in the runner's workflow file."
      fi
    else
      warn "Installing tshark failed; see the output above."
    fi
  else
    root_command "sudo $install_cmd"
    note "tshark is not installed. Installing it needs root: run the block below, or grant passwordless sudo and re-run this workflow to have it installed for you."
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
elif [ "$IS_ROOT" = true ]; then
  SUDO_STATUS="the runner runs as root, so sudo is not needed"
elif [ "$HAVE_SUDO" = true ]; then
  SUDO_STATUS="passwordless sudo works for $USER_NAME"
elif [ "$CAPTURE_WITHOUT_ROOT" = true ] && ! is_macos; then
  SUDO_STATUS="not available for $USER_NAME (not needed once capture without root is set up)"
else
  SUDO_STATUS="not available for $USER_NAME"
  root_command "sudo sh -c \"printf '$USER_NAME ALL=(ALL) NOPASSWD: ALL\\n' > /etc/sudoers.d/nwb-benchmarks && chmod 0440 /etc/sudoers.d/nwb-benchmarks && visudo -cf /etc/sudoers.d/nwb-benchmarks\""
  note "Passwordless sudo is not available for $USER_NAME, so the network tracking benchmarks will be skipped or fail. This job cannot grant it to itself; the block below does (full root for that account, see Without passwordless sudo in the README for the alternatives)."
fi
log "sudo: $SUDO_STATUS"

# --- packet capture without root (Linux) ---------------------------------------------
# Capabilities on dumpcap plus membership in the wireshark group let the runner's user
# capture packets; on Linux psutil.net_connections() works without root for the user's own
# processes, so the network tracking benchmarks can then run with use_sudo: false.
CAPTURE_STATUS=""
if [ "$CAPTURE_WITHOUT_ROOT" = true ]; then
  if is_macos || is_windows; then
    warn "capture_without_root applies to Linux only (macOS needs root for psutil.net_connections()); ignoring it."
    CAPTURE_STATUS="Linux only"
  elif [ -z "$tshark_bin" ]; then
    warn "capture_without_root needs tshark installed first; skipping it."
    CAPTURE_STATUS="skipped, tshark is not installed"
  else
    dumpcap_bin="$(command -v dumpcap 2> /dev/null || true)"
    [ -n "$dumpcap_bin" ] || dumpcap_bin="$(dirname "$tshark_bin")/dumpcap"
    if [ ! -f "$dumpcap_bin" ]; then
      warn "dumpcap was not found next to tshark ($tshark_bin); cannot set capture capabilities."
      CAPTURE_STATUS="skipped, dumpcap not found"
    elif [ "$HAVE_ROOT" = true ]; then
      # Mirrors what Debian's "dpkg-reconfigure wireshark-common" does: dumpcap carries the
      # capture capabilities and is executable only by the wireshark group.
      as_root groupadd -f wireshark
      as_root chgrp wireshark "$dumpcap_bin"
      as_root chmod 0750 "$dumpcap_bin"
      as_root setcap cap_net_raw,cap_net_admin+eip "$dumpcap_bin"
      as_root usermod -aG wireshark "$USER_NAME"
      CAPTURE_STATUS="\`$dumpcap_bin\` has capture capabilities and $USER_NAME is in group wireshark"
      log "Capture without root: $CAPTURE_STATUS"
      note "Packet capture without root is set up. Restart the runner service so the new group applies (in the runner directory: \`sudo ./svc.sh stop && sudo ./svc.sh start\`), and set \`use_sudo: false\` in the runner's workflow file. Passwordless sudo is then not needed for the benchmarks; remove /etc/sudoers.d/nwb-benchmarks if it was added only for them."
    else
      root_command "sudo groupadd -f wireshark && sudo chgrp wireshark \"$dumpcap_bin\" && sudo chmod 0750 \"$dumpcap_bin\" && sudo setcap cap_net_raw,cap_net_admin+eip \"$dumpcap_bin\" && sudo usermod -aG wireshark $USER_NAME"
      CAPTURE_STATUS="needs root once; see the block below"
      note "Setting up packet capture without root needs root once: run the block below, restart the runner service so the new group applies, and set \`use_sudo: false\` in the runner's workflow file."
    fi
  fi
fi

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
{
  echo "### Requirements on runner \`$LABEL\`"
  echo ""
  echo "| Requirement | Status |"
  echo "| --- | --- |"
  echo "| System | $(uname -s) $(uname -m), $(uname -r) |"
  echo "| Runner user | $USER_NAME |"
  echo "| State directory | \`$STATE_DIR\` |"
  echo "| conda | $CONDA_STATUS |"
  echo "| git | $GIT_STATUS |"
  echo "| C compiler | $CC_STATUS |"
  echo "| tshark | $TSHARK_STATUS |"
  echo "| Passwordless sudo | $SUDO_STATUS |"
  if [ -n "$CAPTURE_STATUS" ]; then
    echo "| Capture without root | $CAPTURE_STATUS |"
  fi
  echo "| Default network interface | ${IFACE:-not detected} |"
  echo "| Disk | $DISK_STATUS |"
  echo ""
  if [ "${#ROOT_COMMANDS[@]}" -gt 0 ]; then
    echo "**Run once on the machine, as a user who can sudo, then re-run this workflow**"
    echo ""
    echo '```sh'
    for entry in "${ROOT_COMMANDS[@]}"; do
      echo "$entry"
    done
    echo '```'
    echo ""
  fi
  if [ "${#NOTES[@]}" -gt 0 ]; then
    echo "**Next steps**"
    echo ""
    for entry in "${NOTES[@]}"; do
      echo "- $entry"
    done
    echo ""
  fi
  echo "This runner's workflow file is \`.github/workflows/runner-$LABEL.yml\`."
} | tee -a "$SUMMARY"
