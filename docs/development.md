# Development notes

## Where a job writes on the runner machine

Everything a job writes stays inside the runner's `_work` folder.
The first step of every job points `HOME` at `<runner>/_work/_nwb_benchmarks/home`, so the suite's `~/.nwb_benchmarks`, its download cache, `~/.asv-machine.json`, and conda's own files all land there; the conda installation, the git and compiler installed when the machine had none, and (on macOS) the Wireshark copy live next to it.
The runner user's real home directory is never touched.

### Layout of `_work/_nwb_benchmarks/`

The folder is a sibling of the runner's own `_temp` and `_tool` folders.

| Path under `_work/_nwb_benchmarks/` | Notes |
| --- | --- |
| `home/` | `HOME` for every job step. Holds `.nwb_benchmarks/{results,machines,environments,logs}` written by the suite, `.nwb_benchmarks/runner/pending/` (files waiting for upload; non-empty after a failed upload, the next run uploads them) and `.nwb_benchmarks/runner/uploaded/` (archive, safe to delete), the download cache `.cache/nwb_benchmarks/`, `.asv-machine.json`, and conda's `.conda/`. |
| `miniforge3/` | conda, installed by the Set up runner workflow; the only conda the jobs use unless `conda_root` says otherwise. Benchmark environments are created inside it and removed at the end of every job unless `keep_conda_env: true`. |
| `tools/Wireshark.app/` | macOS only: Wireshark copied by the Set up runner workflow; its `tshark` is used automatically. |
| `toolchain/` | git and, on Linux, conda-forge's C and C++ compiler, installed from conda-forge by the Set up runner workflow when the machine has none. Its own `bin/` is never put on `PATH`. |
| `bin/` | Links to `git`, `cc`, `gcc`, `c++` and `g++` in `toolchain/`. The first step of every job puts this folder first on `PATH` and, when it holds the compiler, points `CC` and `CXX` at it. |

The clone of `nwb-benchmarks` lives in the job workspace (`_work/nwb-benchmarks-runner/.../nwb-benchmarks`) and is removed at the end of every job.
Result files stay owned by the runner's user even after a sudo run; the workflow restores ownership of the whole state directory itself.

## What the Set up runner workflow installs

- conda: the workflow installs [Miniforge](https://github.com/conda-forge/miniforge) under `<runner>/_work/_nwb_benchmarks/miniforge3`. A conda already on the machine is deliberately ignored, because its environments would live outside `_work`; to use one anyway, point the `conda_root` input at it.
- git and a C compiler: when the machine has none, the workflow installs them from conda-forge into `<runner>/_work/_nwb_benchmarks/toolchain`.
  Only `git` and the compiler commands are linked into `_work/_nwb_benchmarks/bin`, which every job puts first on `PATH`, so nothing else in that folder shadows the machine's own programs.
  git is required.
  The compiler is only used when a package in the upstream environment file has no prebuilt wheel for the Python version it pins; on Linux it is conda-forge's GCC, about 1 GB on disk.
  On macOS a compiler cannot come from conda-forge, because it needs Apple's SDK; if a build ever needs one, run `xcode-select --install` once on the machine.
- [tshark](https://tshark.dev/setup/install) (part of Wireshark), for the network tracking benchmarks. The workflow installs it: on macOS it copies `Wireshark.app` under `_work`, where its `tshark` is found automatically; on Linux it installs the distribution package when the runner's user has passwordless sudo, and otherwise prints the command. On Windows install Wireshark and set `tshark_path`.

## Reusable workflow and composite action

The per-runner file calls the reusable workflow `benchmarks.yml`, which only adds the job-level settings (which runner, one job per runner at a time, timeout) around the **composite action** `.github/actions/benchmarks`.
The action holds every step and its shell scripts, so it can also be used on its own from any workflow, in this repository or another one:

```yaml
steps:
  - uses: CodyCBakerPhD/nwb-benchmarks-runner/.github/actions/benchmarks@dev
    with:
      runner-label: lbl_laptop
      results-upload-token: ${{ secrets.RESULTS_UPLOAD_TOKEN_LBL_LAPTOP }}
      # same options as the workflow inputs below, with dashes instead of underscores
```

The inputs of the action are the workflow inputs with dashes instead of underscores; `lint.yml` checks that the action only references inputs it declares.

## Operational notes

- Cron schedules are in UTC and only run from the default branch (`dev`). GitHub disables scheduled workflows after 60 days without commits to the repository; any commit re-enables them.
- A runner never executes two benchmark jobs at once; a second trigger for the same label waits for the first to finish. Put different machines on different hours if they share a network connection.
- Jobs time out after 12 hours by default (`timeout_minutes`).
- The job fails when `nwb_benchmarks run` produces no results file. A non-zero exit *after* results were written is tolerated and reported as a warning: versions of `nwb-benchmarks` from before [NeurodataWithoutBorders/nwb-benchmarks#198](https://github.com/NeurodataWithoutBorders/nwb-benchmarks/pull/198) still try to POST to the retired server and fail at that final step, and the workflow uploads the files itself.
- Every job stores its console log and the new result files as a workflow artifact for 30 days, so results of a failed upload can also be recovered from the Actions UI.
- Machine names in the results stay anonymous: `nwb_benchmarks` records `github-<timestamp>` whenever it runs under GitHub Actions, while the stable machine id is a hash of the hardware description.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| Job stays "Waiting for a runner to pick up this job" | The runner is offline or its label differs from the workflow's `runner` value. Check **Settings → Actions → Runners** and `./svc.sh status` on the machine. |
| `No conda installation under .../_work/_nwb_benchmarks/miniforge3` | Run the **Set up runner** workflow for this runner, or set the `conda_root` input to use an installation elsewhere. |
| `No upload token was passed` / `RESULTS_UPLOAD_TOKEN is empty` | The repository secret named in the workflow file's `secrets:` block does not exist (check the spelling: uppercase, underscores), or the workflow file does not pass it. |
| Push rejected with 403 / authentication failed | The token expired or its owner lacks write access to `results_repository`. Replace the secret. |
| Network tracking benchmarks skipped or failing | Install tshark or set `tshark_path`; set `network_interface`; grant passwordless sudo (macOS/Linux). |
| `Passwordless sudo is not available` warning | Grant it as in step 2 of "Adding a runner" in the README, pick an option under "Without passwordless sudo", or set `use_sudo: false` to accept skipping the network tracking benchmarks. |
| `Permission denied` under `_work/_nwb_benchmarks` | Leftovers from an interrupted sudo run: `sudo chown -R "$(id -un)" <runner>/_work/_nwb_benchmarks`. |
| `No such file or directory: 'gcc'` / `Failed to build numcodecs` during `conda env create` | A package in the upstream environment file has no prebuilt wheel for the Python version it pins, so pip compiles it and finds no C compiler. On Linux, re-run **Set up runner**, which installs conda-forge's GCC under `_work` when the machine has none; on macOS run `xcode-select --install` once on the machine. If the compile itself fails, fix the pins in `environments/nwb_benchmarks.yaml` upstream. The **Set up runner** summary shows which compiler the jobs use. |
| `conda env create` fails | Check free disk space and `conda clean --all`; the environment file pins Python and uses `pip` for most packages, so network access to PyPI is required. |
