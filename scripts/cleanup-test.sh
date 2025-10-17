#!/bin/bash
# Quick cleanup script for test VM

SCRIPT_DIR="$(dirname "$0")"
VM_NAME="k8s-test"

echo "Cleaning up test environment..."

# Delete VM using kcli
sudo kcli delete vm ${VM_NAME} -y 2>/dev/null && echo "✓ VM deleted"

# Restore default bridge settings
echo ""
"${SCRIPT_DIR}/restore-vlan.sh" virbr0

echo ""
echo "Done!"
