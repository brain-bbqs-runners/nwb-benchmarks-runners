#!/usr/bin/env bash
# Commits the staged result files to the results repository using this runner's token.
#
# Two modes:
#   push          (default) commit straight to RESULTS_BRANCH of RESULTS_REPOSITORY. Needs a
#                 token with write access to that repository. Concurrent uploads from other
#                 runners are handled by re-syncing and retrying the push.
#   pull-request  push a new branch to RESULTS_REPOSITORY (typically the contributor's fork)
#                 and open a pull request against RESULTS_UPSTREAM_REPOSITORY. For
#                 contributors without write access to the central results repository.
#
# Files already present in the repository (same file name) are skipped, so re-running after
# a partial failure never duplicates results. Uploaded files are moved from the pending to
# the uploaded directory.
#
# Inputs (environment variables):
#   RESULTS_UPLOAD_TOKEN         token with write access to RESULTS_REPOSITORY (required)
#   RESULTS_REPOSITORY           owner/name to push to (default: NeurodataWithoutBorders/nwb-benchmarks-results)
#   RESULTS_BRANCH               branch to push to in push mode (default: main)
#   RESULTS_UPLOAD_MODE          push (default) | pull-request
#   RESULTS_UPSTREAM_REPOSITORY  pull-request mode: repository that receives the PR
#                                (default: NeurodataWithoutBorders/nwb-benchmarks-results)
#   RESULTS_UPSTREAM_BRANCH      pull-request mode: base branch of the PR (default: main)
#   RESULTS_COMMIT_AUTHOR_NAME / RESULTS_COMMIT_AUTHOR_EMAIL  identity for the commits
#   RESULTS_REMOTE_URL / RESULTS_UPSTREAM_URL  advanced: override the git URLs (used by the local tests)
#   RUNNER_LABEL                 label of this runner, used in commit messages and branch names
#   RUNNER_PENDING_DIR           staging directory (default: ~/.nwb_benchmarks/runner/pending)
#   RUNNER_UPLOADED_DIR          archive of uploaded files (default: ~/.nwb_benchmarks/runner/uploaded)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

RUNNER_LABEL="${RUNNER_LABEL:-$(hostname)}"
TOKEN="${RESULTS_UPLOAD_TOKEN:-}"
REPOSITORY="${RESULTS_REPOSITORY:-NeurodataWithoutBorders/nwb-benchmarks-results}"
BRANCH="${RESULTS_BRANCH:-main}"
MODE="$(printf '%s' "${RESULTS_UPLOAD_MODE:-push}" | tr '[:upper:]' '[:lower:]')"
UPSTREAM_REPOSITORY="${RESULTS_UPSTREAM_REPOSITORY:-NeurodataWithoutBorders/nwb-benchmarks-results}"
UPSTREAM_BRANCH="${RESULTS_UPSTREAM_BRANCH:-main}"
REMOTE_URL="${RESULTS_REMOTE_URL:-https://github.com/$REPOSITORY.git}"
UPSTREAM_URL="${RESULTS_UPSTREAM_URL:-https://github.com/$UPSTREAM_REPOSITORY.git}"
AUTHOR_NAME="${RESULTS_COMMIT_AUTHOR_NAME:-nwb-benchmarks-runner[bot]}"
AUTHOR_EMAIL="${RESULTS_COMMIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
BENCHMARKS_HOME="$HOME/.nwb_benchmarks"
PENDING_DIR="${RUNNER_PENDING_DIR:-$BENCHMARKS_HOME/runner/pending}"
UPLOADED_DIR="${RUNNER_UPLOADED_DIR:-$BENCHMARKS_HOME/runner/uploaded}"
TEMP_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORKDIR="$TEMP_DIR/nwb-benchmarks-results-upload"
STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
MAX_PUSH_ATTEMPTS=6

if [ -n "${GITHUB_RUN_ID:-}" ]; then
  RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}"
else
  RUN_URL="(local run)"
fi

case "$MODE" in
  push | pull-request) ;;
  *) die "Unrecognized RESULTS_UPLOAD_MODE '$RESULTS_UPLOAD_MODE' (expected 'push' or 'pull-request')." ;;
esac

# --- Pending files ------------------------------------------------------------------
PENDING=()
if [ -d "$PENDING_DIR" ]; then
  while IFS= read -r file; do
    PENDING+=("$file")
  done < <(find "$PENDING_DIR" -type f -name '*.json' | sort)
fi

if [ "${#PENDING[@]}" -eq 0 ]; then
  log "No pending result files in $PENDING_DIR; nothing to upload."
  exit 0
fi
log "${#PENDING[@]} pending file(s) in $PENDING_DIR"

[ -n "$TOKEN" ] || die "RESULTS_UPLOAD_TOKEN is empty. Add a repository secret for runner '$RUNNER_LABEL' (convention: RESULTS_UPLOAD_TOKEN_<LABEL>) and pass it as RESULTS_UPLOAD_TOKEN in the runner's workflow file. The staged files are kept and will be uploaded by the next successful run."

# --- Authentication -----------------------------------------------------------------
# The token travels in an HTTP header passed on the command line of each git call, so it
# is never written to the clone's .git/config. The encoded header is masked in the logs.
AUTH_HEADER_VALUE="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
echo "::add-mask::$AUTH_HEADER_VALUE"
authenticated_git() {
  git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $AUTH_HEADER_VALUE" "$@"
}

# --- Helpers ------------------------------------------------------------------------
# Prints the results-repository subdirectory for a file name, mirroring the layout the
# retired upload server used.
subdir_for() {
  case "$1" in
    environment-*.json) printf 'environments\n' ;;
    machine-*.json) printf 'machines\n' ;;
    *_results.json) printf 'results\n' ;;
    *) return 1 ;;
  esac
}

# Copies the pending files that are not yet in the clone and stages them.
# Sets ADDED_COUNT, SKIPPED_COUNT, and ADDED_LIST (markdown bullet list).
stage_pending() {
  ADDED_COUNT=0
  SKIPPED_COUNT=0
  ADDED_LIST=""
  mkdir -p "$WORKDIR/results" "$WORKDIR/machines" "$WORKDIR/environments"
  local file name subdir
  for file in "${PENDING[@]}"; do
    name="$(basename "$file")"
    if ! subdir="$(subdir_for "$name")"; then
      warn "Skipping unrecognized file $name"
      continue
    fi
    if [ -e "$WORKDIR/$subdir/$name" ]; then
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    cp "$file" "$WORKDIR/$subdir/$name"
    ADDED_COUNT=$((ADDED_COUNT + 1))
    ADDED_LIST="${ADDED_LIST}- ${subdir}/${name}"$'\n'
  done
  git -C "$WORKDIR" add -A -- results machines environments
}

commit_staged() {
  git -C "$WORKDIR" -c "user.name=$AUTHOR_NAME" -c "user.email=$AUTHOR_EMAIL" commit --quiet \
    -m "Add benchmark results from runner '$RUNNER_LABEL'" \
    -m "$(printf 'Workflow run: %s\n\nFiles:\n%s' "$RUN_URL" "$ADDED_LIST")"
}

archive_pending() {
  local file name subdir
  for file in "${PENDING[@]}"; do
    name="$(basename "$file")"
    subdir="$(subdir_for "$name")" || subdir="unrecognized"
    mkdir -p "$UPLOADED_DIR/$subdir"
    mv "$file" "$UPLOADED_DIR/$subdir/$name"
  done
  log "Moved ${#PENDING[@]} file(s) from $PENDING_DIR to $UPLOADED_DIR"
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

cleanup() {
  cd / && rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- Clone --------------------------------------------------------------------------
if [ "$MODE" = push ]; then
  SOURCE_URL="$REMOTE_URL"
  SOURCE_BRANCH="$BRANCH"
else
  # Base the pull request on the upstream repository so it is never behind a stale fork.
  SOURCE_URL="$UPSTREAM_URL"
  SOURCE_BRANCH="$UPSTREAM_BRANCH"
fi

rm -rf "$WORKDIR"
log "Cloning $SOURCE_URL ($SOURCE_BRANCH)"
authenticated_git clone --quiet --depth 1 --branch "$SOURCE_BRANCH" "$SOURCE_URL" "$WORKDIR"

stage_pending
if [ "$ADDED_COUNT" -eq 0 ]; then
  log "All $SKIPPED_COUNT pending file(s) already exist in the repository."
  archive_pending
  exit 0
fi
log "$ADDED_COUNT new file(s) to add ($SKIPPED_COUNT already present)"
commit_staged

# --- Publish ------------------------------------------------------------------------
if [ "$MODE" = push ]; then
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
      stage_pending
      if [ "$ADDED_COUNT" -eq 0 ]; then
        log "All pending files are present in the repository after re-syncing."
        pushed=true
        break
      fi
      commit_staged
    fi
    attempt=$((attempt + 1))
  done
  [ "$pushed" = true ] || die "Could not push to $REPOSITORY ($BRANCH) after $MAX_PUSH_ATTEMPTS attempts. The staged files are kept and will be retried by the next run."

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
else
  safe_label="$(printf '%s' "$RUNNER_LABEL" | tr -c 'A-Za-z0-9._-' '-')"
  head_branch="results/${safe_label}/$(date -u +%Y%m%d-%H%M%S)"
  log "Pushing branch $head_branch to $REPOSITORY"
  authenticated_git -C "$WORKDIR" push --quiet "$REMOTE_URL" "HEAD:refs/heads/$head_branch"

  if [ "$REPOSITORY" = "$UPSTREAM_REPOSITORY" ]; then
    head_ref="$head_branch"
  else
    head_ref="${REPOSITORY%%/*}:$head_branch"
  fi
  title="Benchmark results from runner '$RUNNER_LABEL'"
  # shellcheck disable=SC2016  # the backticks are markdown, not command substitution
  body="$(printf 'Automated upload of %s result file(s) from the self-hosted runner `%s`.\n\nWorkflow run: %s\n\nFiles:\n%s' \
    "$ADDED_COUNT" "$RUNNER_LABEL" "$RUN_URL" "$ADDED_LIST")"
  payload="$(printf '{"title":"%s","head":"%s","base":"%s","body":"%s","maintainer_can_modify":true}' \
    "$(json_escape "$title")" "$(json_escape "$head_ref")" "$(json_escape "$UPSTREAM_BRANCH")" "$(json_escape "$body")")"

  response_file="$TEMP_DIR/nwb-benchmarks-results-pr-response.json"
  http_code="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$UPSTREAM_REPOSITORY/pulls" \
    -d "$payload")"
  if [ "$http_code" != "201" ]; then
    cat "$response_file" || true
    rm -f "$response_file"
    die "Creating the pull request on $UPSTREAM_REPOSITORY failed (HTTP $http_code). The branch $head_branch was pushed to $REPOSITORY; open the pull request by hand. The staged files are kept for the next run."
  fi
  pr_url="$(grep -o '"html_url": *"[^"]*"' "$response_file" | head -n 1 | sed 's/.*"\(https[^"]*\)"/\1/')"
  rm -f "$response_file"
  log "Opened pull request: $pr_url"
  {
    echo "### Opened a pull request with $ADDED_COUNT result file(s)"
    echo ""
    echo "Pull request: $pr_url"
    echo ""
    echo "$ADDED_LIST"
  } >> "$STEP_SUMMARY"
fi

archive_pending
