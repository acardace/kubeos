#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
IMAGE_NAME="k8s-node"
SCRIPT_DIR="$(dirname "$0")"

# Kubernetes version (can be overridden with KUBERNETES_VERSION env var for testing upgrades)
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.34.1}"

# Get git SHA for deterministic tagging
cd "${SCRIPT_DIR}/../.."
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
if [ "$GIT_SHA" = "unknown" ]; then
    echo -e "${RED}ERROR: Not in a git repository${NC}"
    exit 1
fi
IMAGE_TAG="test-vm-${GIT_SHA}"
cd - >/dev/null

REGISTRY="quay.io/acardace"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
VM_NAME="k8s-test"
NETWORK_NAME="k8s-test-vlan2"

# Test network configuration (different from production)
TEST_SUBNET_PREFIX="10.99.16"
TEST_NODE_IP="${TEST_SUBNET_PREFIX}.7"
TEST_GATEWAY_IP="${TEST_SUBNET_PREFIX}.1"
TEST_CLUSTER_NAME="home-test"

echo -e "${GREEN}=== Fedora bootc Kubernetes Test VM Setup ===${NC}\n"

# Step 1: Build the image with test network configuration
echo -e "${YELLOW}[1/7] Building bootc image with test network (${TEST_SUBNET_PREFIX}.0/24)...${NC}"
echo "Image tag: ${IMAGE_TAG} (git SHA: ${GIT_SHA})"
echo "Kubernetes version: ${KUBERNETES_VERSION}"

# Check if image already exists locally
if podman image exists localhost/${IMAGE_NAME}:${IMAGE_TAG}; then
    echo -e "${BLUE}Image localhost/${IMAGE_NAME}:${IMAGE_TAG} already exists, skipping build${NC}"
else
    cd "${SCRIPT_DIR}/.."
    podman build \
        --build-arg KUBERNETES_VERSION=${KUBERNETES_VERSION} \
        --build-arg SUBNET_PREFIX=${TEST_SUBNET_PREFIX} \
        --build-arg NODE_IP=${TEST_NODE_IP} \
        --build-arg GATEWAY_IP=${TEST_GATEWAY_IP} \
        --build-arg DNS_IP=${TEST_GATEWAY_IP} \
        --build-arg CLUSTER_NAME=${TEST_CLUSTER_NAME} \
        --build-arg BACKUP_DISK=/dev/vdb1 \
        --build-arg MEDIA_DISK=/dev/vdc1 \
        -t localhost/${IMAGE_NAME}:${IMAGE_TAG} .
    echo -e "${GREEN}✓ Build complete${NC}"
fi
echo ""

# Step 2: Create isolated network matching VLAN 2 setup
echo -e "${YELLOW}[2/7] Creating isolated network (${TEST_SUBNET_PREFIX}.0/24)...${NC}"
if sudo virsh net-info ${NETWORK_NAME} &>/dev/null; then
    echo "Network ${NETWORK_NAME} already exists, deleting..."
    sudo virsh net-destroy ${NETWORK_NAME} 2>/dev/null || true
    sudo virsh net-undefine ${NETWORK_NAME}
fi
sudo virsh net-define "${SCRIPT_DIR}/test-network.xml"
sudo virsh net-start ${NETWORK_NAME}
sudo virsh net-autostart ${NETWORK_NAME}

# Configure firewalld to allow traffic to the bridge
if systemctl is-active --quiet firewalld; then
    echo "Configuring firewall for test network..."
    sudo firewall-cmd --zone=libvirt --add-interface=virbr-k8stest --permanent 2>/dev/null || true
    sudo firewall-cmd --reload
fi

echo -e "${GREEN}✓ Test network created${NC}\n"

# Step 3: Login to Quay
echo -e "${YELLOW}[3/7] Logging into Quay.io...${NC}"
QUAY_USER=$(bw get item quay.io | jq -r '.login.username')
QUAY_PASS=$(bw get item quay.io | jq -r '.login.password')
echo "${QUAY_PASS}" | podman login -u "${QUAY_USER}" --password-stdin quay.io
echo -e "${GREEN}✓ Logged in${NC}\n"

# Step 4: Tag and push image
echo -e "${YELLOW}[4/7] Tagging and pushing image to ${FULL_IMAGE}...${NC}"
podman tag localhost/${IMAGE_NAME}:${IMAGE_TAG} ${FULL_IMAGE}
podman push ${FULL_IMAGE}
echo -e "${GREEN}✓ Image pushed${NC}\n"

# Step 5: Create VM from Fedora CoreOS
echo -e "${YELLOW}[5/7] Creating VM '${VM_NAME}' from Fedora CoreOS...${NC}"
if sudo kcli list vm 2>/dev/null | grep -qw "${VM_NAME}"; then
    echo "VM ${VM_NAME} already exists, deleting..."
    sudo kcli delete vm ${VM_NAME} -y
fi

sudo kcli create vm ${VM_NAME} \
    -i fcos \
    -P memory=4096 \
    -P cores=2 \
    -P disks=[30,10,10,10,10,10] \
    -P nets=[${NETWORK_NAME}] \
    -P keys=['ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOeHlYMy97S9KKda5QdORi6wujhntAoFXIbfrF+rn9CK antonio@mushu'] || {
        echo -e "${RED}ERROR: Failed to create VM${NC}"
        exit 1
    }

echo -e "${GREEN}✓ VM created${NC}\n"

# Step 6: Wait for VM network and set password
echo -e "${YELLOW}[6/7] Waiting for VM to be accessible and setting password...${NC}"

# Wait for VM to get an IP address
echo "Waiting for VM to get an IP address..."
MAX_RETRIES=30
RETRY_COUNT=0
VM_IP=""
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    VM_IP=$(sudo kcli get vm -P name=${VM_NAME} -o json | jq -r .[0].ip)
    if [ -n "$VM_IP" ] && [ "$VM_IP" != "null" ]; then
        echo "VM IP: ${VM_IP}"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        sleep 2
    fi
done

if [ -z "$VM_IP" ] || [ "$VM_IP" = "null" ]; then
    echo -e "${RED}ERROR: VM did not get an IP address after ${MAX_RETRIES} attempts${NC}"
    exit 1
fi

# Wait for SSH to be available
echo "Waiting for SSH to be available..."
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 core@${VM_IP} true 2>/dev/null; then
        echo -e "${GREEN}✓ SSH available${NC}"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        sleep 2
    fi
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}ERROR: SSH did not become available after ${MAX_RETRIES} attempts${NC}"
    exit 1
fi

# Set password for core user before bootc switch
# This will be preserved through the 3-way merge
echo "Setting password for core user in FCOS..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@${VM_IP} << 'EOSSH'
echo 'core:debug' | sudo chpasswd
EOSSH

echo -e "${GREEN}✓ Password set${NC}\n"

# Partition and format disks for backup and media
echo "Partitioning and formatting backup and media disks..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@${VM_IP} << 'EOSSH'
# Partition disks (create single partition on each)
echo "Creating partitions..."
echo -e "g\nn\n\n\n\nw\n" | sudo fdisk /dev/vdb
echo -e "g\nn\n\n\n\nw\n" | sudo fdisk /dev/vdc

# Wait for partitions to appear
echo "Waiting for partitions to appear..."
MAX_RETRIES=10
for dev in vdb1 vdc1; do
    RETRY_COUNT=0
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if [ -b /dev/$dev ]; then
            echo "/dev/$dev is ready"
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            sleep 1
        fi
    done
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "ERROR: /dev/$dev did not appear after ${MAX_RETRIES} attempts"
        exit 1
    fi
done

# Format partitions with XFS
echo "Formatting partitions with XFS..."
sudo mkfs.xfs -f /dev/vdb1
sudo mkfs.xfs -f /dev/vdc1

echo "Disks formatted and ready"
EOSSH

echo -e "${GREEN}✓ Disks formatted${NC}\n"

# Step 7: Switch to k8s image
echo -e "${YELLOW}[7/7] Switching VM to kubernetes bootc image...${NC}"

# Create credentials file for podman login inside VM
CREDS_FILE=$(mktemp)
cat > ${CREDS_FILE} << EOF
${QUAY_PASS}
EOF

# Copy credentials and switch image
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${CREDS_FILE} core@${VM_IP}:/tmp/quay-pass
rm ${CREDS_FILE}

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@${VM_IP} << EOSSH || true
set -e
echo "Logging into Quay registry..."
cat /tmp/quay-pass | sudo podman login --authfile /etc/ostree/auth.json -u ${QUAY_USER} --password-stdin quay.io
rm /tmp/quay-pass

echo "Switching to ${FULL_IMAGE}..."
sudo bootc switch --apply ${FULL_IMAGE}
EOSSH

echo -e "${GREEN}✓ VM rebooting to new image${NC}\n"

echo "Waiting for VM to reboot..."

# Configure bridge to be VLAN-aware after bootc switch
# Now the VM will use VLAN 2 tagged traffic, bridge needs to handle it
echo -e "${YELLOW}Configuring VLAN-aware bridge for bootc image...${NC}"
echo "Setting bridge to VLAN-aware mode..."
sudo ip link set virbr-k8stest type bridge vlan_filtering 1
# Remove default VLAN 1 to avoid confusion
sudo bridge vlan del vid 1 dev virbr-k8stest self 2>/dev/null || true
# PVID 2 = Port VLAN ID, untagged traffic goes to VLAN 2
sudo bridge vlan add vid 2 dev virbr-k8stest self pvid untagged

# Configure VM's vnet interface as trunk for VLAN 2
# Get the vnet interface name for this VM
VNET_IFACE=$(sudo virsh domiflist ${VM_NAME} | grep ${NETWORK_NAME} | awk '{print $1}')
if [ -n "$VNET_IFACE" ]; then
    echo "Configuring ${VNET_IFACE} as trunk for VLAN 2..."
    sudo bridge vlan del vid 1 dev ${VNET_IFACE} 2>/dev/null || true
    sudo bridge vlan add vid 2 dev ${VNET_IFACE}
    echo "VM interface VLAN configuration:"
    sudo bridge vlan show dev ${VNET_IFACE}
else
    echo -e "${RED}⚠ Could not find vnet interface for VM${NC}"
fi

echo "Bridge VLAN configuration:"
sudo bridge vlan show dev virbr-k8stest
echo -e "${GREEN}✓ Bridge configured for VLAN 2 (host uses untagged, guest uses tagged)${NC}\n"

# Wait for VM to be reachable and Kubernetes to initialize
echo -e "${YELLOW}Waiting for VM to become reachable...${NC}"
MAX_RETRIES=60
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if ping -c 1 -W 2 ${TEST_NODE_IP} &>/dev/null; then
        echo -e "${GREEN}✓ VM is reachable at ${TEST_NODE_IP}${NC}"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        sleep 2
    fi
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}⚠ VM did not become reachable at ${TEST_NODE_IP} after ${MAX_RETRIES} attempts${NC}"
    echo "Check with: sudo kcli console ${VM_NAME}"
else
    # VM is reachable, now wait for Kubernetes API
    echo "Waiting for Kubernetes API to be ready..."
    MAX_RETRIES=30
    RETRY_COUNT=0
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if curl -k -s --connect-timeout 2 https://${TEST_NODE_IP}:6443/healthz &>/dev/null; then
            echo -e "${GREEN}✓ Kubernetes API is responding${NC}"
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            sleep 2
        fi
    done

    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo -e "${YELLOW}⚠ Kubernetes API did not respond after ${MAX_RETRIES} attempts${NC}"
        echo "This may be normal if Kubernetes is still initializing. Check logs with:"
        echo "  ssh core@${TEST_NODE_IP} journalctl -u kubeadm-init.service -f"
    fi
fi
echo ""

echo -e "${GREEN}=== Test VM Setup Complete ===${NC}\n"
echo "VM Details:"
echo "  Name: ${VM_NAME}"
echo "  Network: ${NETWORK_NAME} (${TEST_SUBNET_PREFIX}.0/24, isolated from real network)"
echo "  VM IP: ${TEST_NODE_IP}"
echo "  Host IP: ${TEST_GATEWAY_IP} (your laptop on the test bridge)"
echo "  Image: ${FULL_IMAGE}"
echo ""
echo "Access methods from your laptop:"
echo "  1. SSH: ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@${TEST_NODE_IP}"
echo "  2. Ping VM: ping ${TEST_NODE_IP}"
echo "  3. Access K8s API: curl -k https://${TEST_NODE_IP}:6443"
echo "  4. Console: sudo virsh console ${VM_NAME}  (login: core / password: debug)"
echo ""
echo "Check kubernetes status remotely from laptop:"
echo "  ${SCRIPT_DIR}/remote-quick-check.sh --test           # Quick health check"
echo "  ${SCRIPT_DIR}/remote-verify-cluster.sh --test        # Full verification"
echo ""
echo "Or check directly on the VM:"
echo "  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@${TEST_NODE_IP} journalctl -u kubeadm-init.service -f"
echo "  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@${TEST_NODE_IP} kubectl get nodes"
echo ""
echo "Get kubeconfig to your laptop:"
echo "  scp core@${TEST_NODE_IP}:/etc/kubernetes/admin.conf ./test-kubeconfig"
echo "  export KUBECONFIG=\$PWD/test-kubeconfig"
echo "  kubectl get nodes"
echo ""
echo "Clean up when done:"
echo "  ${SCRIPT_DIR}/cleanup-test.sh"
