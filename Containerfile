FROM quay.io/fedora/fedora-bootc:42

LABEL bootc.image-description="Kubernetes OS (Fedora Bootc)"

# Kubernetes version (can be overridden for testing upgrades)
ARG KUBERNETES_VERSION=1.34.1

# Network configuration (can be overridden for testing)
ARG SUBNET_PREFIX=192.168.16
ARG NODE_IP=192.168.16.7
ARG GATEWAY_IP=192.168.16.1
ARG DNS_IP=192.168.16.1
ARG CLUSTER_NAME=home

# Disk configuration (can be overridden for testing)
ARG BACKUP_DISK=/dev/disk/by-id/ata-WDC_WD10EZEX-08WN4A0_WD-WCC6Y0SS50Y6-part1
ARG MEDIA_DISK=/dev/disk/by-id/ata-WDC_WD5000LPLX-66ZNTT1_WD-WXJ1A56K9D2J-part1

# Copy Kubernetes repository configuration first (needed for package installation)
COPY rootfs/etc/yum.repos.d/kubernetes.repo /etc/yum.repos.d/kubernetes.repo

# Install all packages in a single layer for better caching
# - Remove unnecessary packages to reduce size
# - Install hardware-specific firmware (matches Talos extensions)
# - Install Kubernetes and container runtime
# - Remove documentation, locales, and unused packages to minimize image size
RUN dnf remove -y \
        NetworkManager \
        NetworkManager-libnm \
        NetworkManager-cloud-setup \
        NetworkManager-tui \
        nano \
        nano-default-editor \
        'sssd*' \
        'samba*' \
        'fwupd*' \
        libsmbclient \
    && dnf install -y \
        amd-ucode-firmware \
        amd-gpu-firmware \
        realtek-firmware \
        linux-firmware \
        systemd-networkd \
        cri-o \
        kubeadm-${KUBERNETES_VERSION} \
        kubelet-${KUBERNETES_VERSION} \
        kubectl-${KUBERNETES_VERSION} \
        containernetworking-plugins \
        iproute \
        nftables \
        openssh-server \
        xfsprogs \
        bash-completion \
        distrobox \
        jq \
    && dnf clean all \
    && rm -rf /usr/share/man/* \
    && rm -rf /usr/share/doc/* \
    && rm -rf /usr/share/info/* \
    && rm -rf /usr/share/cracklib/* \
    && find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en_US' ! -name 'locale.alias' -exec rm -rf {} +

# Copy all configuration files (last, so changes don't invalidate package layer)
COPY rootfs/ /

# Configure permissions, timezone, apply presets, and apply build-time network settings
# Make /opt writable by symlinking to /var/opt (needed for Flannel and other apps)
RUN chmod 0644 /usr/share/ssh-keys/core \
    && chmod 0440 /etc/sudoers.d/core \
    && ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime \
    && rm -rf /opt \
    && ln -s /var/opt /opt \
    && systemctl preset-all \
    && sed -i "s|Address=192.168.16.7/24|Address=${NODE_IP}/24|g" /usr/lib/systemd/network/30-vlan2.network \
    && sed -i "s|Gateway=192.168.16.1|Gateway=${GATEWAY_IP}|g" /usr/lib/systemd/network/30-vlan2.network \
    && sed -i "s|DNS=192.168.16.1|DNS=${DNS_IP}|g" /usr/lib/systemd/network/30-vlan2.network \
    && sed -i "s|kubernetesVersion: v1.34.1|kubernetesVersion: v${KUBERNETES_VERSION}|g" /etc/kubernetes/kubeadm-config.yaml \
    && sed -i "s|advertiseAddress: 192.168.16.7|advertiseAddress: ${NODE_IP}|g" /etc/kubernetes/kubeadm-config.yaml \
    && sed -i "/name: node-ip/,/value:/ s|value: 192.168.16.7|value: ${NODE_IP}|g" /etc/kubernetes/kubeadm-config.yaml \
    && sed -i "s|controlPlaneEndpoint: \"192.168.16.7:6443\"|controlPlaneEndpoint: \"${NODE_IP}:6443\"|g" /etc/kubernetes/kubeadm-config.yaml \
    && sed -i "s|clusterName: home|clusterName: ${CLUSTER_NAME}|g" /etc/kubernetes/kubeadm-config.yaml \
    && sed -i "s|- 192.168.16.7|- ${NODE_IP}|g" /etc/kubernetes/kubeadm-config.yaml \
    && sed -i "s|BACKUP_DISK_PLACEHOLDER|${BACKUP_DISK}|g" /usr/lib/systemd/system/var-mnt-backup.mount \
    && sed -i "s|MEDIA_DISK_PLACEHOLDER|${MEDIA_DISK}|g" /usr/lib/systemd/system/var-mnt-media.mount
