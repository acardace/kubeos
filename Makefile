# Makefile for KubeOS - Fedora bootc Kubernetes image

.PHONY: help build build-test test test-ssh test-kubeconfig test-clean test-verify cluster-verify kubeconfig

# Default target
help:
	@echo "KubeOS - Available targets:"
	@echo ""
	@echo "  make build                - Build and push production image"
	@echo "  make build-test           - Build and push test image"
	@echo "  make test                 - Build and deploy test VM with isolated network"
	@echo "  make test-ssh             - SSH into test VM"
	@echo "  make test-kubeconfig      - Copy kubeconfig from test VM to local directory"
	@echo "  make test-clean           - Clean up test VM and network"
	@echo "  make test-verify          - Run full cluster verification on test VM"
	@echo "  make cluster-verify       - Run full cluster verification on production node"
	@echo "  make kubeconfig           - Copy kubeconfig from production cluster"
	@echo ""
	@echo "Build options:"
	@echo "  TAG=<tag>                 Custom tag for production build (default: latest)"
	@echo ""
	@echo "Examples:"
	@echo "  make build TAG=v1.34.1                    # Build production with specific tag"
	@echo "  make build-test                           # Build test image"
	@echo "  make test                                 # Deploy test environment"
	@echo "  make test-verify                          # Verify test cluster"
	@echo "  make cluster-verify                       # Verify production cluster"
	@echo ""

# Build production image
build:
ifdef TAG
	@./scripts/build.sh --tag $(TAG)
else
	@./scripts/build.sh
endif

# Build test image
build-test:
	@./scripts/build.sh --test

# Run test VM setup
test:
	@./scripts/test-vm.sh

# SSH into test VM
test-ssh:
	@ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@192.168.122.50

# Copy kubeconfig from test VM
test-kubeconfig:
	@scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@192.168.122.50:/var/home/core/.kube/config kubeconfig
	@echo "Kubeconfig copied to ./kubeconfig"

# Clean up test environment
test-clean:
	@./scripts/cleanup-test.sh

# Cluster verification (production)
cluster-verify:
	@./scripts/remote-verify-cluster.sh

# Test VM verification
test-verify:
	@./scripts/remote-verify-cluster.sh --test

# Copy kubeconfig from production cluster
kubeconfig:
	@scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@192.168.16.7:/var/home/core/.kube/config kubeconfig
	@echo "Kubeconfig copied to ./kubeconfig"
