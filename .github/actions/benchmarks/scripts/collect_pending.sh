#!/usr/bin/env bash
# Collects the pending result files for the upload job, which commits them to the results
# repository from a GitHub-hosted runner, so the upload token never reaches this machine.
#
# Files that an earlier upload job already committed are recognized by reading the results
# repository without a token: a result or environment file counts as uploaded once the
# repository has a file of the same name, and a machine file once the repository's copy has
# the same content, the rules upload_results.sh commits by. Those files move from the pending
# to the uploaded directory. Every other pending file, including any whose earlier upload
# failed, is copied to PENDING_ARTIFACT_DIR for this run's upload job. When the repository
# cannot be read, every pending file is sent again; the upload skips the ones already there.
#
# Inputs (environment variables):
#   PENDING_ARTIFACT_DIR         where to copy the files still to upload (required)
#   RESULTS_REPOSITORY           owner/name to read (default: NeurodataWithoutBorders/nwb-benchmarks-results)
#   RESULTS_BRANCH               branch to read (default: the repository's default branch)
#   RESULTS_REMOTE_URL           advanced: override the git URL (used by the local tests)
#   RUNNER_LABEL                 label of this runner, used in the artifact name
#   RUNNER_PENDING_DIR           staging directory (default: ~/.nwb_benchmarks/runner/pending)
#   RUNNER_UPLOADED_DIR          archive of uploaded files (default: ~/.nwb_benchmarks/runner/uploaded)
#
# Outputs (GITHUB_OUTPUT): pending_count, and artifact_name (empty when nothing is left to upload)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

ARTIFACT_DIR="${PENDING_ARTIFACT_DIR:?PENDING_ARTIFACT_DIR must name the directory to collect the files in}"
RUNNER_LABEL="${RUNNER_LABEL:-$(hostname)}"
REPOSITORY="${RESULTS_REPOSITORY:-NeurodataWithoutBorders/nwb-benchmarks-results}"
BRANCH="${RESULTS_BRANCH:-}"
REMOTE_URL="${RESULTS_REMOTE_URL:-https://github.com/$REPOSITORY.git}"
BENCHMARKS_HOME="$HOME/.nwb_benchmarks"
PENDING_DIR="${RUNNER_PENDING_DIR:-$BENCHMARKS_HOME/runner/pending}"
UPLOADED_DIR="${RUNNER_UPLOADED_DIR:-$BENCHMARKS_HOME/runner/uploaded}"
TEMP_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORKDIR="$TEMP_DIR/nwb-benchmarks-results-index"
INDEX_FILE="$TEMP_DIR/nwb-benchmarks-results-index.txt"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

PENDING=()
if [ -d "$PENDING_DIR" ]; then
  while IFS= read -r file; do
    PENDING+=("$file")
  done < <(find "$PENDING_DIR" -type f -name '*.json' | sort)
fi

if [ "${#PENDING[@]}" -eq 0 ]; then
  log "No pending result files in $PENDING_DIR; nothing to upload."
  printf 'pending_count=0\nartifact_name=\n' >> "$GITHUB_OUTPUT"
  exit 0
fi
log "${#PENDING[@]} pending file(s) in $PENDING_DIR"

cleanup() {
  cd / && rm -rf "$WORKDIR" "$INDEX_FILE"
}
trap cleanup EXIT

# --- What the results repository already has ----------------------------------------
# A shallow, blob-less clone holds the file tree (names and content hashes) but none of the
# file contents, so it stays small however many results the repository has. No token is
# needed for a public repository.
rm -rf "$WORKDIR"
CLONE_ARGS=(--quiet --depth 1 --filter=blob:none --no-checkout)
if [ -n "$BRANCH" ]; then
  CLONE_ARGS+=(--branch "$BRANCH")
fi
HAVE_INDEX=false
if git clone "${CLONE_ARGS[@]}" "$REMOTE_URL" "$WORKDIR" \
  && git -C "$WORKDIR" ls-tree -r HEAD -- results machines environments > "$INDEX_FILE"; then
  HAVE_INDEX=true
else
  warn "Could not read $REPOSITORY (${BRANCH:-default branch}), so every pending file is sent to the upload job; it skips the ones the repository already has."
fi

# Succeeds when the results repository already has the pending file $1, stored as $2/<name>.
# ls-tree prints "<mode> blob <hash><TAB><path>" for each file.
already_uploaded() {
  local file="$1" subdir="$2" path blob
  [ "$HAVE_INDEX" = true ] || return 1
  path="$subdir/$(basename "$file")"
  blob="$(awk -F '\t' -v path="$path" '$2 == path { split($1, fields, " "); print fields[3]; exit }' "$INDEX_FILE")"
  [ -n "$blob" ] || return 1
  [ "$subdir" != machines ] && return 0
  [ "$blob" = "$(git -C "$WORKDIR" hash-object --stdin < "$file")" ]
}

# --- Sort the pending files ---------------------------------------------------------
TO_UPLOAD=0
ARCHIVED=0
for file in "${PENDING[@]}"; do
  name="$(basename "$file")"
  if ! subdir="$(subdir_for "$name")"; then
    warn "Skipping unrecognized file $name"
    continue
  fi
  if already_uploaded "$file" "$subdir"; then
    mkdir -p "$UPLOADED_DIR/$subdir"
    mv "$file" "$UPLOADED_DIR/$subdir/$name"
    ARCHIVED=$((ARCHIVED + 1))
  else
    mkdir -p "$ARTIFACT_DIR/$subdir"
    cp "$file" "$ARTIFACT_DIR/$subdir/$name"
    TO_UPLOAD=$((TO_UPLOAD + 1))
    log "To upload: $subdir/$name"
  fi
done

if [ "$ARCHIVED" -gt 0 ]; then
  log "Moved $ARCHIVED file(s) that $REPOSITORY already has from $PENDING_DIR to $UPLOADED_DIR"
fi
log "$TO_UPLOAD file(s) to upload"

ARTIFACT_NAME=""
if [ "$TO_UPLOAD" -gt 0 ]; then
  ARTIFACT_NAME="nwb-benchmarks-pending-${RUNNER_LABEL}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
fi
printf 'pending_count=%s\nartifact_name=%s\n' "$TO_UPLOAD" "$ARTIFACT_NAME" >> "$GITHUB_OUTPUT"
