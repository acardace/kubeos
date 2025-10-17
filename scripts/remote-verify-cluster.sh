#!/bin/bash
# Run verify-cluster.sh remotely on the cluster node

set -e

# Default to production
NODE_IP="192.168.16.7"
SSH_USER="core"

# Parse arguments
if [[ "$1" == "--test" ]]; then
    NODE_IP="192.168.122.50"
    shift
elif [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $0 [--test] [NODE_IP] [SSH_USER]"
    echo ""
    echo "Run comprehensive cluster verification remotely via SSH"
    echo ""
    echo "Options:"
    echo "  --test    Use test VM IP (192.168.122.50) instead of production (192.168.16.7)"
    echo ""
    echo "Arguments:"
    echo "  NODE_IP   IP address of the cluster node (default: 192.168.16.7)"
    echo "  SSH_USER  SSH username (default: core)"
    echo ""
    echo "Examples:"
    echo "  $0                      # Verify production node at 192.168.16.7"
    echo "  $0 --test               # Verify test VM at 192.168.122.50"
    echo "  $0 10.0.0.5             # Verify custom IP"
    echo "  $0 192.168.16.7 core    # Verify with specific user"
    exit 0
fi

# Override with positional arguments if provided
if [[ -n "$1" ]]; then
    NODE_IP="$1"
fi
if [[ -n "$2" ]]; then
    SSH_USER="$2"
fi

SCRIPT_DIR="$(dirname "$0")"

echo "Running full cluster verification on ${SSH_USER}@${NODE_IP}..."
echo ""

# Copy script to remote node
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SCRIPT_DIR}/verify-cluster.sh" ${SSH_USER}@${NODE_IP}:/tmp/verify-cluster.sh >/dev/null

# Run script
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${SSH_USER}@${NODE_IP} 'bash /tmp/verify-cluster.sh'
