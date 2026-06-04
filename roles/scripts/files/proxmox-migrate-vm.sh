#!/bin/bash
# =============================================================================
# Proxmox VM Migration Script
# Supports: file-based (qcow2/raw), LVM-thin, ZFS
# Modes: fresh migrate or disk-sync if VM already exists on target
# =============================================================================

set -uo pipefail

# --- Colours ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Helpers ------------------------------------------------------------------
info()      { echo -e "${CYAN}[INFO]${NC}  $*"; }
success()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()      { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { error "$*"; exit 1; }
separator() { echo -e "${BOLD}----------------------------------------------${NC}"; }

# --- Fixed remote account & local SSH identity --------------------------------
REMOTE_USER="migrate"
LOCAL_SSH_USER="migrate"          # local account that owns the SSH key
DEFAULT_SSH_KEY="/home/migrate/.ssh/id_ed25519"

# Remote execution: runs SSH as the local migrate user so key permissions are respected
remote() {
  su -s /bin/bash -c \
    "ssh -i '${SSH_KEY}' \
         -o BatchMode=yes \
         -o StrictHostKeyChecking=accept-new \
         -o ConnectTimeout=10 \
         '${REMOTE_USER}@${REMOTE_IP}' $(printf '%q' "$*")" \
    "${LOCAL_SSH_USER}"
}

# SCP: also runs as the migrate user
remote_scp() {
  local src="$1" dst="$2"
  su -s /bin/bash -c \
    "scp -i '${SSH_KEY}' \
          -o BatchMode=yes \
          -o StrictHostKeyChecking=accept-new \
          $(printf '%q' "$src") $(printf '%q' "$dst")" \
    "${LOCAL_SSH_USER}"
}

# --- Root check ---------------------------------------------------------------
[[ $EUID -ne 0 ]] && die "This script must be run as root (or via sudo)."

# --- Dependency check ---------------------------------------------------------
for cmd in qm pvesm ssh scp; do
  command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# =============================================================================
# STEP 1 — Collect inputs
# =============================================================================
separator
echo -e "${BOLD}  Proxmox VM Migration Tool${NC}"
separator

echo ""
read -rp "$(echo -e "${BOLD}Path to migrate user SSH key [default: ${DEFAULT_SSH_KEY}]:${NC} ")" SSH_KEY
SSH_KEY="${SSH_KEY:-$DEFAULT_SSH_KEY}"
[[ -f "$SSH_KEY" ]] || die "SSH key not found: ${SSH_KEY}"
chmod 600 "$SSH_KEY"
success "Using SSH key: ${SSH_KEY}"

echo ""
info "Available VMs on this node:"
qm list
echo ""

read -rp "$(echo -e "${BOLD}Enter the VM ID to migrate:${NC} ")" VMID
[[ "$VMID" =~ ^[0-9]+$ ]] || die "VM ID must be a number."
qm status "$VMID" &>/dev/null || die "VM $VMID does not exist on this node."

echo ""
read -rp "$(echo -e "${BOLD}Enter the IP address of the remote Proxmox node:${NC} ")" REMOTE_IP
[[ -z "$REMOTE_IP" ]] && die "Remote IP address cannot be empty."

# --- Test SSH -----------------------------------------------------------------
echo ""
info "Testing SSH connection as '${REMOTE_USER}' to ${REMOTE_IP}..."
SSH_TEST=$(su -s /bin/bash -c \
  "ssh -i '${SSH_KEY}' -o ConnectTimeout=10 -o BatchMode=yes \
   -o StrictHostKeyChecking=accept-new \
   '${REMOTE_USER}@${REMOTE_IP}' 'echo ok'" \
  "${LOCAL_SSH_USER}" 2>&1 || true)
if [[ "$SSH_TEST" != "ok" ]]; then
  error "SSH connection failed as '${REMOTE_USER}' to ${REMOTE_IP}."
  echo -e "  Authorise the key with:\n  ${BOLD}ssh-copy-id -i ${SSH_KEY}.pub ${REMOTE_USER}@${REMOTE_IP}${NC}"
  exit 1
fi
success "SSH connection established."

# --- List remote storage ------------------------------------------------------
echo ""
info "Available storage on remote node ${REMOTE_IP}:"
remote "pvesm status" 2>/dev/null || warn "Could not list remote storage — enter name manually."

echo ""
read -rp "$(echo -e "${BOLD}Enter the target storage name on the remote node:${NC} ")" TARGET_STORAGE
[[ -z "$TARGET_STORAGE" ]] && die "Target storage cannot be empty."

STORAGE_EXISTS=$(remote "pvesm status 2>/dev/null | awk 'NR>1 {print \$1}' | grep -w '${TARGET_STORAGE}'" || true)
if [[ -z "$STORAGE_EXISTS" ]]; then
  warn "Could not verify storage '${TARGET_STORAGE}' on remote."
  read -rp "$(echo -e "${YELLOW}Continue anyway? [y/N]:${NC} ")" CONT
  [[ "${CONT,,}" == "y" ]] || die "Aborted."
fi

# --- Detect target storage type on remote -------------------------------------
TARGET_STORAGE_TYPE=$(remote \
  "pvesm status 2>/dev/null | awk -v s='${TARGET_STORAGE}' '\$1==s{print \$2}'" || true)
info "Remote storage '${TARGET_STORAGE}' type: ${TARGET_STORAGE_TYPE:-unknown}"

# =============================================================================
# STEP 2 — Check if VM already exists on remote (sync vs fresh migrate)
# =============================================================================
separator
info "Checking if VM ${VMID} already exists on remote node..."

REMOTE_VM_EXISTS=$(remote "qm status ${VMID} 2>/dev/null && echo exists" || true)
OPERATION="migrate"   # default

if echo "$REMOTE_VM_EXISTS" | grep -q "exists"; then
  REMOTE_VM_STATUS=$(remote "qm status ${VMID} 2>/dev/null | awk '{print \$2}'" || echo "unknown")
  echo ""
  warn "VM ${VMID} already exists on remote node (status: ${REMOTE_VM_STATUS})."
  echo ""
  echo -e "  ${BOLD}Choose an action:${NC}"
  echo -e "  ${BOLD}1)${NC} Sync disks   — re-transfer disks to update the remote copy"
  echo -e "  ${BOLD}2)${NC} Abort        — exit without making any changes"
  echo ""
  read -rp "$(echo -e "${BOLD}Enter choice [1/2]:${NC} ")" VM_EXISTS_CHOICE
  case "$VM_EXISTS_CHOICE" in
    1) OPERATION="sync"
       success "Sync mode selected — disks will be re-transferred."
       if [[ "$REMOTE_VM_STATUS" != "stopped" ]]; then
         warn "Remote VM ${VMID} is ${REMOTE_VM_STATUS}. It must be stopped on the remote before syncing."
         read -rp "$(echo -e "${YELLOW}Attempt remote shutdown now? [y/N]:${NC} ")" RSHUTDOWN
         if [[ "${RSHUTDOWN,,}" == "y" ]]; then
           remote "qm shutdown ${VMID}"
           echo -n "  Waiting for remote VM to stop"
           for i in $(seq 1 60); do
             sleep 2
             REMOTE_VM_STATUS=$(remote "qm status ${VMID} 2>/dev/null | awk '{print \$2}'" || echo "unknown")
             [[ "$REMOTE_VM_STATUS" == "stopped" ]] && { echo ""; break; }
             echo -n "."
           done
           echo ""
           [[ "$REMOTE_VM_STATUS" != "stopped" ]] && die "Remote VM did not stop in time. Aborting."
           success "Remote VM stopped."
         else
           die "Aborted. Stop the remote VM before syncing."
         fi
       fi
       ;;
    *) die "Aborted by user." ;;
  esac
else
  success "VM ${VMID} does not exist on remote. Proceeding with fresh migration."
fi

# =============================================================================
# STEP 3 — Local VM status check
# =============================================================================
separator
info "Checking local VM ${VMID} status..."
VM_STATUS=$(qm status "$VMID" | awk '{print $2}')
echo -e "  VM ${BOLD}${VMID}${NC} current status: ${BOLD}${VM_STATUS}${NC}"

if [[ "$VM_STATUS" != "stopped" ]]; then
  warn "VM ${VMID} is currently ${VM_STATUS}. It must be stopped before migration."
  read -rp "$(echo -e "${YELLOW}Attempt a graceful shutdown now? [y/N]:${NC} ")" SHUTDOWN_CHOICE
  if [[ "${SHUTDOWN_CHOICE,,}" == "y" ]]; then
    info "Sending shutdown signal..."
    qm shutdown "$VMID"
    echo -n "  Waiting for VM to stop"
    for i in $(seq 1 60); do
      sleep 2
      VM_STATUS=$(qm status "$VMID" | awk '{print $2}')
      [[ "$VM_STATUS" == "stopped" ]] && { echo ""; break; }
      echo -n "."
    done
    echo ""
    [[ "$VM_STATUS" != "stopped" ]] && die "VM did not stop in time. Aborting."
    success "VM ${VMID} is now stopped."
  else
    die "Aborted. Please stop the VM before running this script."
  fi
else
  success "VM ${VMID} is stopped. Safe to proceed."
fi

# =============================================================================
# STEP 4 — Gather disk information
# =============================================================================
separator
info "Reading VM ${VMID} configuration and detecting disk types..."

VM_CONF="/etc/pve/qemu-server/${VMID}.conf"
[[ -f "$VM_CONF" ]] || die "Config file not found: ${VM_CONF}"

# Arrays: parallel indexed lists of disk specs, paths, and detected types
DISK_SPECS=()
DISK_FILES=()
DISK_TYPES=()   # file | lvm-thin | zfs

detect_disk_type() {
  local storage="$1"
  local stype
  stype=$(pvesm status -storage "$storage" 2>/dev/null | awk 'NR==2{print $2}' || true)
  case "$stype" in
    lvmthin|lvm) echo "lvm-thin" ;;
    zfspool)     echo "zfs"      ;;
    *)           echo "file"     ;;
  esac
}

while IFS= read -r line; do
  if [[ "$line" =~ ^(scsi|virtio|ide|sata|efidisk|tpmstate)[0-9]+: ]]; then
    DISK_SPEC=$(echo "$line" | cut -d: -f2- | cut -d, -f1 | xargs)
    STORAGE_NAME=$(echo "$DISK_SPEC" | cut -d: -f1)
    DISK_NAME=$(echo "$DISK_SPEC"    | cut -d: -f2)
    DTYPE=$(detect_disk_type "$STORAGE_NAME")
    DISK_SPECS+=("$DISK_SPEC")
    DISK_FILES+=("$DISK_NAME")
    DISK_TYPES+=("$DTYPE")
    echo "    - ${DISK_SPEC}  ${BOLD}[${DTYPE}]${NC}"
  fi
done < "$VM_CONF"

[[ ${#DISK_SPECS[@]} -eq 0 ]] && warn "No disk images found — only config will be transferred."

# =============================================================================
# STEP 5 — Confirm
# =============================================================================
separator
echo ""
echo -e "  ${BOLD}$(echo "$OPERATION" | tr '[:lower:]' '[:upper:]') Summary${NC}"
echo -e "  Mode           : ${BOLD}${OPERATION}${NC}"
echo -e "  VM ID          : ${BOLD}${VMID}${NC}"
echo -e "  Remote Node    : ${BOLD}${REMOTE_USER}@${REMOTE_IP}${NC}"
echo -e "  SSH Key        : ${BOLD}${SSH_KEY}${NC}"
echo -e "  Target Storage : ${BOLD}${TARGET_STORAGE}${NC}"
echo -e "  Disks          : ${BOLD}${#DISK_SPECS[@]}${NC}"
echo ""
read -rp "$(echo -e "${BOLD}Proceed? [y/N]:${NC} ")" CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || die "Cancelled by user."

# =============================================================================
# STEP 6 — Transfer disks (type-aware)
# =============================================================================
separator
info "Transferring disks..."

FIRST_STORAGE_NAME=""

for i in "${!DISK_SPECS[@]}"; do
  DISK_SPEC="${DISK_SPECS[$i]}"
  DISK_TYPE="${DISK_TYPES[$i]}"
  STORAGE_NAME=$(echo "$DISK_SPEC" | cut -d: -f1)
  DISK_NAME=$(echo "$DISK_SPEC"    | cut -d: -f2)
  [[ -z "$FIRST_STORAGE_NAME" ]] && FIRST_STORAGE_NAME="$STORAGE_NAME"

  info "Disk: ${DISK_SPEC}  [${DISK_TYPE}]"

  case "$DISK_TYPE" in

    # ------------------------------------------------------------------
    file)
      DISK_PATH=$(pvesm path "${STORAGE_NAME}:${DISK_NAME}" 2>/dev/null || true)
      if [[ -z "$DISK_PATH" || ! -f "$DISK_PATH" ]]; then
        warn "Could not resolve file path for '${DISK_SPEC}' — skipping."
        continue
      fi
      DISK_FILE=$(basename "$DISK_PATH")
      DISK_SIZE=$(du -sh "$DISK_PATH" | cut -f1)
      info "  File: ${DISK_FILE}  (${DISK_SIZE})"

      # Resolve remote storage directory
      REMOTE_DIR=$(remote \
        "cat /etc/pve/storage.cfg 2>/dev/null | grep -A10 '${TARGET_STORAGE}' | grep 'path' | awk '{print \$2}' | head -1" || true)
      REMOTE_DIR="${REMOTE_DIR:-/var/lib/vz}/images/${VMID}"
      remote "mkdir -p '${REMOTE_DIR}'"

      if [[ "$OPERATION" == "sync" ]]; then
        # rsync for sync mode — only sends changed blocks
        info "  Syncing via rsync..."
        rsync -avz --progress \
          -e "ssh -i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
          "$DISK_PATH" "${REMOTE_USER}@${REMOTE_IP}:${REMOTE_DIR}/${DISK_FILE}"
      else
        remote_scp "$DISK_PATH" "${REMOTE_USER}@${REMOTE_IP}:${REMOTE_DIR}/${DISK_FILE}"
      fi
      success "  Transferred: ${DISK_FILE}"
      ;;

    # ------------------------------------------------------------------
    lvm-thin)
      # LVM-thin volumes have no file path — export as raw stream via dd
      LV_PATH=$(lvdisplay --noheadings -C -o lv_path 2>/dev/null | grep "$DISK_NAME" | xargs || true)
      if [[ -z "$LV_PATH" ]]; then
        # Try constructing the path from VG
        VG=$(pvesm status -storage "$STORAGE_NAME" 2>/dev/null | awk 'NR==2{print $6}' || true)
        LV_PATH="/dev/${VG}/${DISK_NAME}"
      fi
      [[ -b "$LV_PATH" ]] || { warn "LVM volume not found at ${LV_PATH} — skipping."; continue; }

      LV_SIZE=$(blockdev --getsize64 "$LV_PATH" 2>/dev/null || true)
      info "  LVM-thin volume: ${LV_PATH}  ($(numfmt --to=iec "$LV_SIZE" 2>/dev/null || echo "${LV_SIZE}B"))"

      if [[ "$OPERATION" == "sync" ]]; then
        warn "  LVM-thin sync: full block re-transfer (LVM-thin does not support incremental sync natively)."
      fi

      # Determine remote volume name and ensure it exists on target
      REMOTE_VOL_NAME="vm-${VMID}-${DISK_NAME##*-}"
      remote "pvesm alloc '${TARGET_STORAGE}' ${VMID} '${REMOTE_VOL_NAME}' \
        $(( LV_SIZE / 1024 / 1024 / 1024 ))G 2>/dev/null || true"

      REMOTE_LV=$(remote \
        "pvesm path '${TARGET_STORAGE}:${REMOTE_VOL_NAME}' 2>/dev/null || \
         lvdisplay --noheadings -C -o lv_path 2>/dev/null | grep '${REMOTE_VOL_NAME}' | xargs" || true)

      if [[ -z "$REMOTE_LV" ]]; then
        warn "  Could not resolve remote LVM path for ${REMOTE_VOL_NAME} — skipping."
        continue
      fi

      info "  Streaming via dd over SSH..."
      dd if="$LV_PATH" bs=4M status=progress 2>/dev/null | \
        ssh -i "${SSH_KEY}" -o BatchMode=yes \
            "${REMOTE_USER}@${REMOTE_IP}" "dd of='${REMOTE_LV}' bs=4M status=none"
      success "  LVM-thin volume transferred."
      ;;

    # ------------------------------------------------------------------
    zfs)
      # ZFS: use zfs send | zfs receive
      ZFS_POOL=$(pvesm status -storage "$STORAGE_NAME" 2>/dev/null | awk 'NR==2{print $6}' || true)
      ZFS_DATASET="${ZFS_POOL}/${DISK_NAME}"

      zfs list "$ZFS_DATASET" &>/dev/null || { warn "ZFS dataset '${ZFS_DATASET}' not found — skipping."; continue; }

      REMOTE_ZFS_POOL=$(remote \
        "pvesm status 2>/dev/null | awk -v s='${TARGET_STORAGE}' '\$1==s{print \$6}'" || true)
      [[ -z "$REMOTE_ZFS_POOL" ]] && { warn "Could not determine remote ZFS pool — skipping."; continue; }

      REMOTE_DATASET="${REMOTE_ZFS_POOL}/${DISK_NAME}"
      SNAP_NAME="migrate-$(date +%s)"

      info "  ZFS dataset: ${ZFS_DATASET}"

      if [[ "$OPERATION" == "sync" ]]; then
        # Incremental send: find last common snapshot
        LAST_SNAP=$(zfs list -t snapshot -o name -s creation "$ZFS_DATASET" 2>/dev/null \
          | grep "migrate-" | tail -1 | awk -F@ '{print $2}' || true)

        if [[ -n "$LAST_SNAP" ]]; then
          REMOTE_HAS_SNAP=$(remote "zfs list -t snapshot '${REMOTE_DATASET}@${LAST_SNAP}' 2>/dev/null && echo yes" || true)
        else
          REMOTE_HAS_SNAP=""
        fi

        if [[ -n "$LAST_SNAP" && "$REMOTE_HAS_SNAP" == "yes" ]]; then
          info "  Incremental ZFS send from snapshot: ${LAST_SNAP}"
          zfs snapshot "${ZFS_DATASET}@${SNAP_NAME}"
          zfs send -i "${ZFS_DATASET}@${LAST_SNAP}" "${ZFS_DATASET}@${SNAP_NAME}" | \
            ssh -i "${SSH_KEY}" -o BatchMode=yes \
                "${REMOTE_USER}@${REMOTE_IP}" "zfs receive -F '${REMOTE_DATASET}'"
          success "  Incremental ZFS sync complete."
        else
          warn "  No common snapshot found — performing full ZFS send."
          zfs snapshot "${ZFS_DATASET}@${SNAP_NAME}"
          zfs send "${ZFS_DATASET}@${SNAP_NAME}" | \
            ssh -i "${SSH_KEY}" -o BatchMode=yes \
                "${REMOTE_USER}@${REMOTE_IP}" "zfs receive -F '${REMOTE_DATASET}'"
          success "  Full ZFS send complete."
        fi
      else
        # Fresh migrate — full send
        zfs snapshot "${ZFS_DATASET}@${SNAP_NAME}"
        info "  Full ZFS send..."
        zfs send "${ZFS_DATASET}@${SNAP_NAME}" | \
          ssh -i "${SSH_KEY}" -o BatchMode=yes \
              "${REMOTE_USER}@${REMOTE_IP}" "zfs receive -F '${REMOTE_DATASET}'"
        success "  ZFS dataset transferred."
      fi
      ;;

  esac
done

# =============================================================================
# STEP 7 — Transfer / update config (fresh migrate only — sync skips this)
# =============================================================================
separator
if [[ "$OPERATION" == "migrate" ]]; then
  info "Transferring VM configuration..."
  remote "mkdir -p /tmp/pve-migrate"
  remote_scp "$VM_CONF" "${REMOTE_USER}@${REMOTE_IP}:/tmp/pve-migrate/${VMID}.conf"
  remote "cp /tmp/pve-migrate/${VMID}.conf /etc/pve/qemu-server/${VMID}.conf && \
          rm /tmp/pve-migrate/${VMID}.conf"
  success "Configuration transferred."

  # Rewrite source storage name → target storage name if they differ
  if [[ -n "$FIRST_STORAGE_NAME" && "$FIRST_STORAGE_NAME" != "$TARGET_STORAGE" ]]; then
    info "Updating storage references in remote config: '${FIRST_STORAGE_NAME}' → '${TARGET_STORAGE}'..."
    remote "sed -i 's|${FIRST_STORAGE_NAME}:|${TARGET_STORAGE}:|g' /etc/pve/qemu-server/${VMID}.conf"
    success "Storage references updated."
  fi
else
  info "Sync mode — skipping config transfer (existing remote config preserved)."
fi

# =============================================================================
# STEP 8 — Verify
# =============================================================================
separator
info "Verifying VM ${VMID} on remote node..."
REMOTE_STATUS=$(remote "qm status ${VMID} 2>/dev/null" || echo "not found")
echo "  Remote VM status: ${REMOTE_STATUS}"

if echo "$REMOTE_STATUS" | grep -q "stopped"; then
  success "VM ${VMID} confirmed present and stopped on the remote node."
else
  warn "Could not confirm VM status on remote — check manually: qm status ${VMID}"
fi

# =============================================================================
# Done
# =============================================================================
separator
success "$(echo "$OPERATION" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') of VM ${VMID} → ${REMOTE_IP} complete!"
separator
