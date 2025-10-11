# Makefile for Fedora bootc Kubernetes node image

.PHONY: help build test test-clean test-check test-verify test-debug remote-check remote-verify

# Default target
help:
	@echo "Fedora bootc Kubernetes Node - Available targets:"
	@echo ""
	@echo "  make build          - Build and push production image (tag=latest or TAG=version)"
	@echo "  make test           - Build and deploy test VM with isolated network"
	@echo "  make test-clean     - Clean up test VM and network"
	@echo "  make test-debug     - Show test VM debug information"
	@echo "  make test-check     - Run quick health check on test VM"
	@echo "  make test-verify    - Run full cluster verification on test VM"
	@echo "  make remote-check   - Run quick health check on production node"
	@echo "  make remote-verify  - Run full cluster verification on production node"
	@echo ""
	@echo "Examples:"
	@echo "  make build TAG=v1.34.1                        # Build with specific tag"
	@echo "  make build                                    # Build with 'latest' tag"
	@echo "  make test                                     # Deploy test environment"
	@echo "  KUBERNETES_VERSION=1.34.0 make test           # Test with older Kubernetes (for upgrade testing)"
	@echo "  make test-debug                               # Debug test VM connectivity"
	@echo "  make test-check                               # Quick check test cluster"
	@echo "  make remote-check                             # Quick check production cluster"
	@echo ""

# Build production image
build:
	@./scripts/build-production.sh $(TAG)

# Run test VM setup
test:
	@./scripts/test-vm.sh

# Clean up test environment
test-clean:
	@./scripts/cleanup-test.sh

# Debug test VM
test-debug:
	@./scripts/debug-test-vm.sh

# Remote cluster checks (production by default, use test-check/test-verify for test VM)
remote-check:
	@./scripts/remote-quick-check.sh

remote-verify:
	@./scripts/remote-verify-cluster.sh

# Test VM remote checks
test-check:
	@./scripts/remote-quick-check.sh --test

test-verify:
	@./scripts/remote-verify-cluster.sh --test
