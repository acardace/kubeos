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

echo "[1/6] Waiting for Kubernetes API..."
for i in {1..60}; do
    if kubectl cluster-info &>/dev/null; then
        echo "  Kubernetes API is responding"
        break
    fi
    echo "  Waiting for API server... (attempt $i/60)"
    sleep 5
done
echo ""

echo "[2/6] Scaling up all Rook-Ceph deployments..."
ROOK_DEPLOYMENTS=$(kubectl get deployments -n rook-ceph -o json | jq -r '.items[] | select(.spec.replicas == 0) | .metadata.name')
for deploy in $ROOK_DEPLOYMENTS; do
    echo "  Scaling up deployment/$deploy to 1..."
    kubectl scale deployment/$deploy -n rook-ceph --replicas=1 --timeout=60s || echo "  Warning: Failed to scale $deploy"
done
echo ""

echo "[3/6] Waiting for Ceph cluster to be healthy..."
for i in {1..120}; do
    HEALTH=$(kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health 2>/dev/null | grep -o "HEALTH_OK\|HEALTH_WARN" || echo "UNKNOWN")
    if [ "$HEALTH" = "HEALTH_OK" ]; then
        echo "  Ceph is HEALTH_OK"
        break
    elif [ "$HEALTH" = "HEALTH_WARN" ]; then
        echo "  Ceph is HEALTH_WARN (acceptable)"
        break
    fi
    echo "  Waiting for Ceph... (status: $HEALTH, attempt $i/120)"
    sleep 5
done
echo ""

echo "[4/6] Unsetting Ceph flags..."
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout || true
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset norebalance || true
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noscrub || true
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset nodeep-scrub || true
echo ""

echo "[5/6] Scaling up all Deployments and StatefulSets in the cluster..."
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

echo "[6/6] Resuming Flux reconciliation..."
flux resume kustomization --all || echo "Warning: Failed to resume kustomizations"
flux resume helmrelease --all || echo "Warning: Failed to resume helmreleases"
echo ""

echo "Triggering Flux reconciliation..."
flux reconcile kustomization flux-system --with-source || echo "Warning: Failed to reconcile flux-system"
echo ""

echo "=== Clean Reboot Complete ==="
echo "The cluster has been rebooted cleanly. Flux will restore all workloads."
echo "Monitor Flux with: flux get all"
