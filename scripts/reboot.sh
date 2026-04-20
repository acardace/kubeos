#!/bin/bash
# Clean reboot script for single-node Kubernetes cluster with Rook-Ceph
# This script gracefully shuts down the cluster to avoid 30+ minute delays

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
echo ""

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

echo "[1/9] Waiting for Kubernetes API..."
for i in {1..60}; do
    if kubectl cluster-info &>/dev/null; then
        echo "  Kubernetes API is responding"
        break
    fi
    echo "  Waiting for API server... (attempt $i/60)"
    sleep 5
done
echo ""

echo "[2/9] Waiting for kubeadm-auto-upgrade to complete..."
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

echo "[3/9] Scaling up Rook-Ceph infrastructure (excluding OSDs)..."
ROOK_INFRA_DEPLOYMENTS=$(kubectl get deployments -n rook-ceph -o json | jq -r '.items[] | select(.spec.replicas == 0) | select(.metadata.name | test("rook-ceph-osd-") | not) | .metadata.name')
for deploy in $ROOK_INFRA_DEPLOYMENTS; do
    echo "  Scaling up deployment/$deploy to 1..."
    kubectl scale deployment/$deploy -n rook-ceph --replicas=1 --timeout=60s || echo "  Warning: Failed to scale $deploy"
done
echo ""

echo "[4/9] Waiting for Rook operator to be ready..."
kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=300s || echo "  Warning: Operator rollout timed out"
echo ""

echo "[5/9] Scaling up OSDs sequentially (to reduce I/O contention)..."
OSD_DEPLOYMENTS=$(kubectl get deployments -n rook-ceph -o json | jq -r '.items[] | select(.spec.replicas == 0) | select(.metadata.name | test("rook-ceph-osd-")) | .metadata.name' | sort)
TOTAL_OSD_COUNT=$(echo "$OSD_DEPLOYMENTS" | grep -c . || echo "0")
CURRENT_OSD=0
for osd_deploy in $OSD_DEPLOYMENTS; do
    CURRENT_OSD=$((CURRENT_OSD + 1))
    OSD_ID=$(echo "$osd_deploy" | sed 's/rook-ceph-osd-\([0-9]*\).*/\1/')
    echo "  [$CURRENT_OSD/$TOTAL_OSD_COUNT] Scaling up $osd_deploy..."
    kubectl scale deployment/$osd_deploy -n rook-ceph --replicas=1 --timeout=60s || echo "    Warning: Failed to scale $osd_deploy"

    # Wait for this specific OSD to be up before starting next one
    # bluefs-bdev-expand on HDDs takes ~15 min, plus OSD startup ~5 min = ~20 min total
    echo "    Waiting for OSD.$OSD_ID to be up (up to 20 min for HDD journal replay)..."
    for i in {1..240}; do
        OSD_UP=$(kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd dump 2>/dev/null | grep "^osd\.$OSD_ID " | grep -c " up " || echo "0")
        if [ "$OSD_UP" = "1" ]; then
            echo "    OSD.$OSD_ID is up"
            break
        fi
        if [ $((i % 12)) -eq 0 ]; then
            echo "    Still waiting for OSD.$OSD_ID... ($((i * 5 / 60)) min elapsed)"
        fi
        sleep 5
    done
done
echo ""

echo "[6/9] Waiting for Ceph cluster to be healthy..."
for i in {1..60}; do
    HEALTH=$(kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health 2>/dev/null | grep -o "HEALTH_OK\|HEALTH_WARN" || echo "UNKNOWN")
    if [ "$HEALTH" = "HEALTH_OK" ]; then
        echo "  Ceph is HEALTH_OK"
        break
    elif [ "$HEALTH" = "HEALTH_WARN" ]; then
        echo "  Ceph is HEALTH_WARN (acceptable)"
        break
    fi
    echo "  Waiting for Ceph... (status: $HEALTH, attempt $i/60)"
    sleep 5
done
echo ""

echo "[7/9] Unsetting Ceph flags..."
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout || true
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset norebalance || true
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noscrub || true
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset nodeep-scrub || true
echo ""

echo "[8/9] Scaling up all Deployments and StatefulSets in the cluster..."
# Get all namespaces except rook-ceph (already done)
ALL_NAMESPACES=$(kubectl get namespaces -o json | jq -r '.items[].metadata.name' | grep -v -E '^rook-ceph$')

for ns in $ALL_NAMESPACES; do
    # Scale deployments
    DEPLOYMENTS=$(kubectl get deployments -n $ns -o json 2>/dev/null | jq -r '.items[] | select(.spec.replicas == 0) | .metadata.name' || echo "")
    if [ -n "$DEPLOYMENTS" ]; then
        echo "  Namespace: $ns (Deployments)"
        for deploy in $DEPLOYMENTS; do
            echo "    Scaling deployment/$deploy to 1..."
            kubectl scale deployment/$deploy -n $ns --replicas=1 --timeout=30s || echo "    Warning: Failed to scale $deploy"
        done
    fi

    # Scale statefulsets
    STATEFULSETS=$(kubectl get statefulsets -n $ns -o json 2>/dev/null | jq -r '.items[] | select(.spec.replicas == 0) | .metadata.name' || echo "")
    if [ -n "$STATEFULSETS" ]; then
        echo "  Namespace: $ns (StatefulSets)"
        for sts in $STATEFULSETS; do
            echo "    Scaling statefulset/$sts to 1..."
            kubectl scale statefulset/$sts -n $ns --replicas=1 --timeout=30s || echo "    Warning: Failed to scale $sts"
        done
    fi
done
echo ""

echo "[9/9] Resuming Flux reconciliation..."
flux resume kustomization --all || echo "Warning: Failed to resume kustomizations"
flux resume helmrelease --all || echo "Warning: Failed to resume helmreleases"
echo ""

echo "Triggering Flux reconciliation..."
flux reconcile kustomization flux-system --with-source || echo "Warning: Failed to reconcile flux-system"
echo ""

echo "=== Clean Reboot Complete ==="
echo "The cluster has been rebooted cleanly. Flux will restore all workloads."
echo "Monitor Flux with: flux get all"
