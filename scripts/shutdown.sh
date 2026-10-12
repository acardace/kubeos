#!/bin/bash
# Clean shutdown script for single-node Kubernetes cluster with mdadm + LVM
# Gracefully scales down workloads and suspends Flux before shutdown.
# Records pre-shutdown replica counts so reboot.sh can restore them.

set -e

# Configuration
NODE_IP="${NODE_IP:-192.168.16.7}"
NODE_USER="${NODE_USER:-core}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SNAPSHOT_PATH="/tmp/kubeos-replica-snapshot.json"

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

echo "[1/5] Snapshotting workload replica counts..."
# Flux resume only restores replicas for Kustomization-managed workloads:
# kustomize-controller re-applies manifests on every reconciliation, but
# helm-controller skips upgrades when chart/values are unchanged (and several
# charts don't render spec.replicas at all), so HelmRelease-managed workloads
# would stay at 0 after a reboot. Snapshot the current replica counts to a
# local file; reboot.sh scales everything back from it.
if kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system flux-system -o jsonpath='{.spec.suspend}' 2>/dev/null | grep -q true; then
    echo "  Flux is already suspended - keeping existing replica snapshot"
else
    REPLICAS=$(kubectl get deploy,sts -A -o json | jq -r '.items[] | select((.spec.replicas // 0) > 0) | "\(.metadata.namespace) \(.kind) \(.metadata.name) \(.spec.replicas)"')
    if [ -n "$REPLICAS" ]; then
        echo "$REPLICAS" > "${SNAPSHOT_PATH}" \
            || { echo "Error: Failed to write replica snapshot"; exit 1; }
        echo "  Saved $(echo "$REPLICAS" | wc -l) workloads to ${SNAPSHOT_PATH}"
    else
        echo "  Warning: No workloads with replicas > 0 found, not writing snapshot"
    fi
fi
echo ""

echo "[2/5] Suspending Flux reconciliation..."
flux suspend kustomization --all || echo "Warning: Failed to suspend kustomizations"
flux suspend helmrelease --all || echo "Warning: Failed to suspend helmreleases"
echo ""

echo "[3/5] Hibernating CNPG clusters..."
# Must happen before the general scale-down so the CNPG webhook is still alive
kubectl annotate clusters.postgresql.cnpg.io immich-postgres -n privileged-apps cnpg.io/hibernation=on --overwrite || echo "Warning: Failed to hibernate immich-postgres"
# Wait for the postgres pod to terminate before proceeding
kubectl wait pod -l cnpg.io/cluster=immich-postgres -n privileged-apps --for=delete --timeout=60s 2>/dev/null || true
echo ""

echo "[4/5] Scaling down all Deployments and StatefulSets..."
ALL_NAMESPACES=$(kubectl get namespaces -o json | jq -r '.items[].metadata.name' | grep -v -E '^kube-system$|^kube-public$|^kube-node-lease$|^default$|^kube-flannel$|^metallb-system$|^flux-system$')

for ns in $ALL_NAMESPACES; do
    kubectl scale --replicas 0 --all deployment -n "$ns" 2>/dev/null || true
    kubectl scale --replicas 0 --all sts -n "$ns" 2>/dev/null || true
done
echo ""

echo "[5/5] Waiting for workloads to scale down..."
for ns in $ALL_NAMESPACES; do
    kubectl rollout status deployment --all -n "$ns" --timeout=60s 2>/dev/null || true
    kubectl rollout status statefulset --all -n "$ns" --timeout=60s 2>/dev/null || true
done

echo "=== Shutdown Complete ==="
echo "Cluster is ready for reboot or shutdown"
