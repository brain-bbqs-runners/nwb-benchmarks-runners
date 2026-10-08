# Development notes

## Where a job writes on the runner machine

Everything a job writes stays inside the runner's `_work` folder.
The first step of every job points `HOME` at `<runner>/_work/_nwb_benchmarks/home`, so the suite's `~/.nwb_benchmarks`, its download cache, `~/.asv-machine.json`, and conda's own files all land there; the conda installation and (on macOS) the Wireshark copy that provide the toolchain live next to it.
The runner user's real home directory is never touched.

The full layout is in the README section "Files on the runner machine".

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
