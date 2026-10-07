# NWB Benchmarks (Runners)

Scheduled runs of the [NWB Benchmarks](https://github.com/NeurodataWithoutBorders/nwb-benchmarks) suite on
self-hosted GitHub Actions runners, with the results committed to
[nwb-benchmarks-results](https://github.com/NeurodataWithoutBorders/nwb-benchmarks-results).

Each contributor registers one or more of their own machines as self-hosted runners of this repository, gives
every runner a label, and adds a small workflow file that decides when that runner benchmarks and how the machine
is configured. Every runner uploads with its own token, stored as a separate repository secret, so many people can
feed the central results repository without running a server and without any one token being shared between
machines. (The PythonAnywhere upload server that `nwb_benchmarks run` used to
post to has been retired; these workflows replace it, and
[NeurodataWithoutBorders/nwb-benchmarks#198](https://github.com/NeurodataWithoutBorders/nwb-benchmarks/pull/198)
removes the old uploader from the suite.)

## How it works

```
.github/actions/benchmarks/
  action.yml             composite action with all the steps (clone, conda env, run, upload, clean up)
  scripts/               the shell scripts the action runs on the self-hosted machine
.github/workflows/
  benchmarks.yml         reusable workflow: job-level settings (runner, concurrency, timeout) around the action
  runner-<label>.yml     one per runner or situation: schedule, runner label, machine config, token secret
  lint.yml               actionlint + shellcheck + action validation, on GitHub-hosted runners only
templates/runner-workflow.yml   copy this file to add a runner
```

A runner is described by exactly two things:

- **one workflow file** `.github/workflows/runner-<label>.yml`, which names the runner label (e.g. `lbl-mac`,
  `jane-linux-workstation`), picks the schedule, and sets any machine-specific inputs (conda location, network
  interface, ...);
- **one repository secret** `RESULTS_UPLOAD_TOKEN_<LABEL>` (the label in uppercase, dashes turned into
  underscores, e.g. `RESULTS_UPLOAD_TOKEN_LBL_MAC`), which the workflow file passes to the reusable workflow as
  `RESULTS_UPLOAD_TOKEN`. Secrets are passed explicitly, never inherited, so a job only ever receives the token
  of the runner it runs on.

A "situation" is just another workflow file: the same machine can have one file that runs the full suite
nightly and another that runs a `--bench` subset hourly, both passing the same secret.

The per-runner file calls the reusable workflow `benchmarks.yml`, which only adds the job-level settings
(which runner, one job per runner at a time, timeout) around the **composite action**
`.github/actions/benchmarks`. The action holds every step and its shell scripts, so it can also be used on
its own from any workflow, in this repository or another one:

```yaml
steps:
  - uses: CodyCBakerPhD/nwb-benchmarks-runner/.github/actions/benchmarks@dev
    with:
      runner-label: my-machine
      results-upload-token: ${{ secrets.RESULTS_UPLOAD_TOKEN_MY_MACHINE }}
      # same options as the workflow inputs below, with dashes instead of underscores
```

Every job on a runner:

1. Fails immediately if it is supposed to upload but no token was passed, so a misnamed secret costs seconds
   rather than hours.
2. Clones `nwb-benchmarks` at the requested ref.
3. Creates a **fresh** conda environment from `environments/nwb_benchmarks.yaml`. Fresh on purpose: the
   benchmarks track performance against current dependency versions, and the environment id stored with each
   result is derived from the installed packages.
4. Runs `nwb_benchmarks run` from the clone, with `sudo -E` when passwordless sudo is available (the network
   tracking benchmarks need root on macOS and Linux). The console output is saved as a job artifact.
5. Moves the new files from `~/.nwb_benchmarks/{results,machines,environments}` into
   `~/.nwb_benchmarks/runner/pending/`.
6. Clones the results repository, copies in every pending file that is not already there, commits, and pushes
   with the runner's token (retrying if another runner pushed first). Uploaded files move to
   `~/.nwb_benchmarks/runner/uploaded/`. If the upload fails, the files stay pending and go with the next run.
7. Removes the clone and the conda environment, and restores file ownership after a sudo run.

## Adding a runner

### 1. Prepare the machine

- macOS or Linux. Windows is best effort: it needs Git for Windows (for `bash`) and cannot run the
  network tracking benchmarks, which need root.
- A conda installation ([Miniforge](https://github.com/conda-forge/miniforge) recommended) for the user account
  that will run the GitHub Actions runner service. Common install locations are detected automatically;
  anything else needs the `conda_root` input (below).
- `git`.
- [tshark](https://tshark.dev/setup/install) (part of Wireshark), for the network tracking benchmarks.
- Optional but recommended: passwordless `sudo` for the runner's user, e.g. a file `/etc/sudoers.d/nwb-benchmarks`
  containing `<user> ALL=(ALL) NOPASSWD: ALL`. Without it the network tracking benchmarks are skipped or fail
  while the timing benchmarks still run. Because this grants the workflow root on the machine, prefer a dedicated
  user account or a dedicated machine.
- The machine must be awake and online at the scheduled times and should otherwise be idle while the suite runs;
  a full run takes hours.

### 2. Register the self-hosted runner

Repository **Settings → Actions → Runners → New self-hosted runner**, then follow GitHub's instructions on the
machine. When `config.sh` asks for additional labels, enter the runner label (lowercase letters, digits, and
dashes). Install the runner as a service so it survives reboots:

```
./svc.sh install   # runs as the current user; make sure that user owns the conda installation
./svc.sh start
```

Only `schedule` and `workflow_dispatch` events ever reach the self-hosted runners (see Security below).

### 3. Create the upload token

Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with:

- **Repository access**: only the repository you will push to (`NeurodataWithoutBorders/nwb-benchmarks-results`
  if you have write access there, otherwise your fork of it; see "Upload modes").
- **Permissions**: *Contents: Read and write*. Add *Pull requests: Read and write* for `pull-request` mode.
- An expiration you keep track of: when the token expires, uploads fail with an authentication error until you
  store a new one. Result files are never lost; they stay pending on the machine.

A classic token with the `public_repo` scope also works.

### 4. Store the token as a repository secret

A repository administrator adds the token under **Settings → Secrets and variables → Actions → New repository
secret**, named `RESULTS_UPLOAD_TOKEN_<LABEL>`: the runner label in uppercase with dashes turned into
underscores (`lbl-mac` → `RESULTS_UPLOAD_TOKEN_LBL_MAC`). One secret per runner; the token can be the
contributor's own or one the administrator creates for that machine. Rotating a token means replacing this one
secret; nothing on the machine changes.

### 5. Add the per-runner workflow

Copy `templates/runner-workflow.yml` to `.github/workflows/runner-<label>.yml` and:

- replace every `RUNNER_LABEL` with your label and `RUNNER_SECRET_NAME` with the secret name from step 4;
- choose a cron schedule (UTC);
- uncomment and fill in the machine inputs your machine needs (see the configuration reference; often none).

Open a pull request to `dev`. Scheduled workflows only run from the default branch, so nothing happens until
the file is merged.

### 6. Test it

1. **Actions → Benchmarks (<label>) → Run workflow**, tick **debug**. This runs one repeat of each benchmark
   with verbose output and uploads nothing. It confirms the runner is online, conda is found, and the suite
   starts.
2. Run it again without debug, optionally with a `benchmark_pattern` such as
   `time_remote_slicing.HDF5PyNWBRemfilePreloadedNoCacheContinuousSliceBenchmark.time_slice` to keep it short.
   The job summary links to the commit (or pull request) in the results repository.

## Configuration reference

### Secret (one repository secret per runner)

| Secret | Purpose |
| --- | --- |
| `RESULTS_UPLOAD_TOKEN_<LABEL>` | Token with write access to `results_repository`. The runner's workflow file passes it as `RESULTS_UPLOAD_TOKEN`; it reaches git as a per-command HTTP header, is never written to disk on the runner, and is masked in logs. |

### Inputs of the reusable workflow (set under `with:` in `runner-<label>.yml`)

The composite action takes the same inputs with dashes instead of underscores (`conda-root`, `use-sudo`, ...),
plus `runner-label` and `results-upload-token`; `timeout_minutes` is job-level and exists only on the workflow.

| Input | Default | Purpose |
| --- | --- | --- |
| `runner` | required | Runner label. |
| `nwb_benchmarks_repository` | `NeurodataWithoutBorders/nwb-benchmarks` | Fork to benchmark instead of upstream. |
| `nwb_benchmarks_ref` | `main` | Branch, tag, or commit of the suite to run. |
| `benchmark_pattern` | empty (full suite) | `--bench` pattern selecting a subset of the suite. |
| `debug` | `false` | `--debug`: one repeat, verbose output, nothing staged or uploaded. |
| `upload` | `true` | Set to `false` to run without uploading. |
| `timeout_minutes` | `720` | Job timeout. |
| `conda_root` | auto-detected | Root of the conda installation (the directory containing `etc/profile.d/conda.sh`). Set it when the job logs "No conda installation was found". |
| `conda_env_name` | `nwb_benchmarks_runner` | Name of the conda environment created at the start and removed at the end of every job. |
| `network_interface` | interface of the default route | Interface for network tracking (`en0`, `eth0`, `Ethernet`, ...). Set it if auto-detection picks the wrong one or fails. |
| `tshark_path` | `tshark` on `PATH` | Absolute path of the tshark executable. Required on Windows. |
| `use_sudo` | `auto` | `auto` uses sudo when it works without a password; `true` requires it (job fails otherwise); `false` never uses it. |
| `cache_directory` | `~/.cache/nwb_benchmarks` | Passed to `nwb_benchmarks config_set_cache`; put it on a large disk, the suite downloads whole NWB files. |
| `keep_conda_env` | `false` | Keep the conda environment after the job for inspection. |
| `results_repository` | `NeurodataWithoutBorders/nwb-benchmarks-results` | Repository the token pushes to. In `pull-request` mode, your fork. |
| `results_branch` | `main` | Branch pushed to in `push` mode. |
| `upload_mode` | `push` | `push` or `pull-request` (see below). |
| `upstream_repository` | `NeurodataWithoutBorders/nwb-benchmarks-results` | `pull-request` mode: repository that receives the pull request. |
| `upstream_branch` | `main` | `pull-request` mode: base branch of the pull request. |

The manual trigger form of each per-runner workflow exposes `benchmark_pattern`, `nwb_benchmarks_ref`, `debug`,
and `upload`; scheduled runs use the full suite, `main`, no debug, and upload.

## Upload modes

- **`push`** (default): results are committed straight to `main` of the central results repository, like the
  retired server did. Requires a token of an account with write access to that repository. Simultaneous uploads
  from several runners are safe: a rejected push is re-synced and retried, and file names are unique per run.
- **`pull-request`**: for contributors without write access. Fork the results repository, set
  `results_repository` to the fork and `upload_mode` to `pull-request` in the runner's workflow file, and give
  the token *Contents* and *Pull requests* write access on the fork. Each run pushes a branch `results/<label>/<timestamp>` to the fork
  and opens a pull request against the central repository for a maintainer to merge.

Files already present in the target repository (same file name) are skipped in both modes, so retries never
duplicate results.

## Files on the runner machine

| Path | Notes |
| --- | --- |
| `~/.nwb_benchmarks/results/`, `machines/`, `environments/` | Written by `nwb_benchmarks`. The workflow only moves out the result files it produced; machine and environment files are copied. |
| `~/.nwb_benchmarks/runner/pending/` | Files waiting for upload. Non-empty after a failed upload; the next run uploads them. |
| `~/.nwb_benchmarks/runner/uploaded/` | Archive of uploaded files. Safe to delete at any time. |
| `~/.asv-machine.json`, `~/.nwb_benchmarks/config.json`, the cache directory | Created by `asv` and `nwb_benchmarks`. |
| `<runner>/_work/nwb-benchmarks-runner/nwb-benchmarks-runner/nwb-benchmarks` | The clone; removed at the end of every job. |
| conda environment `nwb_benchmarks_runner` | Removed at the end of every job unless `keep_conda_env: true`. |

Result files on disk are owned by the runner's user even after a sudo run; the workflow restores ownership itself.

## Operational notes

- Cron schedules are in UTC and only run from the default branch (`dev`). GitHub disables scheduled workflows
  after 60 days without commits to the repository; any commit re-enables them.
- A runner never executes two benchmark jobs at once; a second trigger for the same label waits for the first to
  finish. Put different machines on different hours if they share a network connection.
- Jobs time out after 12 hours by default (`timeout_minutes`).
- The job fails when `nwb_benchmarks run` produces no results file. A non-zero exit *after* results were written
  is tolerated and reported as a warning: versions of `nwb-benchmarks` from before
  [NeurodataWithoutBorders/nwb-benchmarks#198](https://github.com/NeurodataWithoutBorders/nwb-benchmarks/pull/198)
  still try to POST to the retired server and fail at that final step, and the workflow uploads the files itself.
- Every job stores its console log and the new result files as a workflow artifact for 30 days, so results of a
  failed upload can also be recovered from the Actions UI.
- Machine names in the results stay anonymous: `nwb_benchmarks` records `github-<timestamp>` whenever it runs
  under GitHub Actions, while the stable machine id is a hash of the hardware description.

## Security

- Self-hosted runners on a public repository: only `schedule` and `workflow_dispatch` trigger jobs on them, and
  `workflow_dispatch` is limited to people with write access. Never add `pull_request` or `push` triggers to a
  workflow that uses `self-hosted`. The lint workflow runs on GitHub-hosted runners only.
- Passwordless sudo gives the benchmark suite root on the machine. Use a dedicated user or machine, and keep the
  suite pinned to `main` of the upstream repository (the default) unless you are testing your own branch.
- Tokens are scoped to a single repository and stored only as repository secrets, one per runner. Each
  per-runner workflow passes its own secret explicitly (no `secrets: inherit`), so a machine never receives
  another runner's token. Rotate a token by replacing the secret; nothing on the machine has to change.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| Job stays "Waiting for a runner to pick up this job" | The runner is offline or its label differs from the workflow's `runner` value. Check **Settings → Actions → Runners** and `./svc.sh status` on the machine. |
| `No conda installation was found` | Set the `conda_root` input in the runner's workflow file. |
| `No upload token was passed` / `RESULTS_UPLOAD_TOKEN is empty` | The repository secret named in the workflow file's `secrets:` block does not exist (check the spelling: uppercase, underscores), or the workflow file does not pass it. |
| Push rejected with 403 / authentication failed | The token expired or lacks write access to `RESULTS_REPOSITORY`. Replace it, or switch to `pull-request` mode with a fork. |
| Network tracking benchmarks skipped or failing | Install tshark or set `tshark_path`; set `network_interface`; grant passwordless sudo (macOS/Linux). |
| `Passwordless sudo is not available` warning | Configure sudoers as in step 1, or set `use_sudo: false` to accept skipping the network tracking benchmarks. |
| `Permission denied` on `~/.nwb_benchmarks` or `~/.asv-machine.json` | Leftovers from an interrupted sudo run: `sudo chown -R "$(id -un)" ~/.nwb_benchmarks ~/.asv-machine.json`. |
| `conda env create` fails | Check free disk space and `conda clean --all`; the environment file pins Python and uses `pip` for most packages, so network access to PyPI is required. |
