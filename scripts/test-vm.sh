#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(dirname "$0")"
VM_NAME="k8s-test"
NETWORK_NAME="default"
REGISTRY="quay.io/acardace"
IMAGE_NAME="kubeos"

# Test network configuration (using default libvirt network)
TEST_SUBNET_PREFIX="192.168.122"
TEST_NODE_IP="${TEST_SUBNET_PREFIX}.50"
TEST_GATEWAY_IP="${TEST_SUBNET_PREFIX}.1"

# Kubernetes version (can be overridden with KUBERNETES_VERSION env var for testing upgrades)
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"

echo -e "${GREEN}=== Fedora bootc Kubernetes Test VM Setup ===${NC}\n"

# Cleanup ignition file on exit
IGNITION_FILE="${SCRIPT_DIR}/../${VM_NAME}.ign"
trap "rm -f ${IGNITION_FILE}" EXIT

# Step 1: Convert Butane config to Ignition
echo -e "${YELLOW}[1/7] Converting Butane config to Ignition...${NC}"
podman run --interactive --rm --security-opt label=disable \
    --volume "${SCRIPT_DIR}/..:/pwd" --workdir /pwd quay.io/coreos/butane:release \
    --pretty --strict k8s-test.bu > "${IGNITION_FILE}"
echo -e "${GREEN}✓ Ignition file created${NC}\n"

# Step 2: Build the test image using build.sh
echo -e "${YELLOW}[2/7] Building bootc test image...${NC}"
if [ -n "$KUBERNETES_VERSION" ]; then
    echo "Kubernetes version: ${KUBERNETES_VERSION}"
    FULL_IMAGE=$(cd "$SCRIPT_DIR" && ./build.sh --test --kube-version "$KUBERNETES_VERSION" | tail -1)
else
    echo "Kubernetes version: default from Containerfile"
    FULL_IMAGE=$(cd "$SCRIPT_DIR" && ./build.sh --test | tail -1)
fi
echo -e "${GREEN}✓ Build complete${NC}"
echo "Image: ${FULL_IMAGE}"
echo ""

# Step 3: Create VM from Fedora CoreOS with Ignition
echo -e "${YELLOW}[3/7] Creating VM '${VM_NAME}' from Fedora CoreOS with Ignition config...${NC}"
if sudo kcli list vm 2>/dev/null | grep -qw "${VM_NAME}"; then
    echo "VM ${VM_NAME} already exists, deleting..."
    sudo kcli delete vm ${VM_NAME} -y
fi

sudo kcli create vm ${VM_NAME} \
    -i fcos \
    -P memory=8192 \
    -P cores=4 \
    -P disks=[30,10,10,10,10,10] \
    -P nets=[${NETWORK_NAME}] \
    -P keys=['ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOeHlYMy97S9KKda5QdORi6wujhntAoFXIbfrF+rn9CK antonio@mushu'] || {
        echo -e "${RED}ERROR: Failed to create VM${NC}"
        exit 1
    }

echo -e "${GREEN}✓ VM created (ignition configured password and disks)${NC}\n"

# Step 4: Wait for VM to be accessible after ignition
echo -e "${YELLOW}[4/7] Waiting for VM to complete ignition setup...${NC}"

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

echo -e "${GREEN}✓ VM ready${NC}\n"

# Step 5: Switch to kubeos image
echo -e "${YELLOW}[5/7] Switching VM to kubernetes bootc image...${NC}"

# Get Quay credentials
QUAY_USER=$(bw get item quay.io | jq -r '.login.username')
QUAY_PASS=$(bw get item quay.io | jq -r '.login.password')

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

# Step 6: Configure VLAN
echo -e "${YELLOW}[6/7] Configuring VLAN 2...${NC}"
"${SCRIPT_DIR}/configure-vlan.sh" ${VM_NAME} ${NETWORK_NAME}
echo ""

# Step 7: Wait for VM to be ready
echo -e "${YELLOW}[7/7] Waiting for VM to become reachable and Kubernetes to start...${NC}"
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
echo "  Network: ${NETWORK_NAME} (${TEST_SUBNET_PREFIX}.0/24, using default libvirt network with VLAN 2)"
echo "  VM IP: ${TEST_NODE_IP}"
echo "  Host IP: ${TEST_GATEWAY_IP} (gateway on virbr0)"
echo "  Image: ${FULL_IMAGE}"
echo ""
echo "Access methods from your laptop:"
echo "  1. SSH: ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@${TEST_NODE_IP}"
echo "  2. Ping VM: ping ${TEST_NODE_IP}"
echo "  3. Access K8s API: curl -k https://${TEST_NODE_IP}:6443"
echo "  4. Console: sudo virsh console ${VM_NAME}  (login: core / password: debug)"
echo ""
echo "Check kubernetes status remotely from laptop:"
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
