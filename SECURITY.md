# Security

What the workflows in this repository run, where, and with which privileges.

- Self-hosted runners on a public repository: only `schedule` and `workflow_dispatch` trigger jobs on them, and `workflow_dispatch` is limited to people with write access. Never add `pull_request` or `push` triggers to a workflow that uses `self-hosted`. The lint workflow runs on GitHub-hosted runners only.
- Passwordless `sudo` (or a root runner) gives the benchmark suite root on the machine. Use a dedicated user or machine, and keep the suite pinned to `main` of the upstream repository (the default) unless you are testing your own branch.
- One upload token, scoped to the results repository, is stored as the repository secret `RESULTS_UPLOAD_TOKEN`. Only the upload job references it, and that job runs on a GitHub-hosted runner, so the token never reaches a self-hosted machine; the benchmark job hands its result files over as a workflow artifact and reads the public results repository without a token. Each per-runner workflow passes the secret explicitly (no `secrets: inherit`). Rotate the token by replacing the secret; nothing on the machines has to change.
- The upload job treats the artifact as data: it only commits `*.json` files named like result, machine, or environment files, into their folders of the results repository, so a compromised runner can at most add bogus results or change a machine file.

To report a security problem with these workflows, open an issue in this repository or contact the maintainer directly.
