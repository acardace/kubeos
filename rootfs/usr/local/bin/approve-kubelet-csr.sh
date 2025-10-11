#!/bin/bash
# Auto-approve pending kubelet serving certificate requests
# This is safe for single-node clusters where we trust the kubelet

set -e

KUBECONFIG=/etc/kubernetes/admin.conf

# Check if API server is ready
if ! kubectl --kubeconfig=$KUBECONFIG get nodes &>/dev/null; then
    echo "API server not ready, skipping CSR approval"
    exit 0
fi

# Get all pending kubelet-serving CSRs and approve them
CSRS=$(kubectl --kubeconfig=$KUBECONFIG get csr -o json 2>/dev/null | \
    jq -r '.items[] | select(.spec.signerName=="kubernetes.io/kubelet-serving" and .status.conditions == null) | .metadata.name' || true)

if [ -n "$CSRS" ]; then
    echo "Approving kubelet-serving CSRs: $CSRS"
    echo "$CSRS" | xargs -r kubectl --kubeconfig=$KUBECONFIG certificate approve
else
    echo "No pending kubelet-serving CSRs to approve"
fi
