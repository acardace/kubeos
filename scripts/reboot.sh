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
SNAPSHOT_PATH="/tmp/kubeos-replica-snapshot.json"

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
if ssh ${SSH_OPTS} -o ConnectTimeout=1 ${NODE_USER}@${NODE_IP} "echo" &>/dev/null; then
    echo "  ERROR: Node is still up after 60s - reboot may have failed, aborting"
    exit 1
fi

# Wait for SSH to come back
echo "  Waiting for node to come back up..."
for i in {1..120}; do
    if ssh ${SSH_OPTS} -o ConnectTimeout=2 ${NODE_USER}@${NODE_IP} "echo" &>/dev/null; then
        echo "  Node is back up!"
        break
    fi
    sleep 5
done
if ! ssh ${SSH_OPTS} -o ConnectTimeout=2 ${NODE_USER}@${NODE_IP} "echo" &>/dev/null; then
    echo "  ERROR: Node did not come back up within 10 minutes, aborting"
    exit 1
fi
echo ""

echo "=== Post-Reboot Recovery ==="

echo "[1/5] Waiting for Kubernetes API..."
for i in {1..60}; do
    if kubectl cluster-info &>/dev/null; then
        echo "  Kubernetes API is responding"
        break
    fi
    echo "  Waiting for API server... (attempt $i/60)"
    sleep 5
done
if ! kubectl cluster-info &>/dev/null; then
    echo "  ERROR: Kubernetes API did not come up within 5 minutes, aborting"
    exit 1
fi
echo ""

echo "[2/5] Waiting for kubeadm-auto-upgrade to complete..."
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
if [ "$UPGRADE_STATUS" != "active" ] && [ "$UPGRADE_STATUS" != "inactive" ] && [ "$UPGRADE_STATUS" != "failed" ]; then
    echo "  WARNING: kubeadm-auto-upgrade still in status '${UPGRADE_STATUS}' after 10 minutes, continuing anyway"
fi
echo ""

echo "[3/5] Resuming Flux reconciliation..."
flux resume kustomization --all || echo "Warning: Failed to resume kustomizations"
flux resume helmrelease --all || echo "Warning: Failed to resume helmreleases"
echo ""

echo "Triggering Flux reconciliation..."
flux reconcile kustomization flux-system --with-source || echo "Warning: Failed to reconcile flux-system"

echo ""

echo "[4/5] Resuming CNPG cluster from hibernation..."
# shutdown.sh set cnpg.io/hibernation=on. Flux does not manage that annotation
# (it is not part of the Git manifests), so without this the cluster would
# stay hibernated after the reboot.
kubectl annotate clusters.postgresql.cnpg.io immich-postgres -n privileged-apps cnpg.io/hibernation=off --overwrite || echo "Warning: Failed to resume immich-postgres"
echo ""

echo "[5/5] Restoring workload replicas from snapshot..."
# kustomize-controller re-applies manifests on every reconciliation, so
# Kustomization-managed workloads come back on their own. helm-controller
# skips upgrades when chart/values are unchanged, so HelmRelease-managed
# workloads stay at 0 - restore their replica counts explicitly from the
# snapshot written by shutdown.sh.
SNAPSHOT=$(cat "${SNAPSHOT_PATH}" 2>/dev/null || true)
if [ -z "$SNAPSHOT" ]; then
    echo "  Warning: No replica snapshot found (${SNAPSHOT_PATH})"
    echo "  Relying on Flux alone - HelmRelease-managed workloads may stay scaled to 0"
else
    RESTORED=0
    while read -r ns kind name replicas; do
        if [ -z "$ns" ]; then
            continue
        fi
        kind_lower=$(echo "${kind}" | tr 'A-Z' 'a-z')
        if kubectl scale "${kind_lower}/${name}" -n "${ns}" --replicas="${replicas}" &>/dev/null; then
            RESTORED=$((RESTORED + 1))
        else
            echo "  Warning: Failed to scale ${ns}/${kind}/${name} to ${replicas}"
        fi
    done <<< "$SNAPSHOT"
    echo "  Restored ${RESTORED} workloads from snapshot"
    echo ""

    echo "  Waiting for workloads to roll out..."
    for ns in $(echo "$SNAPSHOT" | awk '{print $1}' | sort -u); do
        kubectl rollout status deployment --all -n "$ns" --timeout=120s 2>/dev/null || true
        kubectl rollout status statefulset --all -n "$ns" --timeout=120s 2>/dev/null || true
    done

    echo ""
    echo "  Waiting for immich-postgres to recover from hibernation..."
    for i in {1..30}; do
        if kubectl get pod -l cnpg.io/cluster=immich-postgres -n privileged-apps --no-headers 2>/dev/null | grep -q .; then
            break
        fi
        sleep 10
    done
    kubectl wait pod -l cnpg.io/cluster=immich-postgres -n privileged-apps --for=condition=Ready --timeout=300s 2>/dev/null || echo "  Warning: immich-postgres pods are not ready yet"
fi
echo ""

echo "=== Clean Reboot Complete ==="
echo "The cluster has been rebooted cleanly and workloads restored."
echo "Monitor recovery with: flux get all && kubectl get pods -A"
