# Proxmox VMID Change

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)
![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-8.x-E57000?logo=proxmox&logoColor=white)
![Status: Stable](https://img.shields.io/badge/Status-Stable-brightgreen)

A Bash script to safely change the VMID of a QEMU virtual machine or LXC container on Proxmox VE — whether running standalone or as part of a cluster — by renaming every related component: storage volume, configuration file, firewall rules, HA resources, and replication job references.

Proxmox VE does not offer a native way to renumber a guest's VMID. The usual workaround — full clone, then delete the original — costs double the disk space temporarily, causes downtime, and can silently drop firewall rules or HA bindings. This script performs an in-place rename instead: no cloning, no wasted space, and every dependent component is either renamed automatically or explicitly flagged for manual follow-up.

## Features

- **Cluster-aware by design.** Works correctly whether you run it from the node hosting the guest or from any other node in the cluster — it queries `/cluster/resources` to locate the guest instead of assuming a local path.
- **Automatic storage backend detection.** Reads `/etc/pve/storage.cfg` to identify each disk's backend (LVM, LVM-thin, Ceph RBD, ZFS, dir/NFS) with no manual input required.
- **Snapshot-aware.** Detects existing snapshots (RBD, LVM, ZFS) before renaming and reports them, including protected RBD snapshots backing a clone.
- **Local-storage safety guard.** Refuses to run `--apply` if a disk lives on node-local storage (LVM, dir) that isn't reachable from the node the script is running on — preventing a silently failed `lvrename` or, worse, one executed against the wrong local volume group.
- **Dry-run by default.** Nothing is changed unless you explicitly pass `--apply`.
- **Interactive confirmation.** In `--apply` mode, a final `(y/N)` prompt summarizes exactly what's about to happen before anything is touched.
- **Automatic rollback.** If any step fails partway through a real run, every already-completed action is automatically undone in reverse order.
- **Handles both QEMU VMs and LXC containers.**

## Requirements

- Proxmox VE (tested on PVE 8.x), standalone or clustered
- Must be run as `root` on a PVE node
- Bash 4+ (uses associative arrays and `set -euo pipefail`)
- Standard PVE tooling already present on any node: `qm`, `pct`, `pvesh`, `pvecm`
- Depending on your storage backend: `lvrename` (LVM), `rbd` (Ceph), `zfs` (ZFS) — these are already present if you use the corresponding storage type

## Installation

```bash
curl -O https://raw.githubusercontent.com/<your-username>/proxmox-vmid-change/main/proxmox-vmid-change.sh
chmod +x proxmox-vmid-change.sh
```

Or clone the repo directly on a PVE node:

```bash
git clone https://github.com/<your-username>/proxmox-vmid-change.git
cd proxmox-vmid-change
chmod +x proxmox-vmid-change.sh
```

## Usage

```bash
./proxmox-vmid-change.sh <old_vmid> <new_vmid> [--apply]
```

| Argument | Description |
|---|---|
| `<old_vmid>` | Current ID of the VM/CT to rename |
| `<new_vmid>` | Target ID — must be free across the entire cluster |
| `--apply` | Actually perform the changes. Without it, the script runs in dry-run mode and changes nothing. |

### Examples

Dry-run — shows exactly what would happen, changes nothing:
```bash
./proxmox-vmid-change.sh 105 205
```

Real execution, with interactive confirmation:
```bash
./proxmox-vmid-change.sh 105 205 --apply
```

## What it actually does

1. Confirms `<old_vmid>` exists somewhere in the cluster and locates its hosting node via the Proxmox API (not just the local filesystem shortcut).
2. Verifies the guest is stopped.
3. Verifies `<new_vmid>` is free across the whole cluster.
4. Builds an inventory of the guest's disks and detects each one's storage backend.
5. **(apply mode only)** Runs a guard check: refuses to continue if any disk sits on node-local storage not reachable from the current node.
6. **(apply mode only)** Shows a summary and asks for confirmation.
7. Renames the storage volume(s) — `lvrename`, `rbd mv`, `zfs rename`, or a file move, depending on backend.
8. Updates and renames the guest's `.conf` file, rewriting internal volume references.
9. Renames the per-VM firewall configuration, if one exists.
10. Migrates HA resource bindings, if the guest is HA-managed.
11. Detects existing replication jobs and flags them for manual recreation (`pvesr` doesn't support renaming a job's target VMID directly).

If any step fails during a real (`--apply`) run, the script automatically rolls back everything that had already succeeded, in reverse order.

See [`examples/sample-dry-run-output.md`](examples/sample-dry-run-output.md) for a full annotated dry-run output from a real 3-node cluster.

## Known limitations

- **PBS backups are left under the old VMID on purpose.** Migrating existing Proxmox Backup Server archives to a new VMID is out of scope — it's higher-risk than it's worth for what this script targets. Your existing backup chain remains valid; new backups will use the new VMID going forward.
- **Replication jobs (`pvesr`) are detected but not migrated.** The Proxmox replication API has no "rename target" operation, so this has to be recreated manually after a successful migration.
- **`dir`/NFS storage snapshot detection is not implemented.** This backend doesn't expose snapshots the same way LVM/RBD/ZFS do in Proxmox (they're typically internal to the qcow2 file itself), so there's nothing separate to check.
- **Guest must be stopped.** This script does not support renaming a running VM/CT's ID — stop it first.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT — see [LICENSE](LICENSE).

## Author

**Hassan Salmane** — IT Infrastructure Engineer
[salmane.pro](https://salmane.pro) · [LinkedIn](https://linkedin.com/in/hassansalmane) · [GitHub](https://github.com/hassan-salmane)
