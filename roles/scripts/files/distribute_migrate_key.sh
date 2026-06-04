#!/bin/bash
# =============================================================================
# distribute_migrate_key.sh
# Distributes the local 'migrate' user's public SSH key to one or more remote
# Proxmox nodes, using your personal sudo-enabled account on both ends.
#
# Prerequisites:
#   - The 'migrate' user and its SSH key must already exist locally
#     (run setup_migrate_user.sh first)
#   - Your user account must have sudo rights on both local and remote nodes
#   - Your user account must be able to SSH into each remote node
#   - sshpass must be installed: apt install sshpass
#
# Usage:
#   chmod +x distribute_migrate_key.sh
#   ./distribute_migrate_key.sh <target1> [target2] [target3] ...
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MIGRATE_USER="migrate"
MIGRATE_KEY="/home/${MIGRATE_USER}/.ssh/id_ed25519.pub"
REMOTE_AUTHORIZED_KEYS="/home/${MIGRATE_USER}/.ssh/authorized_keys"
REMOTE_SSH_DIR="/home/${MIGRATE_USER}/.ssh"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=no"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
error()   { echo "[ERROR] $*" >&2; }

print_usage() {
    echo "Usage: $0 <target-host> [target-host2] ..."
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.101"
    echo "  $0 pve-node2 pve-node3"
    exit 1
}

# Wrapper: run a command over SSH with sshpass handling the SSH login password
# Usage: rssh <host> <command>
rssh() {
    local host="$1"
    local cmd="$2"
    SSHPASS="${SSH_PASS}" sshpass -e \
        ssh ${SSH_OPTS} "${REMOTE_USER}@${host}" "${cmd}"
}

# Wrapper: run a remote sudo command, feeding sudo password via -S
# Usage: rsudo <host> <command>
rsudo() {
    local host="$1"
    local cmd="$2"
    SSHPASS="${SSH_PASS}" sshpass -e \
        ssh ${SSH_OPTS} "${REMOTE_USER}@${host}" \
        "echo '${SUDO_PASS}' | sudo -S -p '' bash -c '${cmd}'" 2>/dev/null
}

# Wrapper: pipe stdin into a remote sudo command
# Usage: echo "data" | rsudo_pipe <host> <command>
rsudo_pipe() {
    local host="$1"
    local cmd="$2"
    SSHPASS="${SSH_PASS}" sshpass -e \
        ssh ${SSH_OPTS} "${REMOTE_USER}@${host}" \
        "echo '${SUDO_PASS}' | sudo -S -p '' bash -c '${cmd}'"  2>/dev/null
}

# ---------------------------------------------------------------------------
# Check sshpass is installed, offer to install if missing
# ---------------------------------------------------------------------------
check_sshpass() {
    if ! command -v sshpass &>/dev/null; then
        warn "sshpass is not installed."
        read -rp "Install it now? (apt install sshpass) [y/N]: " yn
        if [[ "${yn,,}" == "y" ]]; then
            echo "${LOCAL_SUDO_PASS}" | sudo -S -p '' apt-get install -y sshpass
            success "sshpass installed."
        else
            error "sshpass is required. Install with: sudo apt install sshpass"
            exit 1
        fi
    else
        success "sshpass found."
    fi
}

# ---------------------------------------------------------------------------
# Prompt for passwords once upfront
# ---------------------------------------------------------------------------
collect_passwords() {
    echo ""

    # Local sudo password — needed to read migrate's key and run migrate ssh test
    read -rsp "[sudo] Enter YOUR LOCAL sudo password: " LOCAL_SUDO_PASS
    echo ""
    if ! echo "${LOCAL_SUDO_PASS}" | sudo -S -p '' true 2>/dev/null; then
        error "Local sudo authentication failed."
        exit 1
    fi
    success "Local sudo authenticated."
    echo ""

    # SSH login password for the remote node (your user account password)
    read -rsp "[ssh]   Enter YOUR SSH login password for remote nodes: " SSH_PASS
    echo ""
    echo ""

    # Remote sudo password
    read -rsp "[sudo]  Enter YOUR REMOTE sudo password (blank = same as SSH password): " SUDO_PASS
    echo ""
    if [[ -z "${SUDO_PASS}" ]]; then
        SUDO_PASS="${SSH_PASS}"
        info "Using SSH password for remote sudo."
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Pre-flight: read the local public key
# ---------------------------------------------------------------------------
preflight() {
    command -v ssh &>/dev/null || { error "ssh not found."; exit 1; }

    if ! echo "${LOCAL_SUDO_PASS}" | sudo -S -p '' test -f "${MIGRATE_KEY}" 2>/dev/null; then
        error "Public key not found at ${MIGRATE_KEY}"
        error "Have you run setup_migrate_user.sh on this node yet?"
        exit 1
    fi

    PUB_KEY=$(echo "${LOCAL_SUDO_PASS}" | sudo -S -p '' cat "${MIGRATE_KEY}" 2>/dev/null)
    [[ -n "${PUB_KEY}" ]] || { error "Public key file is empty."; exit 1; }

    success "Local public key read from ${MIGRATE_KEY}"
}

# ---------------------------------------------------------------------------
# Distribute key to a single remote host
# ---------------------------------------------------------------------------
distribute_to_host() {
    local target="$1"

    echo ""
    echo "--------------------------------------------------------------"
    info "Target: ${target}"
    echo "--------------------------------------------------------------"

    # Test SSH connectivity
    info "Testing SSH connection to ${target}..."
    if ! rssh "${target}" "echo connected" &>/dev/null; then
        error "Cannot connect to ${target} — check hostname/IP and SSH password."
        FAILED_HOSTS+=("${target}")
        return
    fi
    success "SSH connection OK"

    # Validate remote sudo
    info "Validating remote sudo on ${target}..."
    if ! rsudo "${target}" "true"; then
        error "Remote sudo failed on ${target} — check sudo password."
        FAILED_HOSTS+=("${target}")
        return
    fi
    success "Remote sudo authenticated"

    # Prepare remote .ssh directory
    info "Preparing ${REMOTE_SSH_DIR} on ${target}..."
    rsudo "${target}" \
        "mkdir -p ${REMOTE_SSH_DIR} && \
         touch ${REMOTE_AUTHORIZED_KEYS} && \
         chmod 700 ${REMOTE_SSH_DIR} && \
         chmod 600 ${REMOTE_AUTHORIZED_KEYS} && \
         chown -R ${MIGRATE_USER}:${MIGRATE_USER} ${REMOTE_SSH_DIR}"
    success "Remote .ssh directory ready"

    # Check for duplicate
    local key_fingerprint
    key_fingerprint=$(echo "${PUB_KEY}" | awk '{print $2}')

    info "Checking for duplicate key on ${target}..."
    if rsudo "${target}" "grep -qF '${key_fingerprint}' ${REMOTE_AUTHORIZED_KEYS}" 2>/dev/null; then
        warn "Key already present on ${target} — skipping."
        SUCCESS_HOSTS+=("${target} (already present)")
        return
    fi

    # Install the key
    info "Installing public key on ${target}..."
    echo "${PUB_KEY}" | rsudo_pipe "${target}" \
        "cat >> ${REMOTE_AUTHORIZED_KEYS}"
    success "Public key installed"

    # Verify
    info "Verifying key on ${target}..."
    if rsudo "${target}" "grep -qF '${key_fingerprint}' ${REMOTE_AUTHORIZED_KEYS}"; then
        success "Key verified in ${REMOTE_AUTHORIZED_KEYS} on ${target}"
    else
        error "Key verification failed on ${target}"
        FAILED_HOSTS+=("${target}")
        return
    fi

    # Test migrate user login
    info "Testing migrate user SSH login to ${target}..."
    if echo "${LOCAL_SUDO_PASS}" | sudo -S -p '' -u "${MIGRATE_USER}" \
        ssh ${SSH_OPTS} \
        -i "/home/${MIGRATE_USER}/.ssh/id_ed25519" \
        "${MIGRATE_USER}@${target}" "echo ok" &>/dev/null; then
        success "migrate@${target} SSH login confirmed ✓"
        SUCCESS_HOSTS+=("${target}")
    else
        warn "Key installed but migrate login test inconclusive on ${target}"
        warn "Test manually: sudo -u migrate ssh migrate@${target}"
        SUCCESS_HOSTS+=("${target} (key installed — verify login manually)")
    fi
}

# ---------------------------------------------------------------------------
# Clear passwords from memory
# ---------------------------------------------------------------------------
clear_passwords() {
    LOCAL_SUDO_PASS=""
    SSH_PASS=""
    SUDO_PASS=""
    unset LOCAL_SUDO_PASS
    unset SSH_PASS
    unset SUDO_PASS
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "=============================================================="
    echo "  distribute_migrate_key.sh — SUMMARY"
    echo "=============================================================="

    if [[ ${#SUCCESS_HOSTS[@]} -gt 0 ]]; then
        echo ""
        echo "  Succeeded:"
        for h in "${SUCCESS_HOSTS[@]}"; do
            echo "    ✓  ${h}"
        done
    fi

    if [[ ${#FAILED_HOSTS[@]} -gt 0 ]]; then
        echo ""
        echo "  Failed:"
        for h in "${FAILED_HOSTS[@]}"; do
            echo "    ✗  ${h}"
        done
    fi

    echo ""
    echo "  To verify a connection manually:"
    echo "  sudo -u ${MIGRATE_USER} ssh ${MIGRATE_USER}@<target>"
    echo ""
    echo "=============================================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    [[ $# -gt 0 ]] || print_usage

    REMOTE_USER="${SUDO_USER:-$USER}"
    SUCCESS_HOSTS=()
    FAILED_HOSTS=()

    echo ""
    echo "======================================================"
    echo "  distribute_migrate_key.sh"
    echo "  SSH account : ${REMOTE_USER}"
    echo "  Targets     : $*"
    echo "======================================================"

    collect_passwords
    check_sshpass
    preflight

    for target in "$@"; do
        distribute_to_host "${target}"
    done

    clear_passwords
    print_summary
}

main "$@"
