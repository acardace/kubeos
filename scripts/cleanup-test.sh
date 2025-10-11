#!/bin/bash
# Quick cleanup script for test VM

VM_NAME="k8s-test"
NETWORK_NAME="k8s-test-vlan2"

echo "Cleaning up test environment..."

# Delete VM using kcli
sudo kcli delete vm ${VM_NAME} -y 2>/dev/null && echo "✓ VM deleted"

# Remove firewall rule if firewalld is running
if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --zone=libvirt --remove-interface=virbr-k8stest --permanent 2>/dev/null && echo "✓ Firewall rule removed"
    sudo firewall-cmd --reload 2>/dev/null
fi

sudo virsh net-destroy ${NETWORK_NAME} 2>/dev/null && echo "✓ Network stopped"
sudo virsh net-undefine ${NETWORK_NAME} 2>/dev/null && echo "✓ Network deleted"
echo "Done!"
