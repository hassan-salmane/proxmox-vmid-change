#!/bin/bash
#
# proxmox-vmid-change.sh
# ------------------------------------------------------------------
# Change the ID of a QEMU VM or LXC container on Proxmox VE, whether
# running in a cluster or standalone, by renaming every related
# component (storage, config, firewall, HA, replication).
#
# Author : Hassan SALMANE
# Usage  : ./proxmox-vmid-change.sh <old_vmid> <new_vmid> [--apply]
#
#   Without --apply : DRY-RUN mode (default). Shows everything that
#                      would be done, changes nothing.
#   With --apply    : actually performs the operations.
#
# ------------------------------------------------------------------

set -euo pipefail

# ==================== CONFIG ====================
SCRIPT_NAME="$(basename "$0")"
LOGDIR="/var/log/proxmox-vmid-change"
LOGFILE="${LOGDIR}/vmid-change-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=true
OLD_VMID=""
NEW_VMID=""
GUEST_TYPE=""        # "qemu" or "lxc"
GUEST_NAME=""        # VM/CT name (shown in the confirmation prompt)
OLD_NODE=""          # node actually hosting OLD_VMID
IS_CLUSTER=false
LOCAL_NODE=""
CONF_PATH=""
CONF_BACKUP=""
declare -a ROLLBACK_ACTIONS=()   # stack of actions to replay on failure

# ==================== COLORS (display) ====================
C_RESET="\033[0m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_CYAN="\033[36m"
C_BOLD="\033[1m"

# ==================== LOGGING ====================
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local color="$C_RESET"
    case "$level" in
        INFO)  color="$C_CYAN" ;;
        OK)    color="$C_GREEN" ;;
        WARN)  color="$C_YELLOW" ;;
        ERROR) color="$C_RED" ;;
        DRY)   color="$C_YELLOW" ;;
    esac
    echo -e "${color}[$ts] [$level] ${msg}${C_RESET}"
    # File logging only if LOGDIR is writable (root)
    if [[ -w "$LOGDIR" ]] 2>/dev/null; then
        echo "[$ts] [$level] $msg" >> "$LOGFILE"
    fi
}

die() {
    log ERROR "$*"
    log ERROR "Aborting script."
    exit 1
}

run_action() {
    # run_action <description> <command...>
    # Dry-run: just prints. Apply mode: runs it and logs the result.
    local desc="$1"; shift
    if $DRY_RUN; then
        log DRY "[DRY-RUN] $desc"
        log DRY "         -> command: $*"
    else
        log INFO "$desc"
        if "$@"; then
            log OK "  -> OK"
        else
            log ERROR "  -> FAILED on: $*"
            return 1
        fi
    fi
}

# run_action_rb <description> <rollback_cmd_as_string> <command...>
# Variant of run_action that pushes an undo command (as a string,
# executed via `bash -c`) onto the stack every time it actually
# succeeds. If a later step fails, ROLLBACK_ACTIONS is replayed in
# reverse order (LIFO) by trigger_rollback().
run_action_rb() {
    local desc="$1"; local rollback_cmd="$2"; shift 2
    if $DRY_RUN; then
        log DRY "[DRY-RUN] $desc"
        log DRY "         -> command: $*"
        log DRY "         -> planned rollback: $rollback_cmd"
    else
        log INFO "$desc"
        if "$@"; then
            log OK "  -> OK"
            ROLLBACK_ACTIONS+=("$rollback_cmd")
        else
            log ERROR "  -> FAILED on: $*"
            return 1
        fi
    fi
}

# Replays the rollback stack in reverse order (last successful action
# undone first). Each entry is a full shell command, executed as-is
# via bash -c.
trigger_rollback() {
    local count="${#ROLLBACK_ACTIONS[@]}"
    if [[ "$count" -eq 0 ]]; then
        log WARN "Nothing to roll back (no action had succeeded yet)."
        return
    fi

    echo
    log ERROR "========================================================"
    log ERROR "  FAILURE detected -- triggering automatic ROLLBACK"
    log ERROR "  ($count action(s) to undo, in reverse order)"
    log ERROR "========================================================"

    local i
    for (( i=count-1; i>=0; i-- )); do
        local cmd="${ROLLBACK_ACTIONS[$i]}"
        log WARN "Rollback [$((i+1))/$count]: $cmd"
        if bash -c "$cmd"; then
            log OK "  -> Rollback OK"
        else
            log ERROR "  -> ROLLBACK FAILED for this action! Manual intervention required: $cmd"
        fi
    done

    echo
    log ERROR "Rollback finished. Manually check the state of VM/CT $OLD_VMID before retrying."
    if [[ -n "$CONF_BACKUP" && -f "$CONF_BACKUP" ]]; then
        log INFO "Original .conf backup available at: $CONF_BACKUP"
    fi
}

# ==================== USAGE ====================
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME <old_vmid> <new_vmid> [--apply]

  <old_vmid>   Current ID of the VM/CT to rename
  <new_vmid>   Target ID (must be free across the whole cluster)
  --apply      Actually perform the changes (otherwise dry-run)

Examples:
  $SCRIPT_NAME 105 205                # dry-run, no changes made
  $SCRIPT_NAME 105 205 --apply        # real execution

EOF
    exit 1
}

# ==================== ARGUMENT PARSING ====================
parse_args() {
    [[ $# -lt 2 ]] && usage

    OLD_VMID="$1"
    NEW_VMID="$2"
    shift 2 || true

    for arg in "$@"; do
        case "$arg" in
            --apply) DRY_RUN=false ;;
            *) die "Unknown argument: $arg" ;;
        esac
    done

    [[ "$OLD_VMID" =~ ^[0-9]+$ ]] || die "old_vmid must be numeric (got: $OLD_VMID)"
    [[ "$NEW_VMID" =~ ^[0-9]+$ ]] || die "new_vmid must be numeric (got: $NEW_VMID)"
    [[ "$OLD_VMID" == "$NEW_VMID" ]] && die "old_vmid and new_vmid are identical ($OLD_VMID)"
    [[ "$NEW_VMID" -ge 100 ]] || die "new_vmid must be >= 100 (Proxmox constraint)"
}

# ==================== PREREQUISITES ====================
check_prerequisites() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (on a PVE node)."
    command -v qm  >/dev/null 2>&1 || die "'qm' command not found -- not a PVE node?"
    command -v pct >/dev/null 2>&1 || die "'pct' command not found -- not a PVE node?"
    command -v pvesh >/dev/null 2>&1 || die "'pvesh' command not found."

    mkdir -p "$LOGDIR" 2>/dev/null || log WARN "Could not create $LOGDIR, file logging disabled."

    LOCAL_NODE="$(hostname)"

    if pvecm status >/dev/null 2>&1; then
        IS_CLUSTER=true
        log INFO "Detected context: CLUSTER (local node: $LOCAL_NODE)"
    else
        IS_CLUSTER=false
        log INFO "Detected context: STANDALONE (node: $LOCAL_NODE)"
    fi
}

# ==================== GUEST TYPE DETECTION (QEMU / LXC) ====================
# The real cluster-wide pmxcfs path is /etc/pve/nodes/<node>/qemu-server/
# or /etc/pve/nodes/<node>/lxc/. The shortcut /etc/pve/qemu-server/ is only
# a LOCAL symlink to nodes/<current_local_node>/qemu-server/ -- it only
# shows guests belonging to the node the script is running on.
# To find a VMID regardless of its node, we must query /cluster/resources
# to learn the node, THEN read directly under /etc/pve/nodes/<found_node>/.

# Cluster-wide detection: returns "type|node" (e.g. "qemu|CIOB-PVE3")
detect_guest_type_cluster() {
    local vmid="$1"
    local json
    json="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)" || {
        echo ""
        return
    }

    local block
    block="$(echo "$json" | tr '{' '\n' | grep -E "\"vmid\":${vmid}([,}]|$)")"
    [[ -z "$block" ]] && { echo ""; return; }

    local rtype rnode
    rtype="$(echo "$block" | grep -o '"type":"[^"]*"' | head -1 | cut -d'"' -f4)"
    rnode="$(echo "$block" | grep -o '"node":"[^"]*"' | head -1 | cut -d'"' -f4)"

    [[ -z "$rtype" || -z "$rnode" ]] && { echo ""; return; }

    echo "${rtype}|${rnode}"
}

# Builds the real .conf path, given the type and the node
build_conf_path() {
    local vmid="$1" type="$2" node="$3"
    if [[ "$type" == "qemu" ]]; then
        echo "/etc/pve/nodes/${node}/qemu-server/${vmid}.conf"
    else
        echo "/etc/pve/nodes/${node}/lxc/${vmid}.conf"
    fi
}

# ==================== EXISTENCE / AVAILABILITY CHECKS ====================
check_old_vmid_exists() {
    local result
    result="$(detect_guest_type_cluster "$OLD_VMID")"
    [[ -z "$result" ]] && die "VM ID $OLD_VMID not found anywhere in the cluster (neither QEMU nor LXC)."

    GUEST_TYPE="${result%%|*}"
    OLD_NODE="${result##*|}"

    CONF_PATH="$(build_conf_path "$OLD_VMID" "$GUEST_TYPE" "$OLD_NODE")"

    [[ -f "$CONF_PATH" ]] || die "Expected .conf file not found: $CONF_PATH (mismatch between the cluster API and pmxcfs, check systemctl status pve-cluster)."

    log OK "VM ID $OLD_VMID found -- type: $GUEST_TYPE, hosting node: $OLD_NODE"
    log INFO "Config path: $CONF_PATH"

    GUEST_NAME="$(grep -E '^name:' "$CONF_PATH" 2>/dev/null | cut -d' ' -f2-)"
    [[ -z "$GUEST_NAME" ]] && GUEST_NAME="(no name / CT hostname)"

    if [[ "$OLD_NODE" != "$LOCAL_NODE" ]]; then
        log WARN "The VM/CT lives on '$OLD_NODE', script running from '$LOCAL_NODE'."
        log WARN "  -> Reading/writing the .conf: OK (shared pmxcfs)."
        log WARN "  -> Renaming LOCAL storage (LVM/dir): will only work if this node ($LOCAL_NODE) has access to the volume."
        log WARN "  -> For local LVM or local dir storage, prefer running this script directly from '$OLD_NODE' (ssh root@$OLD_NODE)."
    fi
}

check_guest_stopped() {
    local status=""
    if [[ "$GUEST_TYPE" == "qemu" ]]; then
        status="$(qm status "$OLD_VMID" 2>/dev/null | awk '{print $2}')" || true
    else
        status="$(pct status "$OLD_VMID" 2>/dev/null | awk '{print $2}')" || true
    fi

    # qm status / pct status only reliably work when run on the hosting
    # node (they query local runtime state, not just pmxcfs). If empty
    # (VM on another node), fall back to the cluster API, which reports
    # the status known cluster-wide.
    if [[ -z "$status" ]]; then
        log INFO "Status not readable locally (VM on another node), checking via cluster API..."
        local json
        json="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)" || true
        local block
        block="$(echo "$json" | tr '{' '\n' | grep -E "\"vmid\":${OLD_VMID}([,}]|$)")"
        status="$(echo "$block" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)"
    fi

    [[ -n "$status" ]] || die "Could not determine the status of $OLD_VMID (neither locally nor via the cluster API)."
    [[ "$status" == "stopped" ]] || die "VM/CT $OLD_VMID is not stopped (status: $status). Stop it before continuing."
    log OK "VM/CT $OLD_VMID is stopped (status: $status)."
}

check_new_vmid_available() {
    local result
    result="$(detect_guest_type_cluster "$NEW_VMID")"
    if [[ -n "$result" ]]; then
        local existing_node="${result##*|}"
        die "VM ID $NEW_VMID is already in use on the cluster (node: $existing_node)."
    fi
    log OK "VM ID $NEW_VMID is free across the whole cluster."
}

# ==================== STORAGE BACKEND DETECTION ====================
# Returns the storage type (lvmthin, lvm, rbd, zfspool, dir, nfs, ...)
# for a given storage name, by reading /etc/pve/storage.cfg
get_storage_type() {
    local storage_name="$1"
    awk -v st="$storage_name" '
        /^[a-z]+:/ {
            split($0, a, ":")
            current_type = a[1]
            current_name = a[2]
            gsub(/^[ \t]+|[ \t]+$/, "", current_name)
        }
        current_name == st && /^[a-z]+:/ { print current_type; exit }
    ' /etc/pve/storage.cfg
}

# Parses the .conf and returns the relevant disk lines
# Line format returned: "<key> <storage> <volname> <remaining_options>"
# QEMU example: "scsi0 local-lvm vm-105-disk-0 size=32G"
# LXC example : "rootfs local-lvm vm-105-disk-0 size=8G"
extract_disk_lines() {
    local conf="$1"
    local type="$2"
    if [[ "$type" == "qemu" ]]; then
        grep -E '^(scsi|virtio|sata|ide)[0-9]+:' "$conf" || true
    else
        grep -E '^(rootfs|mp[0-9]+):' "$conf" || true
    fi
}

# ==================== DISK INVENTORY ====================
# Fills the global DISK_INVENTORY array with lines
# "key|storage|volname|storage_type|remaining_options"
declare -a DISK_INVENTORY=()

build_disk_inventory() {
    DISK_INVENTORY=()
    local lines
    lines="$(extract_disk_lines "$CONF_PATH" "$GUEST_TYPE")"
    [[ -z "$lines" ]] && { log WARN "No disk found in $CONF_PATH"; return; }

    while IFS= read -r line; do
        local key="${line%%:*}"
        local value="${line#*:}"
        value="${value# }"

        local storage="${value%%:*}"
        local remainder="${value#*:}"
        local volname="${remainder%%,*}"
        local options=""
        [[ "$remainder" == *,* ]] && options="${remainder#*,}"

        local stype
        stype="$(get_storage_type "$storage")"
        [[ -z "$stype" ]] && stype="unknown"

        # Warn if this is local storage (LVM/dir) potentially tied to a
        # specific node. Ceph RBD and NFS are shared, so they're fine
        # from any node.
        if [[ "$stype" == "lvm" || "$stype" == "lvmthin" || "$stype" == "dir" ]]; then
            local storage_nodes
            storage_nodes="$(awk -v st="$storage" '
                /^[a-z]+:/ { split($0,a,":"); name=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",name); innode=0 }
                name==st { innode=1 }
                innode && /nodes/ { print $2 }
            ' /etc/pve/storage.cfg)"
            if [[ -n "$storage_nodes" ]] && [[ "$storage_nodes" != *"$LOCAL_NODE"* ]]; then
                log WARN "Storage '$storage' (type: $stype) appears restricted to nodes [$storage_nodes] and does not include '$LOCAL_NODE'."
                log WARN "  -> Renaming this disk must be run from a listed node, otherwise the rename will fail (LV/file not found locally)."
            fi
        fi

        DISK_INVENTORY+=("${key}|${storage}|${volname}|${stype}|${options}")
        log INFO "Disk found: $key -> storage=$storage type=$stype volname=$volname"
    done <<< "$lines"
}

# ==================== LOCAL STORAGE VS NODE GUARD ====================
# For LVM/LVM-thin/dir/ZFS (not shared like Ceph/NFS), the rename
# operation MUST run on the node that physically owns the volume. If
# that's not the current node, block before any --apply to avoid a
# silently failed lvrename/mv, or worse, one run against the wrong
# local VG (the name "pve" potentially exists on every node).
check_local_storage_node_match() {
    local blocking_found=false

    for entry in "${DISK_INVENTORY[@]}"; do
        IFS='|' read -r key storage old_vol stype options <<< "$entry"
        [[ "$old_vol" != *"vm-${OLD_VMID}-"* ]] && continue

        case "$stype" in
            lvm|lvmthin|dir|zfspool)
                # Storage potentially local to a specific node.
                # Check whether it's restricted via "nodes:" in storage.cfg.
                local storage_nodes
                storage_nodes="$(awk -v st="$storage" '
                    /^[a-z]+:/ { split($0,a,":"); name=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",name); innode=0 }
                    name==st { innode=1 }
                    innode && /nodes/ { print $2 }
                ' /etc/pve/storage.cfg)"

                if [[ -n "$storage_nodes" ]]; then
                    # storage.cfg explicitly declares the allowed nodes
                    if [[ "$storage_nodes" != *"$LOCAL_NODE"* ]]; then
                        log ERROR "Disk '$key' ($storage, type: $stype) is restricted to nodes [$storage_nodes] -- '$LOCAL_NODE' is not one of them."
                        blocking_found=true
                    fi
                elif [[ "$OLD_NODE" != "$LOCAL_NODE" ]]; then
                    # No explicit restriction, but this is inherently local
                    # storage (LVM/dir/ZFS without an explicit "shared"
                    # flag) and the VM lives on another node: typical case
                    # of a storage.cfg without "nodes:" that is actually
                    # local in practice.
                    log ERROR "Disk '$key' ($storage, type: $stype) is local storage, and the VM/CT lives on '$OLD_NODE' (not the current node '$LOCAL_NODE')."
                    blocking_found=true
                fi
                ;;
            rbd|nfs|cifs)
                # Cluster-wide shared storage, no node issue.
                ;;
        esac
    done

    if $blocking_found; then
        echo
        die "One or more disks are on LOCAL storage not accessible from '$LOCAL_NODE'. Re-run this script directly from '$OLD_NODE' (e.g. ssh root@$OLD_NODE) to safely rename the storage."
    fi
}

# ==================== STORAGE RENAME BY TYPE ====================
# Builds the new volname by replacing the old VMID with the new one
# e.g. vm-105-disk-0 -> vm-205-disk-0
new_volname_for() {
    local old_volname="$1"
    echo "${old_volname//vm-${OLD_VMID}-/vm-${NEW_VMID}-}"
}

rename_disk_lvm() {
    # LVM / LVM-thin: lvrename <vg> <old_lv> <new_lv>
    local storage="$1" old_vol="$2" new_vol="$3"
    local vg
    vg="$(awk -v st="$storage" '
        /^[a-z]+:/ { split($0,a,":"); name=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",name) }
        name==st && /vgname/ { print $2 }
    ' /etc/pve/storage.cfg)"
    [[ -z "$vg" ]] && vg="pve"   # sane default fallback

    # Check for LVM snapshots tied to this LV before renaming.
    # lvrename only renames the target LV; an existing LVM snapshot (an
    # LV of type "snapshot" whose origin is this LV) keeps its own name,
    # but its "origin" relation is updated automatically by LVM itself.
    # We just inform the user of their presence.
    local snap_list
    snap_list="$(lvs --noheadings -o lv_name,origin "$vg" 2>/dev/null | awk -v ov="$old_vol" '$2==ov {print $1}' || true)"
    if [[ -n "$snap_list" ]]; then
        log WARN "LV ${vg}/${old_vol} has dependent LVM snapshot(s):"
        echo "$snap_list" | while read -r s; do
            log WARN "    ${vg}/${s} (origin: ${old_vol})"
        done
        log WARN "  -> 'lvrename' automatically updates the 'origin' reference of LVM snapshots (native LVM behavior, no extra action needed)."
    else
        log INFO "No LVM snapshot found on ${vg}/${old_vol}."
    fi

    run_action_rb "Rename LVM: ${vg}/${old_vol} -> ${vg}/${new_vol}" \
        "lvrename '${vg}' '${new_vol}' '${old_vol}'" \
        lvrename "$vg" "$old_vol" "$new_vol"
}

rename_disk_rbd() {
    # Ceph RBD: rbd mv <pool>/<old> <pool>/<new>
    local storage="$1" old_vol="$2" new_vol="$3"
    local pool
    pool="$(awk -v st="$storage" '
        /^[a-z]+:/ { split($0,a,":"); name=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",name) }
        name==st && /pool/ { print $2 }
    ' /etc/pve/storage.cfg)"
    [[ -z "$pool" ]] && pool="rbd"

    # Check for RBD snapshots on this volume before renaming.
    # rbd mv/rename moves the image AND its snapshots together (they're
    # tied to the image, not its name), so the operation stays safe.
    # Still, we explicitly inform the user of their presence because:
    #  - an in-use snapshot (e.g. an active clone) can block the rename
    #    with an explicit Ceph error
    #  - it's useful information to have before acting on a prod disk
    local snap_list
    snap_list="$(rbd snap ls "${pool}/${old_vol}" 2>/dev/null | tail -n +2 || true)"
    if [[ -n "$snap_list" ]]; then
        local snap_count
        snap_count="$(echo "$snap_list" | wc -l)"
        log WARN "Volume ${pool}/${old_vol} has ${snap_count} RBD snapshot(s):"
        echo "$snap_list" | while read -r line; do
            log WARN "    $line"
        done
        log WARN "  -> 'rbd mv' moves the image AND its snapshots together (no separate action required)."
        log WARN "  -> If an active clone depends on one of these snapshots (protected snapshot), the rename may fail."

        # Specific check for "protected" snapshots (used by a clone)
        local protected_snaps
        protected_snaps="$(rbd snap ls "${pool}/${old_vol}" --all 2>/dev/null | grep -i "yes" || true)"
        if [[ -n "$protected_snaps" ]]; then
            log WARN "  -> At least one snapshot is PROTECTED (likely used by a clone):"
            log WARN "    $protected_snaps"
            log WARN "  -> The rename should still work (rbd mv handles protected snapshots), but check that no external clone references this volume by its old explicit name."
        fi
    else
        log INFO "No RBD snapshot found on ${pool}/${old_vol}."
    fi

    run_action_rb "Rename RBD: ${pool}/${old_vol} -> ${pool}/${new_vol}" \
        "rbd mv '${pool}/${new_vol}' '${pool}/${old_vol}'" \
        rbd mv "${pool}/${old_vol}" "${pool}/${new_vol}"
}

rename_disk_zfs() {
    # ZFS: zfs rename <pool>/<old> <pool>/<new>
    local storage="$1" old_vol="$2" new_vol="$3"
    local zpool
    zpool="$(awk -v st="$storage" '
        /^[a-z]+:/ { split($0,a,":"); name=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",name) }
        name==st && /pool/ { print $2 }
    ' /etc/pve/storage.cfg)"
    [[ -z "$zpool" ]] && die "Could not determine the zpool for storage $storage"

    # ZFS: snapshots are children of the dataset (pool/vol@snapname).
    # 'zfs rename' moves the dataset AND all its snapshots automatically
    # (native ZFS behavior). Just listed here for information/traceability.
    local snap_list
    snap_list="$(zfs list -t snapshot -o name -H 2>/dev/null | grep "^${zpool}/${old_vol}@" || true)"
    if [[ -n "$snap_list" ]]; then
        local snap_count
        snap_count="$(echo "$snap_list" | wc -l)"
        log WARN "Dataset ${zpool}/${old_vol} has ${snap_count} ZFS snapshot(s):"
        echo "$snap_list" | while read -r s; do
            log WARN "    $s"
        done
        log WARN "  -> 'zfs rename' moves the dataset AND its snapshots together (no separate action required)."
    else
        log INFO "No ZFS snapshot found on ${zpool}/${old_vol}."
    fi

    run_action_rb "Rename ZFS: ${zpool}/${old_vol} -> ${zpool}/${new_vol}" \
        "zfs rename '${zpool}/${new_vol}' '${zpool}/${old_vol}'" \
        zfs rename "${zpool}/${old_vol}" "${zpool}/${new_vol}"
}

rename_disk_dir() {
    # dir / nfs: qcow2/raw files under <path>/<vmid>/<volname>
    local storage="$1" old_vol="$2" new_vol="$3"
    local base_path
    base_path="$(awk -v st="$storage" '
        /^[a-z]+:/ { split($0,a,":"); name=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",name) }
        name==st && /path/ { print $2 }
    ' /etc/pve/storage.cfg)"
    [[ -z "$base_path" ]] && die "Could not determine the path for storage $storage"

    local old_dir="${base_path}/images/${OLD_VMID}"
    local new_dir="${base_path}/images/${NEW_VMID}"

    run_action "Creating target directory: $new_dir" mkdir -p "$new_dir"
    run_action_rb "Moving file: ${old_dir}/${old_vol} -> ${new_dir}/${new_vol}" \
        "mv '${new_dir}/${new_vol}' '${old_dir}/${old_vol}'" \
        mv "${old_dir}/${old_vol}" "${new_dir}/${new_vol}"
}

# Dispatch based on the detected type
rename_disk_by_type() {
    local storage="$1" old_vol="$2" new_vol="$3" stype="$4"
    case "$stype" in
        lvm|lvmthin)      rename_disk_lvm  "$storage" "$old_vol" "$new_vol" ;;
        rbd)              rename_disk_rbd  "$storage" "$old_vol" "$new_vol" ;;
        zfspool)          rename_disk_zfs  "$storage" "$old_vol" "$new_vol" ;;
        dir|nfs|cifs)     rename_disk_dir  "$storage" "$old_vol" "$new_vol" ;;
        *)
            log WARN "Storage type '$stype' not handled automatically for $storage:$old_vol"
            log WARN "  -> Manual rename required for this disk."
            ;;
    esac
}

rename_all_disks() {
    for entry in "${DISK_INVENTORY[@]}"; do
        IFS='|' read -r key storage old_vol stype options <<< "$entry"
        # ISO / cloudinit / non-VM-owned volumes: leave untouched (e.g.
        # no vm-<id>- in the name)
        if [[ "$old_vol" != *"vm-${OLD_VMID}-"* ]]; then
            log WARN "Disk $key ($old_vol) does not match the vm-${OLD_VMID}-* pattern, skipped (probably a shared ISO/template)."
            continue
        fi
        local new_vol
        new_vol="$(new_volname_for "$old_vol")"
        rename_disk_by_type "$storage" "$old_vol" "$new_vol" "$stype"
    done
}

# ==================== .CONF FILE UPDATE ====================
update_conf_file() {
    local new_conf
    new_conf="$(build_conf_path "$NEW_VMID" "$GUEST_TYPE" "$OLD_NODE")"

    CONF_BACKUP="/tmp/${OLD_VMID}.conf.bak.$(date +%s)"
    run_action "Safety backup: $CONF_PATH -> $CONF_BACKUP" \
        cp "$CONF_PATH" "$CONF_BACKUP"

    if $DRY_RUN; then
        log DRY "[DRY-RUN] Replacing references vm-${OLD_VMID}- -> vm-${NEW_VMID}- in the conf content"
        log DRY "[DRY-RUN] Renaming file: $CONF_PATH -> $new_conf"
        return
    fi

    sed -i "s/vm-${OLD_VMID}-/vm-${NEW_VMID}-/g" "$CONF_PATH"
    sed -i "s#/${OLD_VMID}/#/${NEW_VMID}/#g" "$CONF_PATH"

    mv "$CONF_PATH" "$new_conf"
    log OK "Config file renamed and updated: $new_conf"

    # Rollback: delete the new conf and restore the original from the backup
    ROLLBACK_ACTIONS+=("rm -f '${new_conf}' && cp '${CONF_BACKUP}' '${CONF_PATH}'")

    CONF_PATH="$new_conf"
}

# ==================== PER-VM FIREWALL ====================
update_firewall_conf() {
    local old_fw="/etc/pve/firewall/${OLD_VMID}.fw"
    local new_fw="/etc/pve/firewall/${NEW_VMID}.fw"
    if [[ -f "$old_fw" ]]; then
        run_action_rb "Rename firewall conf: $old_fw -> $new_fw" \
            "mv '${new_fw}' '${old_fw}'" \
            mv "$old_fw" "$new_fw"
    else
        log INFO "No dedicated firewall rules for $OLD_VMID, nothing to do."
    fi
}

# ==================== HA MANAGER ====================
update_ha_resources() {
    local ha_res
    ha_res="$(pvesh get /cluster/ha/resources --output-format json 2>/dev/null \
              | grep -o "\"sid\":\"vm:${OLD_VMID}\"" || true)"
    if [[ -n "$ha_res" ]]; then
        log WARN "VM $OLD_VMID is managed by the HA manager."
        if $DRY_RUN; then
            log DRY "[DRY-RUN] Removing HA resource vm:${OLD_VMID}, then recreating vm:${NEW_VMID}"
        else
            run_action "Removing HA resource vm:${OLD_VMID}" \
                pvesh delete "/cluster/ha/resources/vm:${OLD_VMID}"
            run_action "Creating HA resource vm:${NEW_VMID}" \
                pvesh create "/cluster/ha/resources" -sid "vm:${NEW_VMID}"
        fi
    else
        log INFO "No HA resource associated with $OLD_VMID."
    fi
}

# ==================== REPLICATION (pvesr) ====================
update_replication_jobs() {
    local repl_jobs
    repl_jobs="$(pvesh get /cluster/replication --output-format json 2>/dev/null \
                 | grep -o "\"id\":\"${OLD_VMID}-[0-9]*\"" || true)"
    if [[ -n "$repl_jobs" ]]; then
        log WARN "Replication job(s) exist for $OLD_VMID."
        log WARN "  -> Must be handled manually: pvesr does not support renaming a VMID directly,"
        log WARN "    you'll need to recreate the replication job for $NEW_VMID afterwards (pvesr create-local-job)."
    else
        log INFO "No replication job for $OLD_VMID."
    fi
}

# ==================== INTERACTIVE CONFIRMATION ====================
confirm_apply() {
    $DRY_RUN && return   # no confirmation needed in dry-run mode

    echo
    log WARN "========================================================"
    log WARN "  WARNING: --apply mode is active, changes will be REAL."
    log WARN "========================================================"
    log WARN "  VM/CT           : $OLD_VMID ($GUEST_NAME)"
    log WARN "  New ID          : $NEW_VMID"
    log WARN "  Running from    : $LOCAL_NODE"
    log WARN "  Hosting node    : $OLD_NODE"
    log WARN "  Disks affected  : ${#DISK_INVENTORY[@]}"
    echo
    read -r -p "Proceed with renaming $OLD_VMID -> $NEW_VMID? (y/N) " reply
    case "$reply" in
        [yY]|[yY][eE][sS])
            log OK "Confirmed, proceeding with the real execution."
            ;;
        *)
            log INFO "Not confirmed, cleanly aborting. No changes were made."
            exit 0
            ;;
    esac
    echo
}

# ==================== FINAL SUMMARY ====================
final_summary() {
    echo
    log INFO "========================================"
    if $DRY_RUN; then
        log INFO "  DRY-RUN finished -- no changes applied."
        log INFO "  Re-run with --apply to actually execute."
    else
        log OK "  Migration $OLD_VMID -> $NEW_VMID complete."
        log INFO "  Original conf backup: $CONF_BACKUP"
        log INFO "  Verify with: qm config $NEW_VMID --node $OLD_NODE   (or pct config $NEW_VMID --node $OLD_NODE)"
        log INFO "  Remember to manually check: existing PBS backup jobs (remain under the old ID),"
        log INFO "  any replication jobs, and test starting the VM/CT."
    fi
    log INFO "========================================"
}

# ==================== MAIN ====================
main() {
    parse_args "$@"
    check_prerequisites

    log INFO "=== Changing VM ID: $OLD_VMID -> $NEW_VMID ==="
    $DRY_RUN && log WARN "DRY-RUN mode active (no real changes). Use --apply to actually execute."

    check_old_vmid_exists
    check_guest_stopped
    check_new_vmid_available

    build_disk_inventory

    if ! $DRY_RUN; then
        log INFO "--- Local storage / node guard check ---"
        check_local_storage_node_match
        log OK "All storages are accessible from this node ($LOCAL_NODE), proceeding."
    fi

    confirm_apply

    # The trap is only armed from here, once all preliminary checks
    # have passed: from this point on, any command that fails (thanks
    # to set -e) automatically triggers the full rollback.
    if ! $DRY_RUN; then
        trap 'trigger_rollback; exit 1' ERR
    fi

    log INFO "--- Step 1/5: Renaming storage ---"
    rename_all_disks

    log INFO "--- Step 2/5: Updating the config file ---"
    update_conf_file

    log INFO "--- Step 3/5: Firewall rules ---"
    update_firewall_conf

    log INFO "--- Step 4/5: HA resources ---"
    update_ha_resources

    log INFO "--- Step 5/5: Replication jobs ---"
    update_replication_jobs

    trap - ERR   # full success, disarm the trap

    final_summary
}

main "$@"
