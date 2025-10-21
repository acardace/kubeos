#!/bin/bash
# Clean shutdown script for single-node Kubernetes cluster with Rook-Ceph
# This script gracefully shuts down the cluster to avoid 30+ minute delays

set -e

# Configuration
NODE_IP="${NODE_IP:-192.168.16.7}"
NODE_USER="${NODE_USER:-core}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Clean Shutdown Sequence for KubeOS ==="
echo "Target: ${NODE_USER}@${NODE_IP}"
echo ""

# Check if we can reach the node
if ! ssh ${SSH_OPTS} ${NODE_USER}@${NODE_IP} "echo 'Node reachable'" 2>/dev/null; then
    echo "Error: Cannot reach node at ${NODE_IP}"
    exit 1
fi

# Check if kubectl works
if ! kubectl cluster-info &>/dev/null; then
    echo "Error: kubectl cannot connect to cluster"
    exit 1
fi

echo "[1/8] Suspending Flux reconciliation..."
flux suspend kustomization --all || echo "Warning: Failed to suspend kustomizations"
flux suspend helmrelease --all || echo "Warning: Failed to suspend helmreleases"
echo ""

echo "[2/8] Finding namespaces with PVCs..."
NAMESPACES=$(kubectl get pvc --all-namespaces -o json | jq -r '.items[].metadata.namespace' | sort -u)
if [ -z "$NAMESPACES" ]; then
    echo "No namespaces with PVCs found"
else
    echo "Found namespaces with PVCs: $(echo $NAMESPACES | tr '\n' ' ')"
fi
echo ""

echo "[3/8] Scaling down Deployments in PVC namespaces..."
for ns in $NAMESPACES; do
    if [ "$ns" = "rook-ceph" ]; then
        echo "  Skipping rook-ceph namespace (will handle separately)"
        continue
    fi

    echo "  Namespace: $ns"
    DEPLOYMENTS=$(kubectl get deployments -n $ns -o json | jq -r '.items[].metadata.name' 2>/dev/null || echo "")
    for deploy in $DEPLOYMENTS; do
        echo "    Scaling deployment/$deploy to 0..."
        kubectl scale deployment/$deploy -n $ns --replicas=0 --timeout=30s || echo "    Warning: Failed to scale $deploy"
    done
done
echo ""

echo "[4/8] Scaling down StatefulSets in PVC namespaces..."
for ns in $NAMESPACES; do
    if [ "$ns" = "rook-ceph" ]; then
        continue
    fi

    STATEFULSETS=$(kubectl get statefulsets -n $ns -o json | jq -r '.items[].metadata.name' 2>/dev/null || echo "")
    for sts in $STATEFULSETS; do
        echo "    Scaling statefulset/$sts to 0..."
        kubectl scale statefulset/$sts -n $ns --replicas=0 --timeout=30s || echo "    Warning: Failed to scale $sts"
    done
done
echo ""

echo "[5/8] Unmounting CephFS kernel mounts on node..."
ssh ${SSH_OPTS} ${NODE_USER}@${NODE_IP} "sudo bash -c '
    CEPH_MOUNTS=\$(grep ceph /proc/mounts | awk \"{print \\\$2}\" | tac)
    if [ -n \"\$CEPH_MOUNTS\" ]; then
        echo \"Found CephFS mounts, unmounting...\"
        for mount in \$CEPH_MOUNTS; do
            echo \"  Unmounting \$mount\"
            umount -f \$mount 2>/dev/null || umount -l \$mount 2>/dev/null || echo \"  Warning: Could not unmount \$mount\"
        done
    else
        echo \"No CephFS mounts found\"
    fi
'" || echo "Warning: Could not unmount CephFS mounts"
echo ""

echo "[6/8] Setting Ceph flags to prevent rebalancing..."
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noout || true
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set norebalance || true
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noscrub || true
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set nodeep-scrub || true
echo ""

echo "[7/8] Scaling down Rook-Ceph operator..."
kubectl -n rook-ceph scale deployment rook-ceph-operator --replicas=0 --timeout=30s || true
echo ""

echo "[8/8] Scaling down Ceph services..."
echo "  Scaling down MDS..."
kubectl -n rook-ceph scale deployment -l app=rook-ceph-mds --replicas=0 --timeout=60s || true

echo "  Scaling down OSDs..."
kubectl -n rook-ceph scale deployment -l app=rook-ceph-osd --replicas=0 --timeout=120s || true

echo "  Waiting for OSDs to flush..."
sleep 10

echo "  Scaling down MGR..."
kubectl -n rook-ceph scale deployment -l app=rook-ceph-mgr --replicas=0 --timeout=30s || true

echo "  Scaling down MON..."
kubectl -n rook-ceph scale deployment -l app=rook-ceph-mon --replicas=0 --timeout=30s || true
echo ""

echo "=== Shutdown Complete ==="
echo "Cluster is ready for reboot or shutdown"
