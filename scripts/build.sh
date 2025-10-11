#!/bin/bash
# Unified build script for KubeOS images (production and test)
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
IMAGE_NAME="kubeos"
REGISTRY="quay.io/acardace"
SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="${SCRIPT_DIR}/.."

# Default config file (production)
CONFIG_FILE="${REPO_ROOT}/build-config.yaml"

# Parse arguments
CUSTOM_TAG=""
SKIP_TAG=false
SKIP_PUSH=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --test)
            CONFIG_FILE="${REPO_ROOT}/build-config-test.yaml"
            shift
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --tag)
            CUSTOM_TAG="$2"
            shift 2
            ;;
        --skip-tag)
            SKIP_TAG=true
            shift
            ;;
        --skip-push)
            SKIP_PUSH=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Build and push KubeOS container images"
            echo ""
            echo "Options:"
            echo "  --test                    Use test build configuration"
            echo "  --config FILE             Path to build config YAML file"
            echo "  --tag TAG                 Custom tag (default: latest for prod, <version>-test-<sha> for test)"
            echo "  --skip-tag                Build only, don't tag"
            echo "  --skip-push               Build and tag, but don't push to registry"
            echo "  -h, --help                Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Build production image (latest)"
            echo "  $0 --tag v1.34.1                      # Build production with specific tag"
            echo "  $0 --test                             # Build test image"
            echo "  $0 --skip-tag                         # Build only, no tag"
            echo "  $0 --skip-push                        # Build and tag, but don't push (CI)"
            echo "  $0 --config my-config.yaml            # Build with custom config"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run '$0 --help' for usage"
            exit 1
            ;;
    esac
done

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}ERROR: Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Check if yq is available
if ! command -v yq &> /dev/null; then
    echo -e "${RED}ERROR: yq is not installed. Please install yq to parse YAML config files.${NC}"
    echo "Install with: brew install yq"
    exit 1
fi

# Read configuration from YAML file
echo -e "${BLUE}Reading configuration from: $CONFIG_FILE${NC}"
KUBERNETES_VERSION=$(yq eval '.kubernetes_version' "$CONFIG_FILE")
SUBNET_PREFIX=$(yq eval '.network.subnet_prefix' "$CONFIG_FILE")
NODE_IP=$(yq eval '.network.node_ip' "$CONFIG_FILE")
GATEWAY_IP=$(yq eval '.network.gateway_ip' "$CONFIG_FILE")
DNS_IP=$(yq eval '.network.dns_ip' "$CONFIG_FILE")
CLUSTER_NAME=$(yq eval '.network.cluster_name' "$CONFIG_FILE")
BACKUP_DISK=$(yq eval '.disks.backup' "$CONFIG_FILE")
MEDIA_DISK=$(yq eval '.disks.media' "$CONFIG_FILE")

# Determine if this is a test build based on config file name
MODE="production"
if [[ "$CONFIG_FILE" == *"test"* ]]; then
    MODE="test"
fi

# Determine image tag
if [ -n "$CUSTOM_TAG" ]; then
    IMAGE_TAG="$CUSTOM_TAG"
elif [ "$MODE" = "test" ]; then
    # For test builds, use version-test-<sha> format
    cd "$REPO_ROOT"
    GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    if [ "$GIT_SHA" = "unknown" ]; then
        echo -e "${RED}ERROR: Not in a git repository${NC}"
        exit 1
    fi
    IMAGE_TAG="${KUBERNETES_VERSION}-test-${GIT_SHA}"
    cd - >/dev/null
else
    # Production: use "latest"
    IMAGE_TAG="latest"
fi

LOCAL_IMAGE="localhost/${IMAGE_NAME}:${IMAGE_TAG}"
REMOTE_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

# Print build info
echo -e "${GREEN}=== Building KubeOS Image ===${NC}\n"
echo "Mode: ${MODE}"
echo "Config: $(basename $CONFIG_FILE)"
echo "Image: ${REMOTE_IMAGE}"
echo "Kubernetes: ${KUBERNETES_VERSION}"
echo "Network: ${SUBNET_PREFIX}.0/24"
echo "Node IP: ${NODE_IP}"
echo "Cluster: ${CLUSTER_NAME}"
echo ""

# Step 1: Build the image
echo -e "${YELLOW}[1/3] Building container image...${NC}"
cd "${REPO_ROOT}"

BUILD_ARGS="--build-arg KUBERNETES_VERSION=${KUBERNETES_VERSION} \
    --build-arg SUBNET_PREFIX=${SUBNET_PREFIX} \
    --build-arg NODE_IP=${NODE_IP} \
    --build-arg GATEWAY_IP=${GATEWAY_IP} \
    --build-arg DNS_IP=${DNS_IP} \
    --build-arg CLUSTER_NAME=${CLUSTER_NAME} \
    --build-arg BACKUP_DISK=${BACKUP_DISK} \
    --build-arg MEDIA_DISK=${MEDIA_DISK}"

podman build ${BUILD_ARGS} -t "${LOCAL_IMAGE}" .
echo -e "${GREEN}✓ Build complete${NC}"
echo ""

# Exit early if skip-tag is set
if [ "$SKIP_TAG" = true ]; then
    echo -e "${YELLOW}Skipping tag and push (--skip-tag specified)${NC}\n"
    echo "Local image: ${LOCAL_IMAGE}"
    exit 0
fi

# Step 2: Tag image for registry
echo -e "${YELLOW}[2/3] Tagging image...${NC}"
podman tag "${LOCAL_IMAGE}" "${REMOTE_IMAGE}"

# For production builds with latest tag, also tag with version
if [ "$MODE" = "production" ] && [ "$IMAGE_TAG" = "latest" ]; then
    VERSION_TAG="${KUBERNETES_VERSION}"
    REMOTE_VERSION_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION_TAG}"
    podman tag "${LOCAL_IMAGE}" "${REMOTE_VERSION_IMAGE}"
    echo -e "${GREEN}✓ Tagged: ${REMOTE_IMAGE}${NC}"
    echo -e "${GREEN}✓ Tagged: ${REMOTE_VERSION_IMAGE}${NC}"
else
    echo -e "${GREEN}✓ Tagged: ${REMOTE_IMAGE}${NC}"
fi
echo ""

# Exit if we shouldn't push to registry
if [ "$SKIP_PUSH" = true ]; then
    echo -e "${YELLOW}Skipping registry push (--skip-push specified)${NC}\n"
    echo "Tagged images:"
    echo "  ${REMOTE_IMAGE}"
    if [ "$MODE" = "production" ] && [ "$IMAGE_TAG" = "latest" ]; then
        echo "  ${REMOTE_VERSION_IMAGE}"
    fi
    exit 0
fi

# Step 3: Login to Quay and push
echo -e "${YELLOW}[3/3] Logging into Quay.io and pushing...${NC}"
if ! podman login quay.io --get-login &>/dev/null; then
    QUAY_USER=$(bw get item quay.io | jq -r '.login.username')
    QUAY_PASS=$(bw get item quay.io | jq -r '.login.password')
    echo "${QUAY_PASS}" | podman login -u "${QUAY_USER}" --password-stdin quay.io
    echo -e "${GREEN}✓ Logged in${NC}"
else
    echo -e "${BLUE}Already logged in${NC}"
fi

podman push "${REMOTE_IMAGE}"
echo -e "${GREEN}✓ Pushed: ${REMOTE_IMAGE}${NC}"

if [ "$MODE" = "production" ] && [ "$IMAGE_TAG" = "latest" ]; then
    podman push "${REMOTE_VERSION_IMAGE}"
    echo -e "${GREEN}✓ Pushed: ${REMOTE_VERSION_IMAGE}${NC}"
fi
echo ""

echo -e "${GREEN}=== Build Complete ===${NC}\n"
echo "Images:"
echo "  Local:  ${LOCAL_IMAGE}"
echo "  Remote: ${REMOTE_IMAGE}"
if [ "$MODE" = "production" ] && [ "$IMAGE_TAG" = "latest" ]; then
    echo "  Remote: ${REMOTE_VERSION_IMAGE}"
fi
echo ""

if [ "$MODE" = "production" ]; then
    echo "To deploy this image:"
    echo "  1. Boot server from Fedora CoreOS live ISO"
    echo "  2. Login to Quay: podman login quay.io"
    echo "  3. Switch: sudo bootc switch ${REMOTE_IMAGE}"
    echo "  4. Reboot: sudo systemctl reboot"
else
    echo "Test image ready for VM deployment"
    echo "Use: ./scripts/test-vm.sh (will use this image)"
fi
echo ""

# Output image name for other scripts to consume
echo "${REMOTE_IMAGE}"
