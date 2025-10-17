#!/bin/bash
# Configure VLAN 2 on default libvirt bridge for a VM

set -ex

# Configuration
BRIDGE_NAME="virbr0"
VLAN_ID="2"
VM_NAME="${1:-k8s-test}"
NETWORK_NAME="${2:-default}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Configuring VLAN ${VLAN_ID} on bridge ${BRIDGE_NAME}...${NC}"

# Enable VLAN filtering on bridge
echo "Setting bridge to VLAN-aware mode..."
sudo ip link set ${BRIDGE_NAME} type bridge vlan_filtering 1

# Remove default VLAN 1 to avoid confusion
sudo bridge vlan del vid 1 dev ${BRIDGE_NAME} self 2>/dev/null || true

# PVID 2 = Port VLAN ID, untagged traffic goes to VLAN 2
sudo bridge vlan add vid ${VLAN_ID} dev ${BRIDGE_NAME} self pvid untagged

# Configure VM's vnet interface as trunk for VLAN 2
# Get the vnet interface name for this VM
VNET_IFACE=$(sudo virsh domiflist ${VM_NAME} | grep ${NETWORK_NAME} | awk '{print $1}')
if [ -n "$VNET_IFACE" ]; then
    echo "Configuring ${VNET_IFACE} as trunk for VLAN ${VLAN_ID}..."
    sudo bridge vlan del vid 1 dev ${VNET_IFACE} 2>/dev/null || true
    sudo bridge vlan add vid ${VLAN_ID} dev ${VNET_IFACE}
    echo -e "${GREEN}✓ VLAN ${VLAN_ID} configured on ${VNET_IFACE}${NC}"
else
    echo -e "${RED}⚠ Could not find vnet interface for VM ${VM_NAME}${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Bridge ${BRIDGE_NAME} configured for VLAN ${VLAN_ID}${NC}"

# Show current VLAN configuration
echo ""
echo "Current VLAN configuration:"
sudo bridge vlan show dev ${BRIDGE_NAME}
if [ -n "$VNET_IFACE" ]; then
    sudo bridge vlan show dev ${VNET_IFACE}
fi
