#!/bin/bash
# ============================================================
# Kubernetes 1.36 Complete kubeadm Setup (Ubuntu)
#
# Usage:
#   MASTER:  sudo bash k8s.sh master
#   WORKER:  sudo bash k8s.sh worker
#
# IMPORTANT:
#   Run on FRESH/NEW nodes.
#   Do NOT run directly on an existing Kubernetes cluster.
# ============================================================
set -euo pipefail

K8S_VERSION="v1.36"
POD_CIDR="10.244.0.0/16"
ROLE="${1:-}"

if [[ "$ROLE" != "master" && "$ROLE" != "worker" ]]; then
    echo "Usage:"
    echo "  sudo bash k8s.sh master"
    echo "  sudo bash k8s.sh worker"
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

echo "===================================================="
echo " Kubernetes $K8S_VERSION kubeadm Setup"
echo " Role: $ROLE"
echo "===================================================="

# ============================================================
# 1. Disable Swap
# ============================================================
echo ""
echo "[1/9] Disabling swap..."
swapoff -a || true
sed -ri '/\sswap\s/s/^/#/' /etc/fstab
if swapon --show | grep -q .; then
    echo "ERROR: Swap is still enabled."
    exit 1
fi
echo "Swap disabled successfully."

# ============================================================
# 2. Kernel Modules
# ============================================================
echo ""
echo "[2/9] Configuring kernel modules..."
cat > /etc/modules-load.d/k8s.conf <<EOT
overlay
br_netfilter
EOT
modprobe overlay
modprobe br_netfilter
echo "Kernel modules loaded."

# ============================================================
# 3. Kubernetes Networking Sysctl
# ============================================================
echo ""
echo "[3/9] Configuring Kubernetes networking..."
cat > /etc/sysctl.d/k8s.conf <<EOT
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOT
sysctl --system
echo "Networking parameters configured."

# ============================================================
# 4. Install Containerd
# ============================================================
echo ""
echo "[4/9] Installing containerd..."
apt-get update
apt-get install -y ca-certificates curl gpg apt-transport-https

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
cat > /etc/apt/sources.list.d/docker.list <<EOT
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOT

apt-get update
apt-get install -y containerd.io
echo "Containerd installed."

# ============================================================
# 5. Configure Containerd
# ============================================================
echo ""
echo "[5/9] Configuring containerd..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd

if ! systemctl is-active --quiet containerd; then
    echo "ERROR: containerd is not running."
    systemctl status containerd --no-pager
    exit 1
fi
echo "Containerd is active."

# ============================================================
# 6. Install Kubernetes
# ============================================================
echo ""
echo "[6/9] Installing Kubernetes $K8S_VERSION..."
rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat > /etc/apt/sources.list.d/kubernetes.list <<EOT
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /
EOT

apt-get update
apt-mark unhold kubeadm kubelet kubectl 2>/dev/null || true
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
echo "Kubernetes packages installed."

# ============================================================
# 7. Version Verification
# ============================================================
echo ""
echo "[7/9] Verifying versions..."
echo ""; echo "kubeadm:";    kubeadm version
echo ""; echo "kubelet:";    kubelet --version
echo ""; echo "kubectl:";    kubectl version --client
echo ""; echo "containerd:"; containerd --version

# ============================================================
# 8. Master Initialization
# ============================================================
if [[ "$ROLE" == "master" ]]; then
    echo ""
    echo "[8/9] Initializing Kubernetes control-plane..."

    if [[ -f /etc/kubernetes/admin.conf ]]; then
        echo "ERROR: Kubernetes cluster already appears to be initialized."
        echo "Refusing to run kubeadm init again."
        exit 1
    fi

    kubeadm init --pod-network-cidr="${POD_CIDR}"

    echo ""
    echo "Configuring kubectl..."
    mkdir -p /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config
    chown root:root /root/.kube/config
    export KUBECONFIG=/etc/kubernetes/admin.conf
    echo "Control-plane initialized."

    # ========================================================
    # 9. Install Flannel
    # ========================================================
    echo ""
    echo "[9/9] Installing Flannel CNI..."
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

    echo ""
    echo "Waiting for Flannel..."
    sleep 10

    echo ""; echo "Cluster status:"; kubectl get nodes -o wide
    echo ""; echo "System pods:";    kubectl get pods -A

    echo ""
    echo "===================================================="
    echo " WORKER JOIN COMMAND"
    echo "===================================================="
    echo ""
    kubeadm token create --print-join-command
    echo ""
    echo "===================================================="
    echo " MASTER SETUP COMPLETED"
    echo "===================================================="
else
    echo ""
    echo "[8/9] Worker node preparation completed."
    echo ""
    echo "[9/9] Worker is ready for kubeadm join."
    echo ""
    echo "Run the kubeadm join command generated on the Master."
    echo ""
    echo "Example:"
    echo ""
    echo "kubeadm join <MASTER-IP>:6443 --token <TOKEN> \\"
    echo "  --discovery-token-ca-cert-hash sha256:<HASH>"
    echo ""
fi

echo ""
echo "===================================================="
echo " Kubernetes $K8S_VERSION setup finished"
echo "===================================================="
