# Security

What the workflows in this repository run, where, and with which privileges.

- Self-hosted runners on a public repository: only `schedule` and `workflow_dispatch` trigger jobs on them, and `workflow_dispatch` is limited to people with write access. Never add `pull_request` or `push` triggers to a workflow that uses `self-hosted`. The lint workflow runs on GitHub-hosted runners only.
- Passwordless sudo (or a root runner) gives the benchmark suite root on the machine. Use a dedicated user or machine, and keep the suite pinned to `main` of the upstream repository (the default) unless you are testing your own branch.
- Tokens are scoped to a single repository and stored only as repository secrets, one per runner. Each per-runner workflow passes its own secret explicitly (no `secrets: inherit`), so a machine never receives another runner's token. Rotate a token by replacing the secret; nothing on the machine has to change.

To report a security problem with these workflows, open an issue in this repository or contact the maintainer directly.
