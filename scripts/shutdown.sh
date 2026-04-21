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
    DEPLOYMENTS=$(kubectl get deployments -n $ns -o json 2>/dev/null | jq -r '.items[] | select(.spec.replicas > 0) | .metadata.name' || echo "")
    for deploy in $DEPLOYMENTS; do
        echo "  Scaling deployment/$deploy -n $ns to 0..."
        kubectl scale deployment/$deploy -n $ns --replicas=0 --timeout=30s || echo "  Warning: Failed to scale $deploy"
    done

    STATEFULSETS=$(kubectl get statefulsets -n $ns -o json 2>/dev/null | jq -r '.items[] | select(.spec.replicas > 0) | .metadata.name' || echo "")
    for sts in $STATEFULSETS; do
        echo "  Scaling statefulset/$sts -n $ns to 0..."
        kubectl scale statefulset/$sts -n $ns --replicas=0 --timeout=30s || echo "  Warning: Failed to scale $sts"
    done
done
echo ""

echo "[3/3] Waiting for pods to terminate..."
sleep 10

echo "=== Shutdown Complete ==="
echo "Cluster is ready for reboot or shutdown"
