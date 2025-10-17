#!/bin/bash
# Restore default VLAN configuration on libvirt bridge

set -e

# Configuration
BRIDGE_NAME="${1:-virbr0}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Restoring default VLAN configuration on ${BRIDGE_NAME}...${NC}"

# Disable VLAN filtering
sudo ip link set ${BRIDGE_NAME} type bridge vlan_filtering 0 2>/dev/null

# Restore VLAN 1 as default
sudo bridge vlan add vid 1 dev ${BRIDGE_NAME} self pvid untagged 2>/dev/null || true
sudo bridge vlan del vid 2 dev ${BRIDGE_NAME} self 2>/dev/null || true

echo -e "${GREEN}✓ Default VLAN configuration restored on ${BRIDGE_NAME}${NC}"

# Show current configuration
echo ""
echo "Current bridge configuration:"
sudo ip link show ${BRIDGE_NAME} | grep -i vlan || echo "VLAN filtering disabled"
