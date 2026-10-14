#!/usr/bin/env bash
# Commits result files to the results repository. The upload job of the Benchmarks workflow
# runs this on a GitHub-hosted runner, with the files the benchmark job collected on the
# self-hosted machine (collect_pending.sh) and the one repository-wide upload token, so the
# token never reaches a self-hosted machine.
#
# The files are committed straight to RESULTS_BRANCH of RESULTS_REPOSITORY, like the retired
# upload server did. The token therefore needs write access to that repository. Concurrent
# uploads from other runners are handled by re-syncing and retrying the push.
#
# Result and environment files already present in the repository (same file name) are
# skipped, so re-running after a partial failure never duplicates results. A machine file
# keeps its name when its content changes (the machine id leaves the machine's name out), so
# a machine file whose content differs from the repository's copy replaces it. The machine
# keeps every file pending until it sees the file in the repository, so files whose upload
# fails are sent again by the next run.
#
# Inputs (environment variables):
#   RESULTS_FILES_DIR            directory holding the files to commit, in any layout (required)
#   RESULTS_UPLOAD_TOKEN         token with write access to RESULTS_REPOSITORY (required)
#   RESULTS_REPOSITORY           owner/name to push to (default: NeurodataWithoutBorders/nwb-benchmarks-results)
#   RESULTS_BRANCH               branch to push to (default: the repository's default branch)
#   RESULTS_COMMIT_AUTHOR_NAME / RESULTS_COMMIT_AUTHOR_EMAIL  identity for the commits
#   RESULTS_REMOTE_URL           advanced: override the git URL (used by the local tests)
#   RUNNER_LABEL                 label of the runner that produced the files, used in commit messages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

FILES_DIR="${RESULTS_FILES_DIR:?RESULTS_FILES_DIR must name the directory holding the files to commit}"
RUNNER_LABEL="${RUNNER_LABEL:-$(hostname)}"
TOKEN="${RESULTS_UPLOAD_TOKEN:-}"
REPOSITORY="${RESULTS_REPOSITORY:-NeurodataWithoutBorders/nwb-benchmarks-results}"
BRANCH="${RESULTS_BRANCH:-}"
REMOTE_URL="${RESULTS_REMOTE_URL:-https://github.com/$REPOSITORY.git}"
AUTHOR_NAME="${RESULTS_COMMIT_AUTHOR_NAME:-nwb-benchmarks-runner[bot]}"
AUTHOR_EMAIL="${RESULTS_COMMIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
TEMP_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORKDIR="$TEMP_DIR/nwb-benchmarks-results-upload"
STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
MAX_PUSH_ATTEMPTS=6

if [ -n "${GITHUB_RUN_ID:-}" ]; then
  RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}"
else
  RUN_URL="(local run)"
fi

# --- Files to commit ----------------------------------------------------------------
FILES=()
if [ -d "$FILES_DIR" ]; then
  while IFS= read -r file; do
    FILES+=("$file")
  done < <(find "$FILES_DIR" -type f -name '*.json' | sort)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  log "No result files in $FILES_DIR; nothing to upload."
  exit 0
fi
log "${#FILES[@]} file(s) to upload from runner '$RUNNER_LABEL'"

[ -n "$TOKEN" ] || die "RESULTS_UPLOAD_TOKEN is empty. Add the repository secret RESULTS_UPLOAD_TOKEN (Settings > Secrets and variables > Actions) and make sure the runner's workflow file passes it. The runner keeps the files pending and sends them again with its next run."

# --- Authentication -----------------------------------------------------------------
# The token travels in an HTTP header passed on the command line of each git call, so it
# is never written to the clone's .git/config. The encoded header is masked in the logs.
AUTH_HEADER_VALUE="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
echo "::add-mask::$AUTH_HEADER_VALUE"
authenticated_git() {
  git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $AUTH_HEADER_VALUE" "$@"
}

# --- Helpers ------------------------------------------------------------------------
# Copies the files that are not yet in the clone, and the machine files whose content
# changed, and stages them. Sets ADDED_COUNT (files added or replaced), SKIPPED_COUNT, and
# ADDED_LIST (markdown bullet list).
stage_files() {
  ADDED_COUNT=0
  SKIPPED_COUNT=0
  ADDED_LIST=""
  mkdir -p "$WORKDIR/results" "$WORKDIR/machines" "$WORKDIR/environments"
  local file name subdir note
  for file in "${FILES[@]}"; do
    name="$(basename "$file")"
    if ! subdir="$(subdir_for "$name")"; then
      warn "Skipping unrecognized file $name"
      continue
    fi
    note=""
    if [ -e "$WORKDIR/$subdir/$name" ]; then
      if [ "$subdir" = machines ] && ! cmp -s "$file" "$WORKDIR/$subdir/$name"; then
        note=" (updated)"
      else
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
      fi
    fi
    cp "$file" "$WORKDIR/$subdir/$name"
    ADDED_COUNT=$((ADDED_COUNT + 1))
    ADDED_LIST="${ADDED_LIST}- ${subdir}/${name}${note}"$'\n'
  done
  git -C "$WORKDIR" add -A -- results machines environments
}

commit_staged() {
  git -C "$WORKDIR" -c "user.name=$AUTHOR_NAME" -c "user.email=$AUTHOR_EMAIL" commit --quiet \
    -m "Add benchmark results from runner '$RUNNER_LABEL'" \
    -m "$(printf 'Workflow run: %s\n\nFiles:\n%s' "$RUN_URL" "$ADDED_LIST")"
}

cleanup() {
  cd / && rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- Clone --------------------------------------------------------------------------
rm -rf "$WORKDIR"
# Without an explicit branch, the clone checks out the repository's default branch, and the
# results are pushed back to that same branch.
CLONE_ARGS=(--quiet --depth 1)
if [ -n "$BRANCH" ]; then
  CLONE_ARGS+=(--branch "$BRANCH")
fi
log "Cloning $REMOTE_URL (${BRANCH:-default branch})"
authenticated_git clone "${CLONE_ARGS[@]}" "$REMOTE_URL" "$WORKDIR"
if [ -z "$BRANCH" ]; then
  BRANCH="$(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD)"
  log "Using the default branch of $REPOSITORY: $BRANCH"
fi

stage_files
if [ "$ADDED_COUNT" -eq 0 ]; then
  log "All $SKIPPED_COUNT file(s) already exist in the repository."
  exit 0
fi
log "$ADDED_COUNT new file(s) to add ($SKIPPED_COUNT already present)"
commit_staged

# --- Push ---------------------------------------------------------------------------
attempt=1
pushed=false
while [ "$attempt" -le "$MAX_PUSH_ATTEMPTS" ]; do
  if authenticated_git -C "$WORKDIR" push --quiet "$REMOTE_URL" "HEAD:refs/heads/$BRANCH"; then
    pushed=true
    break
  fi
  if [ "$attempt" -lt "$MAX_PUSH_ATTEMPTS" ]; then
    warn "Push attempt $attempt/$MAX_PUSH_ATTEMPTS was rejected (another runner probably pushed first). Re-syncing and retrying."
    sleep $((attempt * 10))
    authenticated_git -C "$WORKDIR" fetch --quiet --depth 1 "$REMOTE_URL" "$BRANCH"
    git -C "$WORKDIR" reset --quiet --hard FETCH_HEAD
    stage_files
    if [ "$ADDED_COUNT" -eq 0 ]; then
      log "All files are present in the repository after re-syncing."
      pushed=true
      break
    fi
    commit_staged
  fi
  attempt=$((attempt + 1))
done
[ "$pushed" = true ] || die "Could not push to $REPOSITORY ($BRANCH) after $MAX_PUSH_ATTEMPTS attempts. The runner keeps the files pending and sends them again with its next run."

if [ "$ADDED_COUNT" -gt 0 ]; then
  commit_sha="$(git -C "$WORKDIR" rev-parse HEAD)"
  log "Pushed $ADDED_COUNT file(s) to $REPOSITORY ($BRANCH): https://github.com/$REPOSITORY/commit/$commit_sha"
  {
    echo "### Uploaded $ADDED_COUNT result file(s) to \`$REPOSITORY\`"
    echo ""
    echo "Commit: https://github.com/$REPOSITORY/commit/$commit_sha"
    echo ""
    echo "$ADDED_LIST"
  } >> "$STEP_SUMMARY"
fi
