# NWB Benchmarks (Runners)

Scheduled runs of the [NWB Benchmarks](https://github.com/NeurodataWithoutBorders/nwb-benchmarks) suite on self-hosted GitHub Actions runners, with the results committed to [nwb-benchmarks-results](https://github.com/NeurodataWithoutBorders/nwb-benchmarks-results).

Each contributor registers one or more of their own machines as self-hosted runners of this repository, gives every runner a unique label, and registers a workflow file that determines when to run the benchmarks with a particular configuration.

## Contents

- [How it works](#how-it-works)
- [Adding a runner](#adding-a-runner)
  - [1. Prepare the machine](#1-prepare-the-machine)
  - [2. Register the self-hosted runner](#2-register-the-self-hosted-runner)
  - [3. Set up the machine with the Set up runner workflow](#3-set-up-the-machine-with-the-set-up-runner-workflow)
  - [4. Create the upload token](#4-create-the-upload-token)
  - [5. Store the token as a repository secret](#5-store-the-token-as-a-repository-secret)
  - [6. Add the per-runner workflow](#6-add-the-per-runner-workflow)
  - [7. Test it](#7-test-it)
- [Configuration reference](#configuration-reference)
  - [Secret (one repository secret per runner)](#secret-one-repository-secret-per-runner)
  - [Workflow inputs](#workflow-inputs)
- [Operational notes](#operational-notes)

## How it works

A runner is described by exactly two things:

- **one workflow file** `.github/workflows/runner-<label>.yml`, which names the runner label (e.g. `lbl_laptop`), picks the schedule, and sets any machine-specific inputs (conda location, network interface, and so on)
- **one repository secret** `RESULTS_UPLOAD_TOKEN_<LABEL>` (the label in uppercase, dashes turned into underscores, e.g. `RESULTS_UPLOAD_TOKEN_LBL_LAPTOP`), which the workflow file passes to the reusable workflow as `RESULTS_UPLOAD_TOKEN`.
- **Secrets are passed explicitly**, never inherited. A job only ever receives the token of the runner it runs on.

Every job on a runner:

1. Fails immediately if it is supposed to upload but no token was passed, so a misnamed secret costs seconds rather than hours.
2. Clones `nwb-benchmarks` at the requested ref.
3. Creates a **fresh** conda environment from `environments/nwb_benchmarks.yaml`. Fresh on purpose: the benchmarks track performance against current dependency versions, and the environment id stored with each result is derived from the installed packages.
4. Runs `nwb_benchmarks run` from the clone, with `sudo -E` when passwordless sudo is available (the network tracking benchmarks need root on macOS and Linux). The console output is saved as a job artifact.
5. Moves the new files from `~/.nwb_benchmarks/{results,machines,environments}` into `~/.nwb_benchmarks/runner/pending/`.
6. Clones the results repository, copies in every pending file that is not already there, commits, and pushes with the runner's token (retrying if another runner pushed first). Uploaded files move to `~/.nwb_benchmarks/runner/uploaded/`. If the upload fails, the files stay pending and go with the next run.
7. Removes the clone and the conda environment, and restores file ownership after a sudo run.

## Adding a runner

### 1. Prepare the machine

- macOS or Linux. Windows is best effort: it needs Git for Windows (for `bash`) and cannot run the network tracking benchmarks, which need root.
- `git`.
- A C compiler (`gcc` or `clang`; macOS: `xcode-select --install`, Debian/Ubuntu: `sudo apt-get install build-essential`). pip needs it whenever a package in the upstream environment file has no prebuilt wheel for the Python version it pins; without one, building the benchmark environment fails on that package.
- The machine must be awake and online at the scheduled times and should otherwise be idle while the suite runs; a full run takes hours.
- Root for the network tracking benchmarks, in one of the forms described in step 3 (passwordless sudo is the usual choice). Without it the network tracking benchmarks are skipped or fail while the timing benchmarks still run.

conda and tshark are installed in step 3.

### 2. Register the self-hosted runner

First pick the **runner label**: lowercase letters, digits, dashes, and underscores, e.g. `lbl_laptop`.
It is the one string that ties everything together: the workflow file is `runner-<label>.yml` and selects the machine with `runs-on: [self-hosted, <label>]`, then the secret is `RESULTS_UPLOAD_TOKEN_<LABEL>` (all uppercase characters separate with underscores; e.g., `LBL_LAPTOP`).

An admin on the runner repository will then go to **Settings → Actions → Runners → New self-hosted runner**, choose the machine's OS and architecture, then follow all instructions provided by GitHub.
This process will ask for a number of inputs:

| Prompt | What to enter |
| --- | --- |
| `Enter the name of the runner group` | Press Enter (`Default`). |
| `Enter the name of runner` | Anything descriptive, e.g. the hostname, or the label itself. The name only shows up in the Runners list and in job logs; it does not select jobs. |
| `Enter any additional labels` | **The runner label**, e.g. `lbl_laptop`. GitHub adds `self-hosted`, the OS (`Linux`, `macOS`, `Windows`), and the architecture (`X64`, `ARM64`) automatically; keep those. |
| `Enter name of work folder` | Press Enter (`_work`). |

Labels can be changed later without re-registering: **Settings → Actions → Runners → (runner) → Labels**.

Try the runner once in the foreground with `./run.sh` (it should print `Listening for Jobs`), stop it with Ctrl-C, then install it as a service so it survives reboots:

```
./svc.sh install   # runs as the current user; make sure that user owns the conda installation
./svc.sh start
./svc.sh status
```

Only `schedule` and `workflow_dispatch` events ever reach the self-hosted runners (see [SECURITY.md](SECURITY.md)).

### 3. Set up the machine with the Set up runner workflow

Run **Actions → Set up runner → Run workflow** with the runner's label.
It installs Miniforge when no conda is found and, on macOS, Wireshark when tshark is missing, both under `<runner>/_work/_nwb_benchmarks` and without sudo.
With root (passwordless sudo for the runner's user, or a root runner) it also installs tshark on Linux and, with `capture_without_root` ticked, sets up packet capture without root (see below).
It reports the C compiler, sudo, the default network interface, and disk space; builds the benchmark conda environment once to prove the toolchain works; and ends with a copy-paste block of anything that still needs root on the machine plus the lines to add to the runner's workflow file, if any.
Re-run it any time to repair a machine; it only installs what is missing.

The two installations in detail:

- conda: the workflow installs [Miniforge](https://github.com/conda-forge/miniforge) under `<runner>/_work/_nwb_benchmarks/miniforge3`. A conda already on the machine is deliberately ignored, because its environments would live outside `_work`; to use one anyway, point the `conda_root` input at it.
- [tshark](https://tshark.dev/setup/install) (part of Wireshark), for the network tracking benchmarks. The workflow installs it: on macOS it copies `Wireshark.app` under `_work`, where its `tshark` is found automatically; on Linux it installs the distribution package when the runner's user has passwordless sudo, and otherwise prints the command. On Windows install Wireshark and set `tshark_path`.

#### Root for the network tracking benchmarks (optional)

The network tracking benchmarks capture packets with tshark and map them to processes with `psutil.net_connections()`, which needs root on macOS; packet capture needs root or a capture capability on every platform.
The timing benchmarks need neither.
There are three ways to provide root, plus the option of skipping those benchmarks.
The **Set up runner** workflow tells you where the machine stands: its summary prints the exact commands for whichever of these still needs a person at the machine, and with `capture_without_root` ticked it performs the third option itself once it has root.

**Passwordless sudo for the runner's user (default, works on macOS and Linux).** The action runs only the `nwb_benchmarks run` command under `sudo -E` and gives the files it wrote back to the runner's user afterwards; conda setup, upload, and cleanup stay unprivileged.
Grant it with a sudoers drop-in:

```
sudo visudo -f /etc/sudoers.d/nwb-benchmarks
# add one line, replacing <user> with the account the runner service runs as:
<user> ALL=(ALL) NOPASSWD: ALL
```

Confirm with `sudo -n true` as that user (it must print nothing and exit 0).
`use_sudo: auto` picks this up; set `use_sudo: true` in the runner's workflow file if you want the job to fail rather than continue without root.
The rule grants full root to that account, so prefer a dedicated user or a dedicated machine.
Narrowing it to one command is not useful as the action is written: sudo sees `/usr/bin/env`, which it uses to pass `PATH` and `HOME` through, so the rule would have to allow `env` anyway.

**Run the whole runner as root (Linux).** GitHub's `config.sh` refuses to run as root unless you opt in:

```
sudo env RUNNER_ALLOW_RUNASROOT=1 ./config.sh --url ... --token ...
sudo ./svc.sh install root
sudo ./svc.sh start
```

Every step of every job then runs as root, including the upload step that holds the token.
Install conda for root (or point `conda_root` at an installation root can read) and set `use_sudo: false` so the action does not wrap the command a second time; state lives under `/root/.nwb_benchmarks`.
On macOS `svc.sh` installs a per-user LaunchAgent, so a root runner is not supported by the installer; use passwordless sudo there.

**No root at all (Linux only).** Give the capture helper the capabilities it needs and let the runner's user use it.
The **Set up runner** workflow does this when run with `capture_without_root` ticked while the runner's user still has passwordless sudo (grant it, run the workflow, then remove the sudoers line if you want); by hand it is:

```
sudo setcap cap_net_raw,cap_net_admin+eip "$(command -v dumpcap)"
sudo usermod -aG wireshark <user>      # Debian/Ubuntu: `sudo dpkg-reconfigure wireshark-common`, answer Yes
```

Log the user out and in again (or restart the runner service) for the group to apply, and set `use_sudo: false`.
On Linux `psutil.net_connections()` works without root for the processes the user can inspect, which includes the benchmark process itself.
On macOS, Wireshark's ChmodBPF and the `access_bpf` group cover packet capture but `psutil.net_connections()` still needs root, so this option does not apply there.

**Skip the network tracking benchmarks.** Set `use_sudo: false` without any of the above.
The timing benchmarks run normally; the network tracking benchmarks are skipped when tshark is missing and fail when it is present but cannot capture.

### 4. Create the upload token

Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with:

- **Repository access**: only the results repository, `NeurodataWithoutBorders/nwb-benchmarks-results`. The token's owner needs write access to it, because results are committed straight to its default branch (`dev`).
- **Permissions**: *Contents: Read and write*. Nothing else.

A classic token with the `public_repo` scope also works, but is not recommended for security reasons.

### 5. Store the token as a repository secret

A repository administrator adds the token under **Settings → Secrets and variables → Actions → New repository secret**, named `RESULTS_UPLOAD_TOKEN_<LABEL>`: the runner label in uppercase with dashes turned into underscores (`lbl_laptop` → `RESULTS_UPLOAD_TOKEN_LBL_LAPTOP`).

### 6. Add the per-runner workflow

Copy `templates/runner-workflow.yml` to `.github/workflows/runner-<label>.yml` and:

- replace every `RUNNER_LABEL` with your label and `RUNNER_SECRET_NAME` with the secret name from step 5;
- choose a cron schedule (UTC);
- uncomment and fill in the machine inputs your machine needs (see the configuration reference; often none).

Open a pull request to `dev`.

### 7. Test it

1. **Actions → Benchmarks (<label>) → Run workflow**, tick **debug**. This runs one repeat of each benchmark with verbose output and uploads nothing. It confirms the runner is online, conda is found, and the suite starts.
2. Run it again without debug, optionally with a `benchmark_pattern` such as `time_remote_slicing.HDF5PyNWBRemfilePreloadedNoCacheContinuousSliceBenchmark.time_slice` to keep it short.
   The job summary links to the commit in the results repository.

## Configuration reference

### Secret (one repository secret per runner)

| Secret | Purpose |
| --- | --- |
| `RESULTS_UPLOAD_TOKEN_<LABEL>` | Token with write access to `results_repository`. The runner's workflow file passes it as `RESULTS_UPLOAD_TOKEN`; it reaches git as a per-command HTTP header, is never written to disk on the runner, and is masked in logs. |

### Workflow inputs

Set these under `with:` in `runner-<label>.yml`.

The composite action takes the same inputs with dashes instead of underscores (`conda-root`, `use-sudo`, ...), plus `runner-label` and `results-upload-token`; `timeout_minutes` is job-level and exists only on the workflow.

| Input | Default | Purpose |
| --- | --- | --- |
| `runner` | required | Runner label. |
| `nwb_benchmarks_repository` | `NeurodataWithoutBorders/nwb-benchmarks` | Fork to benchmark instead of upstream. |
| `nwb_benchmarks_ref` | `main` | Branch, tag, or commit of the suite to run. |
| `benchmark_pattern` | empty (full suite) | `--bench` pattern selecting a subset of the suite. |
| `debug` | `false` | `--debug`: one repeat, verbose output, nothing staged or uploaded. |
| `upload` | `true` | Set to `false` to run without uploading. |
| `timeout_minutes` | `720` | Job timeout. |
| `conda_root` | the Miniforge under `_work` | Explicit conda installation to use instead (the directory containing `etc/profile.d/conda.sh`). A conda on `PATH` is never used. |
| `conda_env_name` | `nwb_benchmarks_runner` | Name of the conda environment created at the start and removed at the end of every job. |
| `network_interface` | interface of the default route | Interface for network tracking (`en0`, `eth0`, `Ethernet`, ...). Set it if auto-detection picks the wrong one or fails. |
| `tshark_path` | auto-detected | Absolute path of the tshark executable. Searched: the Wireshark copy under `_work`, `PATH`, common locations. Required on Windows. |
| `use_sudo` | `auto` | `auto` uses sudo when it works without a password; `true` requires it (job fails otherwise); `false` never uses it. |
| `cache_directory` | under `_work` | Passed to `nwb_benchmarks config_set_cache`; the suite downloads whole NWB files, so point it at a large disk if `_work` is on a small one. |
| `keep_conda_env` | `false` | Keep the conda environment after the job for inspection. |
| `results_repository` | `NeurodataWithoutBorders/nwb-benchmarks-results` | Repository the results are committed to; the token needs write access to it. |
| `results_branch` | the repository's default branch | Branch the results are committed to. |

The manual trigger form of each per-runner workflow exposes `benchmark_pattern`, `nwb_benchmarks_ref`, `debug`, and `upload`; scheduled runs use the full suite, `main`, no debug, and upload.

## Operational notes

- Cron schedules are in UTC and only run from the default branch (`dev`). GitHub disables scheduled workflows after 60 days without commits to the repository; any commit re-enables them.
- A runner never executes two benchmark jobs at once; a second trigger for the same label waits for the first to finish. Put different machines on different hours if they share a network connection.
- Jobs time out after 12 hours by default (`timeout_minutes`).
- The job fails when `nwb_benchmarks run` produces no results file. A non-zero exit *after* results were written is tolerated and reported as a warning: versions of `nwb-benchmarks` from before [NeurodataWithoutBorders/nwb-benchmarks#198](https://github.com/NeurodataWithoutBorders/nwb-benchmarks/pull/198) still try to POST to the retired server and fail at that final step, and the workflow uploads the files itself.
- Every job stores its console log and the new result files as a workflow artifact for 30 days, so results of a failed upload can also be recovered from the Actions UI.
- Machine names in the results stay anonymous: `nwb_benchmarks` records `github-<timestamp>` whenever it runs under GitHub Actions, while the stable machine id is a hash of the hardware description.
