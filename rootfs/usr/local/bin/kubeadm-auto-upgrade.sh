#!/bin/bash
# Automatic kubeadm upgrade script for bootc-based systems
# Detects version mismatch and upgrades the cluster

set -euo pipefail

KUBECONFIG="/etc/kubernetes/admin.conf"
LOG_PREFIX="[kubeadm-auto-upgrade]"

log() {
    echo "${LOG_PREFIX} $*"
}

# Wait for API server to be ready
wait_for_apiserver() {
    log "Waiting for API server to be ready..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if kubectl --kubeconfig="${KUBECONFIG}" get --raw /healthz &>/dev/null; then
            log "API server is ready"
            return 0
        fi
        retries=$((retries - 1))
        sleep 2
    done
    log "ERROR: API server not ready after 60 seconds"
    return 1
}

# Wait for cluster to be fully operational (CoreDNS ready)
wait_for_cluster_ready() {
    log "Waiting for cluster to be fully operational..."
    local retries=60
    while [ $retries -gt 0 ]; do
        # Check if CoreDNS pods are running (indicator of cluster health)
        if kubectl --kubeconfig="${KUBECONFIG}" -n kube-system get pods -l k8s-app=kube-dns 2>/dev/null | grep -q "Running"; then
            # Wait a bit more to ensure stability
            log "CoreDNS is running, waiting 30s for cluster to stabilize..."
            sleep 30
            log "Cluster is ready"
            return 0
        fi
        retries=$((retries - 1))
        sleep 2
    done
    log "ERROR: Cluster not ready after 120 seconds"
    return 1
}

# Check if cluster exists
if [ ! -f "${KUBECONFIG}" ]; then
    log "No cluster found (${KUBECONFIG} missing), skipping upgrade"
    exit 0
fi

# Wait for API server
if ! wait_for_apiserver; then
    log "Cannot proceed without API server"
    exit 1
fi

# Wait for cluster to be fully ready before attempting upgrade
if ! wait_for_cluster_ready; then
    log "Cannot proceed without stable cluster"
    exit 1
fi

# Get kubeadm binary version
KUBEADM_VERSION=$(kubeadm version -o short | sed 's/v//')
log "kubeadm binary version: ${KUBEADM_VERSION}"

# Get cluster control plane version (not kubelet version)
CLUSTER_VERSION=$(kubectl --kubeconfig="${KUBECONFIG}" version -o json | jq -r '.serverVersion.gitVersion' | sed 's/v//')
log "Current cluster version: ${CLUSTER_VERSION}"

# Compare versions
if [ "${KUBEADM_VERSION}" = "${CLUSTER_VERSION}" ]; then
    log "Versions match, no upgrade needed"
    exit 0
fi

log "Version mismatch detected!"
log "Will upgrade cluster from ${CLUSTER_VERSION} to ${KUBEADM_VERSION}"

# Perform upgrade
log "Running: kubeadm upgrade apply v${KUBEADM_VERSION} --yes"
if kubeadm upgrade apply "v${KUBEADM_VERSION}" --yes --patches /etc/kubernetes/patches; then
    log "✓ Cluster upgrade successful"

    # Update Flannel to ensure compatibility with new Kubernetes version
    log "Updating Flannel CNI..."
    if kubectl --kubeconfig="${KUBECONFIG}" apply -f https://github.com/flannel-io/flannel/releases/download/v0.27.4/kube-flannel.yml; then
        log "✓ Flannel updated"
    else
        log "WARNING: Flannel update failed, but Kubernetes upgrade succeeded"
    fi

    log "✓ Upgrade complete!"
else
    log "ERROR: Cluster upgrade failed"
    exit 1
fi
