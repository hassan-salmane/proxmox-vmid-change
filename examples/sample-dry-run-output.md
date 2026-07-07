# Example output

Real dry-run output from a 3-node Proxmox cluster, renaming a QEMU VM backed by Ceph RBD storage from VMID 1061 to 1062. Node names and IPs have been anonymized.

```
$ ./proxmox-vmid-change.sh 1061 1062

[2026-07-07 12:23:31] [INFO] Detected context: CLUSTER (local node: pve1)
[2026-07-07 12:23:31] [INFO] === Changing VM ID: 1061 -> 1062 ===
[2026-07-07 12:23:31] [WARN] DRY-RUN mode active (no real changes). Use --apply to actually execute.
[2026-07-07 12:23:31] [OK] VM ID 1061 found -- type: qemu, hosting node: pve3
[2026-07-07 12:23:31] [INFO] Config path: /etc/pve/nodes/pve3/qemu-server/1061.conf
[2026-07-07 12:23:31] [WARN] The VM/CT lives on 'pve3', script running from 'pve1'.
[2026-07-07 12:23:31] [WARN]   -> Reading/writing the .conf: OK (shared pmxcfs).
[2026-07-07 12:23:31] [WARN]   -> Renaming LOCAL storage (LVM/dir): will only work if this node (pve1) has access to the volume.
[2026-07-07 12:23:31] [WARN]   -> For local LVM or local dir storage, prefer running this script directly from 'pve3' (ssh root@pve3).
[2026-07-07 12:23:32] [INFO] Status not readable locally (VM on another node), checking via cluster API...
[2026-07-07 12:23:33] [OK] VM/CT 1061 is stopped (status: stopped).
[2026-07-07 12:23:34] [OK] VM ID 1062 is free across the whole cluster.
[2026-07-07 12:23:34] [INFO] Disk found: ide2 -> storage=none,media=cdrom type=unknown volname=none
[2026-07-07 12:23:34] [INFO] Disk found: scsi0 -> storage=Ceph-Pool-HDD type=rbd volname=vm-1061-disk-0
[2026-07-07 12:23:34] [INFO] --- Step 1/5: Renaming storage ---
[2026-07-07 12:23:34] [WARN] Disk ide2 (none) does not match the vm-1061-* pattern, skipped (probably a shared ISO/template).
[2026-07-07 12:23:34] [INFO] No RBD snapshot found on Ceph-Pool-HDD/vm-1061-disk-0.
[2026-07-07 12:23:34] [DRY] [DRY-RUN] Rename RBD: Ceph-Pool-HDD/vm-1061-disk-0 -> Ceph-Pool-HDD/vm-1062-disk-0
[2026-07-07 12:23:34] [DRY]          -> command: rbd mv Ceph-Pool-HDD/vm-1061-disk-0 Ceph-Pool-HDD/vm-1062-disk-0
[2026-07-07 12:23:34] [INFO] --- Step 2/5: Updating the config file ---
[2026-07-07 12:23:34] [DRY] [DRY-RUN] Safety backup: /etc/pve/nodes/pve3/qemu-server/1061.conf -> /tmp/1061.conf.bak.1783423414
[2026-07-07 12:23:34] [DRY] [DRY-RUN] Replacing references vm-1061- -> vm-1062- in the conf content
[2026-07-07 12:23:34] [DRY] [DRY-RUN] Renaming file: /etc/pve/nodes/pve3/qemu-server/1061.conf -> /etc/pve/nodes/pve3/qemu-server/1062.conf
[2026-07-07 12:23:34] [INFO] --- Step 3/5: Firewall rules ---
[2026-07-07 12:23:34] [INFO] No dedicated firewall rules for 1061, nothing to do.
[2026-07-07 12:23:34] [INFO] --- Step 4/5: HA resources ---
[2026-07-07 12:23:35] [INFO] No HA resource associated with 1061.
[2026-07-07 12:23:35] [INFO] --- Step 5/5: Replication jobs ---
[2026-07-07 12:23:36] [INFO] No replication job for 1061.
[2026-07-07 12:23:36] [INFO] ========================================
[2026-07-07 12:23:36] [INFO]   DRY-RUN finished -- no changes applied.
[2026-07-07 12:23:36] [INFO]   Re-run with --apply to actually execute.
[2026-07-07 12:23:36] [INFO] ========================================
```

Note how the script:
- Correctly locates the guest on `pve3` even though it's running from `pve1`
- Warns that Ceph RBD is fine from any node, but flags what would need attention for local LVM/dir storage
- Skips the CD-ROM drive (`ide2`) since it doesn't belong to this guest
- Checks for RBD snapshots before proposing the rename
- Changes absolutely nothing in dry-run mode
