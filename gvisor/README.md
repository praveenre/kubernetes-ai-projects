# gVisor (`runsc`) Sandbox & Kubernetes RuntimeClass Setup

This directory provides the declarative manifests and automation scripts for setting up **gVisor (`runsc`)** container sandboxing and the Kubernetes **`RuntimeClass`** based on the [DevOpsCube gVisor Guide](https://devopscube.com/set-up-gvisor-on-aws-eks/#step-5-create-runtimeclass).

---

## 1. What is gVisor?

[gVisor](https://gvisor.dev/) is an open-source application kernel written in Go that provides defense-in-depth isolation for containers. Instead of sharing the host Linux kernel directly (which a conventional container runtime like `runc` does), containers assigned `runtimeClassName: gvisor` run inside **Sentry** (the user-space application kernel). Sentry intercepts and emulates system calls, ensuring that potentially compromised or untrusted workloads (such as AI agents executing dynamic cluster queries or scripts) cannot escape to the underlying host kernel.

---

## 2. Step 5: Kubernetes `RuntimeClass`

The `RuntimeClass` object maps a workload pod's `runtimeClassName: gvisor` to the underlying containerd runtime handler (`runsc`).

**Manifest (`gvisor/runtimeclass.yaml` / `agent-sandbox/ai-agent-sandbox/manifests/00-runtimeclass.yaml`):**

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
```

### Apply RuntimeClass
```bash
kubectl apply -f gvisor/runtimeclass.yaml
```

Verify that the `gvisor` runtime class is registered:
```bash
kubectl get runtimeclass
```

Expected output:
```text
NAME     HANDLER   AGE
gvisor   runsc     1m
```

---

## 3. Setting Up gVisor on Cluster Nodes

### Option A: Local Development & CI/CD (k3d / K3s)

For local clusters created with k3d, run the automated setup script:

* **Windows (PowerShell):**
  ```powershell
  .\scripts\setup-gvisor.ps1
  ```
* **Linux / macOS:**
  ```bash
  chmod +x ./scripts/setup-gvisor.sh
  ./scripts/setup-gvisor.sh
  ```

This script:
1. Downloads the official gVisor binary package (`runsc`, `containerd-shim-runsc-v1`, and `gvisor-bin`).
2. Copies binaries into `/bin/` on all k3d cluster node containers.
3. Generates containerd configuration in `/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/runsc.toml`.
4. Restarts containerd on each node.
5. Applies the `gvisor` `RuntimeClass`.
6. Executes a smoke test pod to verify sandbox isolation.

---

### Option B: Kubernetes In-Cluster Installer DaemonSet

For bare-metal, on-premise, or self-managed nodes, deploy the `gvisor-installer` DaemonSet:

```bash
kubectl apply -f gvisor/gvisor-installer-daemonset.yaml
kubectl rollout status daemonset/gvisor-installer -n kube-system
kubectl apply -f gvisor/runtimeclass.yaml
```

---

### Option C: AWS EKS with EC2 Launch Template (DevOpsCube Guide)

When deploying on AWS EKS, configure an EC2 Launch Template with User Data to bootstrap nodes with gVisor as documented in the [DevOpsCube gVisor Guide](https://devopscube.com/set-up-gvisor-on-aws-eks/):

```bash
#!/bin/bash
set -ex

# 1. Download gVisor runsc binary
ARCH=$(uname -m)
URL=https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}
wget ${URL}/runsc -O /usr/local/bin/runsc
chmod +x /usr/local/bin/runsc

# 2. Configure containerd to add runsc runtime
CONTAINERD_CONFIG="/etc/containerd/config.toml"
mkdir -p /etc/containerd
if [ ! -f "$CONTAINERD_CONFIG" ]; then
    containerd config default | tee $CONTAINERD_CONFIG > /dev/null
fi

cat << 'EOF' >> $CONTAINERD_CONFIG
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
EOF

# 3. Restart containerd service
systemctl restart containerd
```

Then create the `RuntimeClass` (Step 5):
```bash
kubectl apply -f gvisor/runtimeclass.yaml
```

---

## 4. Verification & Testing

Deploy the test pod:
```bash
kubectl apply -f gvisor/test-pod.yaml
kubectl wait --for=condition=Ready pod/gvisor-smoke-test --timeout=30s
kubectl logs gvisor-smoke-test
```

### Expected Output
When running under gVisor Sentry isolation, `dmesg` outputs:
```text
[   0.000000] Starting gVisor...
[   0.266785] DeFUSEing fork bombs...
[   0.706086] Rewriting operating system in Javascript...
[   0.831371] Asking an AI agent to fix the bugs...
[   1.257651] Committing treasure map to memory...
[   1.626781] Searching for socket adapter...
[   2.049072] Consulting tar man page...
[   2.329822] Forking spaghetti code...
[   2.561482] Rewriting the kernel in Rust...
[   2.938563] Digging up root...
[   2.991153] Checking naughty and nice process list...
[   3.387969] Ready!
=== gVisor verification complete ===
```

Clean up:
```bash
kubectl delete -f gvisor/test-pod.yaml
```
