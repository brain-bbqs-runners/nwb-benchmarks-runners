# Development notes

## Where a job writes on the runner machine

Everything a job writes stays inside the runner's `_work` folder.
The first step of every job points `HOME` at `<runner>/_work/_nwb_benchmarks/home`, so the suite's `~/.nwb_benchmarks`, its download cache, `~/.asv-machine.json`, and conda's own files all land there; the conda installation, the git and compiler installed when the machine had none, and (on macOS) the Wireshark copy live next to it.
The runner user's real home directory is never touched.

### Layout of `_work/_nwb_benchmarks/`

The folder is a sibling of the runner's own `_temp` and `_tool` folders.

| Path under `_work/_nwb_benchmarks/` | Notes |
| --- | --- |
| `home/` | `HOME` for every job step. Holds `.nwb_benchmarks/{results,machines,environments,logs}` written by the suite, `.nwb_benchmarks/runner/pending/` (files not yet seen in the results repository; every run sends them to the upload job again until they appear there) and `.nwb_benchmarks/runner/uploaded/` (archive, safe to delete), the download cache `.cache/nwb_benchmarks/`, `.asv-machine.json`, and conda's `.conda/`. |
| `miniforge3/` | conda, installed by the Set up runner workflow; the only conda the jobs use unless `conda_root` says otherwise. Benchmark environments are created inside it and removed at the end of every job unless `keep_conda_env: true`, in which case the next job updates the existing environment from the environment file instead of rebuilding it, and rebuilds it from scratch once it is 30 days old. |
| `tools/Wireshark.app/` | macOS only: Wireshark copied by the Set up runner workflow; its `tshark` is used automatically. |
| `toolchain/` | git and, on Linux, conda-forge's C and C++ compiler, installed from conda-forge by the Set up runner workflow when the machine has none. Its own `bin/` is never put on `PATH`. |
| `bin/` | Links to `git`, `cc`, `gcc`, `c++` and `g++` in `toolchain/`. The first step of every job puts this folder first on `PATH` and, when it holds the compiler, points `CC` and `CXX` at it. |

The clone of `nwb-benchmarks` lives in the job workspace (`_work/nwb-benchmarks-runners/.../nwb-benchmarks`) and is removed at the end of every job.
Result files stay owned by the runner's user even after a `sudo` run; the workflow restores ownership of the whole state directory itself.

## What the Set up runner workflow installs

- conda: the workflow installs [Miniforge](https://github.com/conda-forge/miniforge) under `<runner>/_work/_nwb_benchmarks/miniforge3`. A conda already on the machine is deliberately ignored, because its environments would live outside `_work`; to use one anyway, point the `conda_root` input at it.
- git and a C compiler: when the machine has none, the workflow installs them from conda-forge into `<runner>/_work/_nwb_benchmarks/toolchain`.
  Only `git` and the compiler commands are linked into `_work/_nwb_benchmarks/bin`, which every job puts first on `PATH`, so nothing else in that folder shadows the machine's own programs.
  git is required.
  The compiler is only used when a package in the upstream environment file has no prebuilt wheel for the Python version it pins; on Linux it is conda-forge's GCC, about 1 GB on disk.
  On macOS a compiler cannot come from conda-forge, because it needs Apple's SDK; if a build ever needs one, run `xcode-select --install` once on the machine.
- [`tshark`](https://tshark.dev/setup/install) (part of Wireshark), for the network tracking benchmarks. The workflow installs it: on macOS it copies `Wireshark.app` under `_work`, where its `tshark` is found automatically; on Linux it installs the distribution package when the runner's user has passwordless `sudo`, and otherwise prints the command. On Windows install Wireshark and set `tshark_path`.

## Reusable workflow and composite actions

The per-runner file calls the reusable workflow `benchmarks.yml`, which runs two jobs, each around a **composite action**:

- `benchmarks`, on the self-hosted runner, adds the job-level settings (which runner, one job per runner at a time, timeout) around `.github/actions/benchmarks`. That action runs the suite, then reads the results repository without a token to tell which pending files still need uploading, and saves those as a workflow artifact named in its `pending-artifact` output.
- `upload`, on `ubuntu-latest`, runs `.github/actions/upload-results`, which downloads that artifact and commits it with the `RESULTS_UPLOAD_TOKEN` secret. It is skipped when there is nothing to upload (debug runs, `upload: false`).

Keeping the upload on a GitHub-hosted runner is what lets every runner share one token without any self-hosted machine receiving it.
The actions hold every step and their shell scripts, so they can also be used on their own from any workflow, in this repository or another one:

```yaml
jobs:
  benchmarks:
    runs-on: [self-hosted, lbl_laptop]
    outputs:
      pending_artifact: ${{ steps.benchmarks.outputs.pending-artifact }}
    steps:
      - id: benchmarks
        uses: brain-bbqs-runners/nwb-benchmarks-runners/.github/actions/benchmarks@main
        with:
          runner-label: lbl_laptop
          # same options as the workflow inputs below, with dashes instead of underscores
  upload:
    needs: benchmarks
    if: ${{ needs.benchmarks.outputs.pending_artifact != '' }}
    runs-on: ubuntu-latest
    steps:
      - uses: brain-bbqs-runners/nwb-benchmarks-runners/.github/actions/upload-results@main
        with:
          artifact-name: ${{ needs.benchmarks.outputs.pending_artifact }}
          runner-label: lbl_laptop
          results-upload-token: ${{ secrets.RESULTS_UPLOAD_TOKEN }}
```

The inputs of the actions are the workflow inputs with dashes instead of underscores; `lint.yml` checks that each action only references inputs it declares.

## Operational notes

- Cron schedules are in UTC and only run from the default branch (`main`). GitHub disables scheduled workflows after 60 days without commits to the repository; any commit re-enables them.
- A runner never executes two benchmark jobs at once; a second trigger for the same label waits for the first to finish, and GitHub keeps at most one run waiting per runner, so hourly triggers that arrive while a long benchmark runs are canceled rather than queued up. Put different machines on different minutes if they share a network connection.
- Jobs time out after 5 days by default (`timeout_minutes`), the maximum GitHub allows for a job on a self-hosted runner.
- A scheduled run measures one benchmark chosen at random (`nwb_benchmarks run --random`), about a hundred are eligible, and the runners run hourly, so each benchmark is sampled about every four days on average. The chosen benchmark is in the job summary and in the console log.
- A runner can be limited to part of the day: `runner-ackermann.yml` runs from noon to midnight Eastern time. GitHub's cron is UTC and ignores daylight saving, so its cron lines cover the UTC hours of both the EDT and the EST window and a small `window` job on a GitHub-hosted runner checks the New York clock and skips the benchmark job outside the window; manual runs always go ahead.
- The pool the random pick chooses from is whatever the suite discovers on that machine: the network tracking benchmarks need `tshark`, and the download and incremental slicing benchmarks need `run_download_benchmarks` and `run_incremental_slicing_benchmarks` in the runner's workflow file, since the suite leaves them out otherwise. The job summary says which of the opt-in parts were included.
- The job fails when `nwb_benchmarks run` produces no results file. A non-zero exit *after* results were written is tolerated and reported as a warning: versions of `nwb-benchmarks` from before [NeurodataWithoutBorders/nwb-benchmarks#198](https://github.com/NeurodataWithoutBorders/nwb-benchmarks/pull/198) still try to POST to the retired server and fail at that final step, and the workflow uploads the files itself.
- Every benchmark job stores its console log and the new result files as a workflow artifact for 30 days, so results of a failed upload can also be recovered from the Actions UI.
- The files handed to the upload job are a separate artifact, kept for 7 days. A failed upload job can be re-run on its own while it exists; otherwise the files stay pending on the machine and its next run sends them again.
- A pending file leaves `pending/` once the benchmark job sees it in the results repository, which it reads with a blob-less shallow clone (file names and content hashes only, no token). If the repository cannot be read, every pending file is sent to the upload job, which skips the ones already there.
- The upload never replaces a result or environment file the repository already has, so a retry cannot duplicate or alter results. A machine file is the exception: its id leaves the machine's name out, so when its content changes (for example the name after a rename) the upload replaces the repository's copy under the same id.
- Machine names in the results stay anonymous: `nwb_benchmarks` records `github-<timestamp>` whenever it runs under GitHub Actions, while the stable machine id is a hash of the hardware description.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| Job stays "Waiting for a runner to pick up this job" | The runner is offline or its label differs from the workflow's `runner` value. Check **Settings → Actions → Runners** and `./svc.sh status` on the machine. |
| `No conda installation under .../_work/_nwb_benchmarks/miniforge3` | Run the **Set up runner** workflow for this runner, or set the `conda_root` input to use an installation elsewhere. |
| Upload job fails with `RESULTS_UPLOAD_TOKEN is empty` | The repository secret `RESULTS_UPLOAD_TOKEN` does not exist, or the runner's workflow file does not pass it in its `secrets:` block. The result files stay pending on the machine and go with its next run once fixed. |
| Upload job's push rejected with 403 / authentication failed | The token expired or its owner lacks write access to `results_repository`. Replace the `RESULTS_UPLOAD_TOKEN` secret. |
| Network tracking benchmarks skipped or failing | Install `tshark` or set `tshark_path`; set `network_interface`; grant passwordless `sudo` (macOS/Linux). |
| `Passwordless sudo is not available` warning | Grant it as in step 2 of "Adding a runner" in the README, pick an option under "Without passwordless `sudo`", or set `use_sudo: false` to accept skipping the network tracking benchmarks. |
| `Permission denied` under `_work/_nwb_benchmarks` | Leftovers from an interrupted `sudo` run: `sudo chown -R "$(id -un)" <runner>/_work/_nwb_benchmarks`. |
| `No such file or directory: 'gcc'` / `Failed to build numcodecs` during `conda env create` | A package in the upstream environment file has no prebuilt wheel for the Python version it pins, so pip compiles it and finds no C compiler. On Linux, re-run **Set up runner**, which installs conda-forge's GCC under `_work` when the machine has none; on macOS run `xcode-select --install` once on the machine. If the compile itself fails, fix the pins in `environments/nwb_benchmarks.yaml` upstream. The **Set up runner** summary shows which compiler the jobs use. |
| `conda env create` fails | Check free disk space and `conda clean --all`; the environment file pins Python and uses `pip` for most packages, so network access to PyPI is required. |
