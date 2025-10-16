# KubeOS

A self-updating Kubernetes operating system built on Fedora bootc, designed for single-node bare metal deployments.

## What is this?

KubeOS is an immutable, container-native OS image that runs a complete Kubernetes cluster.

## Key Features

### 🔄 Automatic Updates
- **OS updates**: Fedora updates pulled daily via GitHub Actions + Renovate
- **Kubernetes updates**: Managed by Renovate, auto-applied on boot via `kubeadm-auto-upgrade.service`
- **Zero manual intervention**: Just reboot when ready - updates apply automatically
- **Atomic rollback**: If something breaks, `bootc rollback` restores previous version

### 📦 What's Included
- Kubernetes (kubeadm, kubelet, kubectl)
- CRI-O container runtime
- Flannel CNI (10.244.0.0/16 pod network)
- Automatic kubelet CSR approval
- Pre-configured systemd-networkd
- SSH access with your public key

### 🎯 Production Configuration
The image is built with production defaults:
- **Node IP**: 192.168.16.7
- **Cluster name**: home
- **Pod subnet**: 10.244.0.0/16
- **Service subnet**: 10.96.0.0/12
- **Storage mounts**: `/var/mnt/backup`, `/var/mnt/media`
- **Node labels**: `home.k8s/disk-backup`, `home.k8s/disk-media`, `home.k8s/device=coral-tpu`, `home.k8s/device-igpu`

## How It Works

### Build Process
1. **GitHub Actions** runs daily at 2 AM UTC
2. Builds container image from Fedora bootc base
3. Installs Kubernetes packages from upstream repos
4. Copies configuration files from `rootfs/`
5. Pushes to `quay.io/acardace/kubeos:latest` and `kubeos:<k8s-version>`

### Update Process
1. **Renovate bot** monitors:
   - Fedora bootc base image updates
   - Kubernetes package updates in the official repos
2. Opens PRs when updates are available
3. Merge PR → GitHub Action builds new image
4. On the node: `bootc upgrade --check` runs daily via timer
5. Finds new image → stages it for next boot
6. User reboots at their convenience
7. On boot: `kubeadm-auto-upgrade.service` detects version mismatch → runs `kubeadm upgrade apply`
8. Kubernetes cluster upgraded automatically

**You only need to reboot.** Everything else is automatic.

## Usage

### Building the Image

#### Local Build

```bash
# Build and push production image
make build

# Build with specific tag
make build TAG=v1.34.1
```

The build script:
- Builds with production network config (192.168.16.0/24)
- Logs into Quay.io using Bitwarden credentials
- Pushes to `quay.io/acardace/kubeos:latest`

**Note**: For local builds, you need `rootfs/usr/lib/ostree/auth.json` with your Quay.io credentials:
```json
{
  "auths": {
    "quay.io": {
      "auth": "BASE64_ENCODED_USERNAME_PASSWORD"
    }
  }
}
```

To generate the base64 auth string:
```bash
echo -n "username:password" | base64
```

#### GitHub Actions Build

For automated builds, set the `QUAY_AUTH_JSON` GitHub secret with the entire `auth.json` content. The workflow will create the file automatically during builds.

### Testing in a VM

```bash
# Create isolated test VM
make test

# Test with different Kubernetes version (e.g., for upgrade testing)
KUBERNETES_VERSION=1.34.0 make test

# Quick health check
make test-check

# Full cluster verification
make test-verify

# Debug VM connectivity
make test-debug

# Clean up test environment
make test-clean
```

The test script:
- Builds image with test network (10.99.16.0/24)
- Creates isolated libvirt network (no production access)
- Deploys VM with Fedora CoreOS → switches to bootc image
- Configures VLAN-aware bridge for networking
- Waits for Kubernetes to initialize

**VM access**: `ssh core@10.99.16.7` (password: `debug`)

### Deploying to Production

#### First Time Deployment

1. Boot bare metal server with Fedora CoreOS live ISO
2. Login and switch to KubeOS image:
   ```bash
   # Login to Quay
   podman login quay.io

   # Switch to bootc image and apply immediately
   sudo bootc switch quay.io/acardace/kubeos:latest
   sudo systemctl reboot
   ```

3. After reboot, Kubernetes initializes automatically via `kubeadm-init.service`

#### Upgrading Production

Updates happen automatically, but you control when:

```bash
# Check for available updates
bootc upgrade --check

# Stage update for next boot (automatic via timer, or manual)
bootc upgrade

# Reboot when ready
systemctl reboot
```

On boot, `kubeadm-auto-upgrade.service` detects Kubernetes version mismatch and upgrades the cluster automatically.

#### Rollback if Needed

```bash
# Rollback to previous image
bootc rollback
systemctl reboot
```

### Remote Cluster Verification

```bash
# Quick health check on production
make remote-check

# Full cluster verification on production
make remote-verify
```

## Project Structure

```
kubeos/
├── Containerfile              # Image definition
├── Makefile                   # Build and test targets
├── .github/
│   └── workflows/
│       └── image.yml          # Daily build automation
├── .renovaterc.json           # Renovate bot configuration
├── rootfs/                    # Files copied into image
│   ├── etc/
│   │   ├── kubernetes/
│   │   │   ├── kubeadm-config.yaml    # Cluster configuration
│   │   │   └── patches/               # kubeadm upgrade patches
│   │   ├── yum.repos.d/
│   │   │   └── kubernetes.repo        # Official Kubernetes repo
│   │   ├── crio/
│   │   │   └── crio.conf.d/           # CRI-O CNI config
│   │   ├── sysctl.d/                  # Kernel parameters
│   │   └── modules-load.d/            # Kernel modules
│   ├── usr/
│   │   ├── lib/systemd/
│   │   │   ├── network/               # systemd-networkd (VLAN 2)
│   │   │   └── system/                # Service units
│   │   ├── local/bin/
│   │   │   ├── kubeadm-auto-upgrade.sh    # Auto-upgrade script
│   │   │   └── approve-kubelet-csr.sh     # CSR approval
│   │   └── share/ssh-keys/
│   │       └── core                   # Your SSH public key
│   └── var/lib/kubelet/
│       └── config.yaml                # Kubelet runtime config
└── scripts/
    ├── build-production.sh            # Build and push image
    ├── test-vm.sh                     # Create test VM
    ├── cleanup-test.sh                # Remove test VM
    ├── remote-quick-check.sh          # Quick SSH health check
    ├── remote-verify-cluster.sh       # Full SSH verification
    └── verify-cluster.sh              # Local cluster verification
```

## How Updates Work

### Fedora OS Updates
- **Renovate** monitors `quay.io/fedora/fedora-bootc:42`
- Opens PR when new Fedora image available
- Merge → GitHub Actions rebuilds image
- `bootc upgrade` on the node pulls new image

### Kubernetes Updates
- **Renovate** monitors Kubernetes package repo
- Updates `ARG KUBERNETES_VERSION=` in Containerfile
- Merge → GitHub Actions rebuilds with new version
- `bootc upgrade` stages new image
- Reboot → `kubeadm-auto-upgrade.service` runs `kubeadm upgrade apply`

### What Survives Reboots
All stateful data lives in `/var` (persistent across image updates):
- `/var/lib/kubelet` - Kubelet data
- `/var/lib/etcd` - etcd database
- `/var/lib/containers` - CRI-O images
- `/var/lib/rook` - Rook-Ceph cluster metadata ⚠️ **Must be backed up**
- `/var/mnt/*` - Your storage mounts
- `/etc` - Merged via 3-way merge (local changes preserved)

## Customization

All configuration lives in `rootfs/`. To customize:

1. Edit files in `rootfs/`
2. Commit changes
3. GitHub Actions rebuilds image automatically (daily, or on push to main)
4. Pull update with `bootc upgrade`

Example: Change node IP, edit `rootfs/usr/lib/systemd/network/30-vlan2.network` (or pass build arg).

## Troubleshooting

**Cluster won't initialize:**
```bash
# Check kubeadm-init service
ssh core@192.168.16.7 journalctl -u kubeadm-init.service -f
```

**Upgrade failed:**
```bash
# Rollback to previous version
bootc rollback
systemctl reboot
```

**Check what's staged for next boot:**
```bash
bootc status
```

**Manual kubeadm upgrade:**
```bash
# If auto-upgrade fails
sudo systemctl stop kubeadm-auto-upgrade.service
sudo kubeadm upgrade apply v1.34.1 --yes
```
