# Contributing to proxmox-vmid-change

Thanks for considering a contribution. This is a sysadmin utility script — the priority is correctness and safety over cleverness, since it operates on production infrastructure.

## Before opening a pull request

- **Test on a real Proxmox node.** This script cannot be meaningfully unit-tested outside a PVE environment — it shells out to `qm`, `pct`, `pvesh`, and storage-specific binaries (`lvrename`, `rbd`, `zfs`). Please confirm your change works against an actual test VM/CT before submitting.
- **Always test in dry-run mode first**, then with `--apply` against a disposable test guest — never against anything you can't afford to lose.
- **Keep `set -euo pipefail` semantics intact.** Any new function that can fail should either be wrapped through `run_action` / `run_action_rb`, or explicitly handle its own failure — a silent failure under `set -e` is the main class of bug this script guards against.
- **New storage backends** should follow the existing pattern: a dedicated `rename_disk_<type>()` function, snapshot detection before the rename, and a `run_action_rb` call with an explicit rollback command.
- **Keep everything in English.** Comments, log messages, error messages — the codebase is fully English for accessibility to the widest possible audience.

## Reporting a bug

Please include:
- Proxmox VE version (`pveversion`)
- Cluster or standalone
- Storage backend(s) involved
- Full script output (dry-run reproduction is fine if the bug doesn't require `--apply`)
- What you expected vs. what happened

## Reporting a security concern

If you find an issue that could cause data loss or unsafe behavior on a production cluster, please open an issue marked clearly as such rather than a silent PR — these deserve visible discussion before merge.

## Style

- Bash, `set -euo pipefail`, 4-space indentation.
- Functions are grouped by concern with `# ==================== SECTION ====================` banners — keep new code under the right one, or add a new banner if it's a genuinely new concern.
- Prefer explicit, readable `awk`/`grep`/`sed` over cleverness — this script is read under pressure, during an actual maintenance window, by someone who needs to trust what it's about to do.
