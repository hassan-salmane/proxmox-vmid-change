# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-07-07

### Added
- Initial public release.
- Cluster-wide guest detection via `/cluster/resources` — locates the hosting node regardless of which node the script runs from.
- Automatic storage backend detection (LVM, LVM-thin, Ceph RBD, ZFS, dir/NFS) by parsing `/etc/pve/storage.cfg`.
- Snapshot detection before rename for RBD, LVM, and ZFS backends, including protected RBD snapshot detection.
- Local-storage-vs-node guard: blocks `--apply` execution if a disk sits on node-local storage unreachable from the current node.
- Dry-run mode by default; `--apply` required for real execution.
- Interactive `(y/N)` confirmation prompt before any real change.
- Automatic rollback: on failure mid-run, every already-completed action is undone in reverse order (LIFO).
- Support for both QEMU VMs and LXC containers.
- Firewall configuration (`.fw`) rename.
- HA resource migration.
- Replication job detection (flagged for manual recreation; not automated).

### Known limitations
- PBS backups remain under the original VMID (by design).
- Replication jobs are detected but must be recreated manually — the Proxmox API has no rename operation for `pvesr` jobs.
- Snapshot detection is not implemented for `dir`/NFS storage.
