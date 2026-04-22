#!/bin/bash
# Clean reboot script for single-node Kubernetes cluster with mdadm + LVM
# Gracefully shuts down, reboots, waits for recovery, and restores workloads

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
NODE_IP="${NODE_IP:-192.168.16.7}"
NODE_USER="${NODE_USER:-core}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Clean Reboot Sequence for KubeOS ==="
echo ""

# Run the shutdown script
"${SCRIPT_DIR}/shutdown.sh"

echo ""
echo "=== Rebooting Node ==="

echo "Initiating reboot on node..."
ssh ${SSH_OPTS} ${NODE_USER}@${NODE_IP} "sudo systemctl reboot" &

echo "Waiting for node to reboot..."
sleep 10

# Wait for SSH to go down
echo "  Waiting for node to go down..."
for i in {1..60}; do
    if ! ssh ${SSH_OPTS} -o ConnectTimeout=1 ${NODE_USER}@${NODE_IP} "echo" &>/dev/null; then
        echo "  Node is down"
        break
    fi
    sleep 1
done

# Wait for SSH to come back
echo "  Waiting for node to come back up..."
for i in {1..120}; do
    if ssh ${SSH_OPTS} -o ConnectTimeout=2 ${NODE_USER}@${NODE_IP} "echo" &>/dev/null; then
        echo "  Node is back up!"
        break
    fi
    sleep 5
done
echo ""

echo "=== Post-Reboot Recovery ==="

echo "[1/3] Waiting for Kubernetes API..."
for i in {1..60}; do
    if kubectl cluster-info &>/dev/null; then
        echo "  Kubernetes API is responding"
        break
    fi
    echo "  Waiting for API server... (attempt $i/60)"
    sleep 5
done
echo ""

echo "[2/3] Waiting for kubeadm-auto-upgrade to complete..."
for i in {1..120}; do
    UPGRADE_STATUS=$(ssh ${SSH_OPTS} ${NODE_USER}@${NODE_IP} "systemctl is-active kubeadm-auto-upgrade.service 2>/dev/null" || echo "unknown")
    if [ "$UPGRADE_STATUS" = "active" ]; then
        # RemainAfterExit=yes means "active" = completed successfully
        echo "  kubeadm-auto-upgrade completed successfully"
        UPGRADE_RESULT=$(ssh ${SSH_OPTS} ${NODE_USER}@${NODE_IP} "sudo journalctl -u kubeadm-auto-upgrade.service --no-pager -n 3 2>/dev/null" || true)
        echo "  Last log: $UPGRADE_RESULT"
        break
    elif [ "$UPGRADE_STATUS" = "activating" ]; then
        if [ $((i % 6)) -eq 0 ]; then
            echo "  Upgrade still running... (attempt $i/120)"
        fi
    elif [ "$UPGRADE_STATUS" = "failed" ]; then
        echo "  WARNING: kubeadm-auto-upgrade failed!"
        ssh ${SSH_OPTS} ${NODE_USER}@${NODE_IP} "sudo journalctl -u kubeadm-auto-upgrade.service --no-pager -n 20 2>/dev/null" || true
        echo "  Continuing with recovery anyway..."
        break
    elif [ "$UPGRADE_STATUS" = "inactive" ]; then
        echo "  kubeadm-auto-upgrade is inactive (no upgrade needed)"
        break
    else
        if [ $((i % 6)) -eq 0 ]; then
            echo "  Waiting for upgrade service... (status: $UPGRADE_STATUS, attempt $i/120)"
        fi
    fi
    sleep 5
done
echo ""

echo "[3/3] Resuming Flux reconciliation..."
flux resume kustomization --all || echo "Warning: Failed to resume kustomizations"
flux resume helmrelease --all || echo "Warning: Failed to resume helmreleases"
echo ""

echo "Triggering Flux reconciliation..."
flux reconcile kustomization flux-system --with-source || echo "Warning: Failed to reconcile flux-system"

echo ""
echo "=== Clean Reboot Complete ==="
echo "The cluster has been rebooted cleanly. Flux will restore all workloads."
echo "Monitor Flux with: flux get all"
