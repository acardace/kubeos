#!/bin/bash
# Kubernetes Cluster Verification Script

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0

check() {
    local name="$1"
    shift
    echo -ne "${BLUE}[CHECK]${NC} $name... "
    if "$@" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC}"
        ((FAILED++))
        return 1
    fi
}

check_output() {
    local name="$1"
    local expected="$2"
    shift 2
    echo -ne "${BLUE}[CHECK]${NC} $name... "
    local output=$("$@" 2>/dev/null)
    if [[ "$output" == *"$expected"* ]]; then
        echo -e "${GREEN}✓${NC}"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} (got: $output, expected: $expected)"
        ((FAILED++))
        return 1
    fi
}

section() {
    echo ""
    echo -e "${YELLOW}=== $1 ===${NC}"
}

section "System Services"
check "CRI-O service running" systemctl is-active crio.service
check "Kubelet service running" systemctl is-active kubelet.service
check "systemd-networkd running" systemctl is-active systemd-networkd.service
check "SSH service running" systemctl is-active sshd.service

section "Network Configuration"
check "VLAN interface exists" ip link show vlan2
check "VLAN has IP address" ip addr show vlan2 | grep -q "inet "
if ip addr show vlan2 | grep -q "192.168.16.7"; then
    echo -e "${BLUE}[INFO]${NC} Node IP: 192.168.16.7 (production)"
elif ip addr show vlan2 | grep -q "10.99.16.7"; then
    echo -e "${BLUE}[INFO]${NC} Node IP: 10.99.16.7 (test)"
else
    echo -e "${YELLOW}[WARN]${NC} Unexpected IP on vlan2"
fi

section "Kubernetes API"
check "API server responding" kubectl get --raw /healthz

section "Cluster Status"
check "Node is Ready" kubectl get nodes | grep -q "Ready"
NODE_NAME=$(kubectl get nodes -o name | head -1)
KUBE_VERSION=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
echo -e "${BLUE}[INFO]${NC} Node name: $NODE_NAME"
echo -e "${BLUE}[INFO]${NC} Kubernetes version: $KUBE_VERSION"
((PASSED++))

section "Node Labels"
check "Worker role label" sh -c "kubectl get $NODE_NAME -o jsonpath='{.metadata.labels}' | grep -q 'node-role.kubernetes.io/worker'"
check "Disk backup label" sh -c "kubectl get $NODE_NAME -o jsonpath='{.metadata.labels}' | grep -q 'home.k8s/disk-backup'"
check "Disk media label" sh -c "kubectl get $NODE_NAME -o jsonpath='{.metadata.labels}' | grep -q 'home.k8s/disk-media'"
check "Coral TPU label" sh -c "kubectl get $NODE_NAME -o jsonpath='{.metadata.labels}' | grep -q 'home.k8s/device.*coral-tpu'"
check "iGPU label" sh -c "kubectl get $NODE_NAME -o jsonpath='{.metadata.labels}' | grep -q 'home.k8s/device-igpu'"

section "System Pods"
check "kube-apiserver running" sh -c "kubectl -n kube-system get pod -l component=kube-apiserver | grep -q '1/1.*Running'"
check "kube-controller-manager running" sh -c "kubectl -n kube-system get pod -l component=kube-controller-manager | grep -q '1/1.*Running'"
check "kube-scheduler running" sh -c "kubectl -n kube-system get pod -l component=kube-scheduler | grep -q '1/1.*Running'"
check "etcd running" sh -c "kubectl -n kube-system get pod -l component=etcd | grep -q '1/1.*Running'"
check "kube-proxy running" sh -c "kubectl -n kube-system get pod -l k8s-app=kube-proxy | grep -q '1/1.*Running'"
check "Flannel CNI running" sh -c "kubectl -n kube-flannel get pod -l app=flannel | grep -q '1/1.*Running'"
check "CoreDNS running" sh -c "kubectl -n kube-system get pod -l k8s-app=kube-dns | grep -q 'Running'"
check "CoreDNS ready" sh -c "kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -q 'True'"

section "Feature Gates & Configuration"
check "User namespace support enabled" sh -c "grep -q 'UserNamespacesSupport: true' /var/lib/kubelet/config.yaml"
check "Seccomp default enabled" sh -c "grep -q 'seccompDefault: true' /var/lib/kubelet/config.yaml"

section "Container Runtime"
check_output "CRI-O runtime" "cri-o" sh -c "kubectl get $NODE_NAME -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}'"

section "Networking"
check "Pod network configured" sh -c "kubectl cluster-info dump | grep -q '10.244.0.0/16'"
check "Service network configured" sh -c "kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' | grep -q '10.96'"

section "Cluster Services"
check "Kubernetes service exists" kubectl get svc kubernetes
check "kube-dns service exists" kubectl -n kube-system get svc kube-dns

section "Certificate Rotation"
check "Kubelet client cert rotation enabled" sh -c "grep -q 'rotateCertificates: true' /var/lib/kubelet/config.yaml"
check "Server cert bootstrap enabled" sh -c "grep -q 'serverTLSBootstrap: true' /var/lib/kubelet/config.yaml"

section "Storage Mounts (if configured)"
if [ -d "/var/mnt/backup" ]; then
    check "Backup mount exists" mountpoint -q /var/mnt/backup
fi
if [ -d "/var/mnt/media" ]; then
    check "Media mount exists" mountpoint -q /var/mnt/media
fi

section "Auto-upgrade Service"
check "Auto-upgrade service exists" sh -c "systemctl list-unit-files | grep -q kubeadm-auto-upgrade.service"
check "Auto-upgrade service enabled" systemctl is-enabled kubeadm-auto-upgrade.service

section "Taints & Scheduling"
echo -ne "${BLUE}[CHECK]${NC} Control plane can schedule workloads... "
TAINTS=$(kubectl get "$NODE_NAME" -o jsonpath='{.spec.taints}')
if [[ -z "$TAINTS" || "$TAINTS" == "null" ]]; then
    echo -e "${GREEN}✓${NC} (no taints)"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠${NC} (taints present: $TAINTS)"
fi

echo ""
echo -e "${YELLOW}=== Summary ===${NC}"
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"

if [ $FAILED -eq 0 ]; then
    echo -e "\n${GREEN}✓ All checks passed! Cluster is healthy.${NC}"
    exit 0
else
    echo -e "\n${RED}✗ Some checks failed. Review the output above.${NC}"
    exit 1
fi
