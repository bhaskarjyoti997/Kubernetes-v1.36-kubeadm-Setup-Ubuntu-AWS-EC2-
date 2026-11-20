# Kubernetes v1.36 kubeadm Setup (Ubuntu / AWS EC2)

A single script that prepares Ubuntu nodes and sets up a Kubernetes cluster with **kubeadm**, **containerd** and **Flannel** CNI.

## Requirements

- Ubuntu 22.04 / 24.04 (fresh instance)
- Minimum 2 vCPU, 2 GB RAM (e.g. EC2 `t3.medium`)
- Root access
- AWS Security Group inbound rules:

| Port | Protocol | Purpose |
|------|----------|---------|
| 6443 | TCP | Kubernetes API server |
| 2379–2380 | TCP | etcd |
| 10250 | TCP | kubelet API |
| 10257 | TCP | kube-controller-manager |
| 10259 | TCP | kube-scheduler |
| 8472 | UDP | Flannel VXLAN (between nodes) |
| 30000–32767 | TCP | NodePort services (optional) |

## What the script does

1. Disables swap
2. Loads `overlay` and `br_netfilter` kernel modules
3. Configures networking sysctl parameters
4. Installs containerd (from Docker’s repo)
5. Configures containerd with the systemd cgroup driver
6. Installs `kubelet`, `kubeadm`, `kubectl` (v1.36) and holds them
7. Prints installed versions
8. **Master only:** runs `kubeadm init`, configures kubectl
9. **Master only:** installs Flannel and prints the worker join command

## Usage

### Master node

```bash
sudo bash k8s.sh master
```

Copy the `kubeadm join ...` command printed at the end.

### Worker node(s)

```bash
sudo bash k8s.sh worker
```

Then run the join command from the master:

```bash
sudo kubeadm join <MASTER-IP>:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

Lost the join command? Regenerate it on the master:

```bash
kubeadm token create --print-join-command
```

## Verify the cluster

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

## Give a worker node a role label

By default, worker nodes show `<none>` under ROLES.

**Before:**

```
NAME              STATUS   ROLES           AGE   VERSION
ip-172-31-7-188   Ready    <none>          11m   v1.36.4
master-node       Ready    control-plane   18m   v1.36.4
```

Add a role label:

```bash
kubectl label node ip-172-31-7-188 node-role.kubernetes.io/worker-node-test=
```

**After:**

```
NAME              STATUS   ROLES              AGE   VERSION
ip-172-31-7-188   Ready    worker-node-test   12m   v1.36.4
master-node       Ready    control-plane      19m   v1.36.4
```

Remove the label:

```bash
kubectl label node ip-172-31-7-188 node-role.kubernetes.io/worker-node-test-
```

## How Kubernetes works (simple flow)

1. You give an order with **kubectl**.
2. The **API Server** receives the request and stores it in **etcd**.
3. The **Scheduler** picks a node for the Pod.
4. The API Server tells that node’s **kubelet**.
5. The kubelet starts the container inside the Pod (via containerd).
6. **kube-proxy** sets up networking so the Pod can be reached.

```
kubectl → API Server → etcd
              ↓
          Scheduler (chooses node)
              ↓
          kubelet (on node) → containerd → Pod
              ↓
          kube-proxy (network)
```

## Single-node cluster (optional)

To run workloads on the master itself:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## Notes

- Run only on **fresh** nodes; the script refuses to re-run `kubeadm init` if a cluster already exists.
- Pod network CIDR is `10.244.0.0/16` (Flannel default).
