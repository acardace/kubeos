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
REGISTRY="quay.io/acardace"

# Get tag from argument or use "latest"
IMAGE_TAG="${1:-latest}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

echo -e "${GREEN}=== Building Fedora bootc Kubernetes Production Image ===${NC}\n"
echo "Image: ${FULL_IMAGE}"
echo ""

# Step 1: Build the production image
echo -e "${YELLOW}[1/3] Building bootc image with production network (192.168.16.0/24)...${NC}"
cd "${SCRIPT_DIR}/.."

# Build with optional KUBERNETES_VERSION override
BUILD_ARGS="--build-arg SUBNET_PREFIX=192.168.16 \
    --build-arg NODE_IP=192.168.16.7 \
    --build-arg VIP_IP=192.168.16.3 \
    --build-arg GATEWAY_IP=192.168.16.1 \
    --build-arg DNS_IP=192.168.16.1 \
    --build-arg CLUSTER_NAME=home"

if [ -n "${KUBERNETES_VERSION}" ]; then
    echo "Building with Kubernetes version: ${KUBERNETES_VERSION}"
    BUILD_ARGS="${BUILD_ARGS} --build-arg KUBERNETES_VERSION=${KUBERNETES_VERSION}"
fi

podman build ${BUILD_ARGS} -t localhost/${IMAGE_NAME}:${IMAGE_TAG} .
echo -e "${GREEN}✓ Build complete${NC}\n"

# Step 2: Login to Quay
echo -e "${YELLOW}[2/3] Logging into Quay.io...${NC}"
QUAY_USER=$(bw get item quay.io | jq -r '.login.username')
QUAY_PASS=$(bw get item quay.io | jq -r '.login.password')
echo "${QUAY_PASS}" | podman login -u "${QUAY_USER}" --password-stdin quay.io
echo -e "${GREEN}✓ Logged in${NC}\n"

# Step 3: Tag and push image
echo -e "${YELLOW}[3/3] Tagging and pushing image to ${FULL_IMAGE}...${NC}"
podman tag localhost/${IMAGE_NAME}:${IMAGE_TAG} ${FULL_IMAGE}
podman push ${FULL_IMAGE}
echo -e "${GREEN}✓ Image pushed${NC}\n"

echo -e "${GREEN}=== Production Image Build Complete ===${NC}\n"
echo "Image: ${FULL_IMAGE}"
echo ""
echo "To deploy this image:"
echo "  1. Boot your bare metal server from Fedora CoreOS"
echo "  2. Login to Quay on the server:"
echo "     podman login quay.io"
echo "  3. Switch to the bootc image:"
echo "     sudo bootc switch ${FULL_IMAGE}"
echo "  4. Reboot the server:"
echo "     sudo systemctl reboot"
echo ""
