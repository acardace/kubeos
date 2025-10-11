#!/bin/bash
# Debug helper for test VM

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VM_NAME="k8s-test"
TEST_NODE_IP="10.99.16.7"

echo -e "${YELLOW}=== Test VM Debug Info ===${NC}\n"

echo -e "${BLUE}[1] VM Status:${NC}"
sudo kcli info vm ${VM_NAME} | grep -E "status|ip" || echo "VM not found"
echo ""

echo -e "${BLUE}[2] Bridge VLAN Configuration:${NC}"
sudo bridge vlan show dev virbr-k8stest
echo ""

echo -e "${BLUE}[3] Ping Test:${NC}"
if ping -c 2 -W 2 ${TEST_NODE_IP} &>/dev/null; then
    echo -e "${GREEN}✓ VM is reachable at ${TEST_NODE_IP}${NC}"
else
    echo -e "${RED}✗ Cannot ping ${TEST_NODE_IP}${NC}"
fi
echo ""

echo -e "${BLUE}[4] SSH Test:${NC}"
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 core@${TEST_NODE_IP} true 2>/dev/null; then
    echo -e "${GREEN}✓ SSH is working${NC}"
else
    echo -e "${RED}✗ Cannot SSH to ${TEST_NODE_IP}${NC}"
fi
echo ""

echo -e "${YELLOW}To access VM console:${NC}"
echo "  sudo kcli console ${VM_NAME}"
echo "  Login: core / Password: debug"
echo ""

echo -e "${YELLOW}Manual bridge VLAN fix (if needed):${NC}"
echo "  sudo bridge vlan del vid 1 dev virbr-k8stest self"
echo "  sudo bridge vlan add vid 2 dev virbr-k8stest self pvid untagged"
echo ""
