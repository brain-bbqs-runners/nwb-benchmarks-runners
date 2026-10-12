# NWB Benchmarks (Runners)

Scheduled runs of the [NWB Benchmarks](https://github.com/NeurodataWithoutBorders/nwb-benchmarks) suite on self-hosted GitHub Actions runners, with the results committed to [nwb-benchmarks-results](https://github.com/NeurodataWithoutBorders/nwb-benchmarks-results).

Each contributor registers one or more of their own machines as self-hosted runners of this repository, gives every runner a unique label, and registers a workflow file that determines when to run the benchmarks with a particular configuration.

## Contents

- [How it works](#how-it-works)
- [Adding a runner](#adding-a-runner)
  - [1. Register the self-hosted runner](#1-register-the-self-hosted-runner)
  - [2. Grant the runner's user passwordless `sudo`](#2-grant-the-runners-user-passwordless-sudo)
  - [3. Set up the machine with the Set up runner workflow](#3-set-up-the-machine-with-the-set-up-runner-workflow)
  - [4. Create the upload token](#4-create-the-upload-token)
  - [5. Store the token as a repository secret](#5-store-the-token-as-a-repository-secret)
  - [6. Add the per-runner workflow](#6-add-the-per-runner-workflow)
  - [Workflow inputs](#workflow-inputs)
- [Other setups (optional)](#other-setups-optional)
  - [Without passwordless `sudo`](#without-passwordless-sudo)
  - [Native Windows](#native-windows)

## How it works

A runner is described by:

- **one workflow file** `.github/workflows/runner-<label>.yml`, which names the runner label (e.g. `lbl_laptop`), picks the schedule, and sets any machine-specific inputs (conda location, network interface, and so on)
- **one repository secret** `RESULTS_UPLOAD_TOKEN_<LABEL>` (the label in uppercase, dashes turned into underscores, e.g. `RESULTS_UPLOAD_TOKEN_LBL_LAPTOP`), which the workflow file passes to the reusable workflow as `RESULTS_UPLOAD_TOKEN`.
- **Secrets are passed explicitly**, never inherited. A job only ever receives the token of the runner it runs on.

Every job on a runner:

1. Fails immediately if it is supposed to upload but no token was passed, so a misnamed secret costs seconds rather than hours.
2. Clones `nwb-benchmarks` at the requested ref.
3. Creates a **fresh** conda environment from `environments/nwb_benchmarks.yaml`. Fresh on purpose: the benchmarks track performance against current dependency versions, and the environment id stored with each result is derived from the installed packages.
4. Runs `nwb_benchmarks run --random` from the clone under `sudo -E`, because the network tracking benchmarks need root. Each run measures one benchmark chosen at random, so the suite is sampled over many short runs rather than run in one long one, and a run that is cut short loses at most that benchmark. Only this command runs as root, and the console output is saved as a job artifact.
5. Moves the new files from `~/.nwb_benchmarks/{results,machines,environments}` into `~/.nwb_benchmarks/runner/pending/`.
6. Clones the results repository, copies in every pending file that is not already there, commits, and pushes with the runner's token (retrying if another runner pushed first). Uploaded files move to `~/.nwb_benchmarks/runner/uploaded/`. If the upload fails, the files stay pending and go with the next run.
7. Removes the clone and the conda environment, and gives the files written under `sudo` back to the runner's user.

## Adding a runner

These steps assume a macOS or Linux machine whose runner account can use `sudo` without a password.
On a Windows device, use the Windows Subsystem for Linux (WSL).
Nothing else has to be installed on the machine beforehand, because the **Set up runner** workflow in step 3 installs everything the jobs need under the runner's `_work` folder.
Machines without passwordless `sudo`, and native Windows, are covered under [Other setups](#other-setups-optional).

### 1. Register the self-hosted runner

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
./svc.sh install   # runs as the current user, the account that gets passwordless sudo in step 2
./svc.sh start
./svc.sh status
```

### 2. Grant the runner's user passwordless `sudo`

The network tracking benchmarks capture packets with `tshark`, which needs root; on macOS, mapping the packets to processes needs root too.
The action runs only the `nwb_benchmarks run` command under `sudo -E` and gives the files it wrote back to the runner's user afterwards; conda setup, upload, and cleanup stay unprivileged.

Grant it with a `sudoers` drop-in:

```
sudo visudo -f /etc/sudoers.d/nwb-benchmarks
# add one line, replacing <user> with the account the runner service runs as:
<user> ALL=(ALL) NOPASSWD: ALL
```

Confirm with `sudo -n true` as that user (it must print nothing and exit 0).

Other details:
- The default `use_sudo: auto` picks this up; set `use_sudo: true` in the runner's workflow file if you want the job to fail rather than continue without root.
- The rule grants full root to that account, so prefer a dedicated user or a dedicated machine.
- Narrowing it to one command is not useful as the action is written; `sudo` sees `/usr/bin/env`, which it uses to pass `PATH` and `HOME` through, so the rule would have to allow `env` anyway.

### 3. Set up the machine with the Set up runner workflow

Run **Actions → Set up runner → Run workflow** with the runner's label.
It installs whatever the machine lacks of Miniforge, git, a C and C++ compiler (Linux), and `tshark`.
Everything goes under `<runner>/_work/_nwb_benchmarks`, except `tshark` on Linux, which comes from the distribution's package manager through the `sudo` from step 2.
It reports what it found, `sudo`, the default network interface, and disk space; builds the benchmark conda environment once to prove the toolchain works; and ends with any lines to add to the runner's workflow file.
Re-run it any time to repair a machine; it only installs what is missing.

### 4. Create the upload token

Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with:

- **Repository access**: only the results repository, `NeurodataWithoutBorders/nwb-benchmarks-results`. The token's owner needs write access to it, because results are committed straight to its default branch (`dev`).
- **Permissions**: *Contents: Read and write*. Nothing else.

A classic token with the `public_repo` scope also works, but is not recommended for security reasons.

### 5. Store the token as a repository secret

A repository administrator adds the token under **Settings → Secrets and variables → Actions → New repository secret**, named `RESULTS_UPLOAD_TOKEN_<LABEL>`.
The runner label in uppercase with dashes turned into underscores (`lbl_laptop` → `RESULTS_UPLOAD_TOKEN_LBL_LAPTOP`).

### 6. Add the per-runner workflow

Copy `templates/runner-workflow.yml` to `.github/workflows/runner-<label>.yml` and:

- replace every `RUNNER_LABEL` with your label and `RUNNER_SECRET_NAME` with the secret name from step 5.
- choose a cron schedule (UTC).

Open a pull request to `dev`.

### Workflow inputs

If needed, set these under `with:` in `runner-<label>.yml`.

| Input | Default | Purpose |
| --- | --- | --- |
| `runner` | required | Runner label. |
| `nwb_benchmarks_repository` | `NeurodataWithoutBorders/nwb-benchmarks` | Fork to benchmark instead of upstream. |
| `nwb_benchmarks_ref` | `main` | Branch, tag, or commit of the suite to run. |
| `benchmark_pattern` | empty (one benchmark at random) | `--bench` pattern selecting a subset of the suite instead; `.` selects all of it. |
| `debug` | `false` | `--debug`: one repeat, verbose output, nothing staged or uploaded. |
| `upload` | `true` | Set to `false` to run without uploading. |
| `timeout_minutes` | `7200` | Job timeout; the default is the 5-day maximum for self-hosted runners. |
| `conda_root` | the Miniforge under `_work` | Explicit conda installation to use instead (the directory containing `etc/profile.d/conda.sh`). A conda on `PATH` is never used. |
| `conda_env_name` | `nwb_benchmarks_runner` | Name of the conda environment created at the start and, unless `keep_conda_env` is set, removed at the end of every job. |
| `network_interface` | interface of the default route | Interface for network tracking (`en0`, `eth0`, `Ethernet`, ...). Set it if auto-detection picks the wrong one or fails. |
| `tshark_path` | auto-detected | Absolute path of the `tshark` executable. Searched: the Wireshark copy under `_work`, `PATH`, common locations. Required on Windows. |
| `use_sudo` | `auto` | `auto` uses `sudo` when it works without a password; `true` requires it (job fails otherwise); `false` never uses it. |
| `cache_directory` | under `_work` | Passed to `nwb_benchmarks config_set_cache`; the suite downloads whole NWB files, so point it at a large disk if `_work` is on a small one. |
| `keep_conda_env` | `false` | Keep the conda environment between jobs. The next job updates it from the environment file instead of rebuilding it, which saves several minutes per run; packages the file does not pin then only change when the file does. |
| `results_repository` | `NeurodataWithoutBorders/nwb-benchmarks-results` | Repository the results are committed to; the token needs write access to it. |
| `results_branch` | the repository's default branch | Branch the results are committed to. |

The manual trigger form of each per-runner workflow exposes `benchmark_pattern`, `nwb_benchmarks_ref`, `debug`, and `upload`; scheduled runs use one benchmark chosen at random, `main`, no debug, and upload.

## Other setups (optional)

### Without passwordless `sudo`

Only the network tracking benchmarks need root; the timing benchmarks run either way.
When the runner's user cannot have passwordless `sudo`, pick one of these.
The **Set up runner** summary then prints the exact commands that still need a person at the machine.

**Run the whole runner as root (Linux).** GitHub's `config.sh` refuses to run as root unless you opt in:

```
sudo env RUNNER_ALLOW_RUNASROOT=1 ./config.sh --url ... --token ...
sudo ./svc.sh install root
sudo ./svc.sh start
```

Every step of every job then runs as root, including the upload step that holds the token.

Other details:
- Set `use_sudo: false` so the action does not wrap the command a second time; the Set up runner workflow, run on that runner, installs everything under `_work` as before.
- On macOS `svc.sh` installs a per-user LaunchAgent, so a root runner is not supported by the installer; use passwordless `sudo` there.

**Capture without root (Linux).** Give the capture helper the capabilities it needs and let the runner's user use it.
The **Set up runner** workflow does this when run with `capture_without_root` ticked while the runner's user still has passwordless `sudo`: grant it as in step 2 for that one run, then remove the `sudoers` line.

By hand it is:

```
sudo setcap cap_net_raw,cap_net_admin+eip "$(command -v dumpcap)"
sudo usermod -aG wireshark <user>      # Debian/Ubuntu: `sudo dpkg-reconfigure wireshark-common`, answer Yes
```

Log the user out and in again (or restart the runner service) for the group to apply, and set `use_sudo: false`.
On Linux `psutil.net_connections()` works without root for the processes the user can inspect, which includes the benchmark process itself.
On macOS, Wireshark's ChmodBPF and the `access_bpf` group cover packet capture but `psutil.net_connections()` still needs root, so this option does not apply there.

**Skip the network tracking benchmarks.** Set `use_sudo: false` without any of the above.
The timing benchmarks run normally; the network tracking benchmarks are skipped when `tshark` is missing and fail when it is present but cannot capture.

### Native Windows

Native Windows is best effort.
It needs Git for Windows, whose `bash` the jobs run in, and a Miniforge installed by hand under `<runner>\_work\_nwb_benchmarks\miniforge3` (or named with `conda_root`), since the **Set up runner** workflow cannot install one there.
`tshark` and the network tracking benchmarks cannot be enabled in this case.
