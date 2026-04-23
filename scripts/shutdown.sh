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

echo "[1/4] Suspending Flux reconciliation..."
flux suspend kustomization --all || echo "Warning: Failed to suspend kustomizations"
flux suspend helmrelease --all || echo "Warning: Failed to suspend helmreleases"
echo ""

echo "[2/4] Hibernating CNPG clusters..."
# Must happen before the general scale-down so the CNPG webhook is still alive
kubectl annotate clusters.postgresql.cnpg.io immich-postgres -n privileged-apps cnpg.io/hibernation=on --overwrite || echo "Warning: Failed to hibernate immich-postgres"
# Wait for the postgres pod to terminate before proceeding
kubectl wait pod -l cnpg.io/cluster=immich-postgres -n privileged-apps --for=delete --timeout=60s 2>/dev/null || true
echo ""

echo "[3/4] Scaling down all Deployments and StatefulSets..."
ALL_NAMESPACES=$(kubectl get namespaces -o json | jq -r '.items[].metadata.name' | grep -v -E '^kube-system$|^kube-public$|^kube-node-lease$|^default$|^kube-flannel$|^metallb-system$|^flux-system$')

for ns in $ALL_NAMESPACES; do
    kubectl scale --replicas 0 --all deployment -n "$ns" 2>/dev/null || true
    kubectl scale --replicas 0 --all sts -n "$ns" 2>/dev/null || true
done
echo ""

echo "[4/4] Waiting for workloads to scale down..."
for ns in $ALL_NAMESPACES; do
    kubectl rollout status deployment --all -n "$ns" --timeout=60s 2>/dev/null || true
    kubectl rollout status statefulset --all -n "$ns" --timeout=60s 2>/dev/null || true
done

echo "=== Shutdown Complete ==="
echo "Cluster is ready for reboot or shutdown"
