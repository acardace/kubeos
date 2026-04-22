#!/bin/bash
# Clean shutdown script for single-node Kubernetes cluster with mdadm + LVM
# Gracefully scales down workloads and suspends Flux before shutdown

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

echo "[1/3] Suspending Flux reconciliation..."
flux suspend kustomization --all || echo "Warning: Failed to suspend kustomizations"
flux suspend helmrelease --all || echo "Warning: Failed to suspend helmreleases"
echo ""

echo "[2/3] Scaling down all Deployments and StatefulSets..."
ALL_NAMESPACES=$(kubectl get namespaces -o json | jq -r '.items[].metadata.name' | grep -v -E '^kube-system$|^kube-public$|^kube-node-lease$|^default$')

for ns in $ALL_NAMESPACES; do
    kubectl scale --replicas 0 --all deployment -n "$ns" 2>/dev/null || true
    kubectl scale --replicas 0 --all sts -n "$ns" 2>/dev/null || true
done
echo ""

echo "[3/3] Waiting for pods to terminate..."
for ns in $ALL_NAMESPACES; do
    kubectl wait pod --all --for=delete -n "$ns" --timeout=120s 2>/dev/null || true
done

echo "=== Shutdown Complete ==="
echo "Cluster is ready for reboot or shutdown"
