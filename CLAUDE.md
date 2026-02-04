# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

KubeOS is a self-updating Kubernetes operating system built on Fedora bootc for single-node bare metal deployments. It's an immutable, container-native OS that runs a complete Kubernetes cluster with automatic updates for both the OS and Kubernetes components.

**Update Flow:** Renovate monitors upstream → Opens PRs → GitHub Actions builds daily at 2 AM UTC → bootc stages updates → On reboot, `kubeadm-auto-upgrade.service` upgrades Kubernetes automatically.

## Build Commands

```bash
make build              # Build and push production image (ghcr.io)
make build-test         # Build and push test image
make test               # Deploy test VM via kcli
make test-ssh           # SSH into test VM (192.168.122.50)
make test-verify        # Run full verification on test VM
make test-kubeconfig    # Copy kubeconfig from test VM
make test-clean         # Cleanup test VM
make cluster-verify     # Verify production cluster health
make kubeconfig         # Copy kubeconfig from production
make shutdown           # Graceful cluster shutdown (drains, stops services)
make reboot             # Graceful cluster reboot
```

## Architecture

```
Containerfile → podman build → ghcr.io/acardace/kubeos:latest
                    ↓
              rootfs/ files copied into image
                    ↓
              config/build-config.yaml provides build args
```

**Build Arguments (YAML-driven via yq):**
- `KUBERNETES_VERSION`, `SUBNET_PREFIX`, `NODE_IP`, `GATEWAY_IP`, `DNS_IP`
- `CLUSTER_NAME`, `BACKUP_DISK`, `MEDIA_DISK`, `GIT_COMMIT`

**Stack:** Fedora bootc + kubeadm/kubelet/kubectl + CRI-O + Flannel CNI + systemd-networkd

## Key Directories

- `rootfs/` - Files copied into image root (systemd units, kubeadm config, network config)
- `rootfs/usr/lib/systemd/system/` - Service units (kubeadm-init, kubeadm-auto-upgrade, approve-kubelet-csr)
- `rootfs/usr/local/bin/` - Custom scripts (kubeadm-auto-upgrade.sh, approve-kubelet-csr.sh)
- `rootfs/etc/kubernetes/` - kubeadm-config.yaml and patches
- `scripts/` - Build, test, verify, shutdown, reboot automation
- `config/` - build-config.yaml (production) and build-config-test.yaml (test)

## Key Files

- `Containerfile` - Single-stage image definition with all packages and configuration
- `config/build-config.yaml` - All parametrized settings (versions, network, disks)
- `scripts/build.sh` - Main build orchestration (parses YAML, calls podman)
- `.renovaterc.json` - Renovate bot config for automated updates
- `k8s-test.bu` - Butane config for test VM (generates Ignition)

## Systemd Services

| Service | Purpose |
|---------|---------|
| `kubeadm-init.service` | Initialize cluster on first boot |
| `kubeadm-auto-upgrade.service` | Detect K8s version mismatch and auto-upgrade |
| `approve-kubelet-csr.service/timer` | Auto-approve kubelet CSRs |
| `var-mnt-backup.automount` | Automount backup disk |
| `var-mnt-media.automount` | Automount media disk |

## Network Configuration

- Uses systemd-networkd (not NetworkManager)
- VLAN 2 for Kubernetes traffic
- Production: 192.168.16.7, Test: 192.168.122.50
- Pod network: 10.244.0.0/16 (Flannel)
- Service network: 10.96.0.0/12

## Persistent Data (/var survives updates)

- `/var/lib/kubelet`, `/var/lib/etcd`, `/var/lib/containers`
- `/var/mnt/backup`, `/var/mnt/media` - External disk mounts
- `/etc` - 3-way merged on updates (local changes preserved)

## Testing Workflow

1. `make build-test` - Build test image
2. `make test` - Deploy test VM (kcli + libvirt)
3. `make test-ssh` - SSH in to debug
4. `make test-verify` - Run health checks
5. `make test-clean` - Cleanup

## CI/CD

GitHub Actions builds on:
- Daily at 2 AM UTC (scheduled)
- Pull requests (test only, no push)
- Push to main (build + push)

Images tagged: `latest` + `<kubernetes-version>` (e.g., `1.35.0`)
