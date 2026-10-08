# Development notes

## Where a job writes on the runner machine

Everything a job writes stays inside the runner's `_work` folder.
The first step of every job points `HOME` at `<runner>/_work/_nwb_benchmarks/home`, so the suite's `~/.nwb_benchmarks`, its download cache, `~/.asv-machine.json`, and conda's own files all land there; the conda installation and (on macOS) the Wireshark copy that provide the toolchain live next to it.
The runner user's real home directory is never touched.

### Layout of `_work/_nwb_benchmarks/`

The folder is a sibling of the runner's own `_temp` and `_tool` folders.

| Path under `_work/_nwb_benchmarks/` | Notes |
| --- | --- |
| `home/` | `HOME` for every job step. Holds `.nwb_benchmarks/{results,machines,environments,logs}` written by the suite, `.nwb_benchmarks/runner/pending/` (files waiting for upload; non-empty after a failed upload, the next run uploads them) and `.nwb_benchmarks/runner/uploaded/` (archive, safe to delete), the download cache `.cache/nwb_benchmarks/`, `.asv-machine.json`, and conda's `.conda/`. |
| `miniforge3/` | conda, installed by the Set up runner workflow; the only conda the jobs use unless `conda_root` says otherwise. Benchmark environments are created inside it and removed at the end of every job unless `keep_conda_env: true`. |
| `tools/Wireshark.app/` | macOS only: Wireshark copied by the Set up runner workflow; its `tshark` is used automatically. |

The clone of `nwb-benchmarks` lives in the job workspace (`_work/nwb-benchmarks-runner/.../nwb-benchmarks`) and is removed at the end of every job.
Result files stay owned by the runner's user even after a sudo run; the workflow restores ownership of the whole state directory itself.

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

## Repository checks

- Markdown in this repository keeps each sentence on its own line, the convention of
  [nwb-benchmarks-paper](https://github.com/NeurodataWithoutBorders/nwb-benchmarks-paper), from which the `.pre-commit-config.yaml` and the `sentence-per-line` hook are taken. A list item may hold several sentences on its line.
- Install [pre-commit](https://pre-commit.com) and run `pre-commit run --all-files` before pushing; the `pre-commit` workflow runs the same hooks on every pull request. The sentence hook rewrites files and reports a failure the first time so the changes can be reviewed; run it again to confirm.
- `lint.yml` additionally runs actionlint and shellcheck on the workflows and scripts.
