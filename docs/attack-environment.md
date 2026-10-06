# Reproducing the attacks from the paper: Losing control: Exposing security weaknesses of Kubernetes control plane interfaces

First, we will try to understand and then reproduce the attacks presented in the research paper.
Second, we will look at existing solutions for securing a Kubernetes cluster, as well as measures that would specifically prevent the reproduced attacks.

# 1. The attack environment

## 1.1 Cluster topology

In line with the paper (Table 2, local environment), we deployed a 3-node cluster with `kubeadm`:

| Element | Paper | Reproduced cluster |
|---|---|---|
| Distribution | Kubernetes 1.30.4 | Kubernetes 1.30.14 |
| Topology | 1 control plane, 2 workers | 1 control plane (`k8s-cp`), 2 workers (`k8s-w1`, `k8s-w2`) |
| OS | Ubuntu 22.04 | Ubuntu 22.04.5 LTS |
| Containerd | 1.7.21 | 2.1.5 |
| Third-party apps | CoreDNS, Prometheus, Grafana, Calico | CoreDNS, Calico, Prometheus, Grafana |

Unlike the paper, which allocates an identical hardware configuration (4 cores, 8 GB RAM) to each of the three nodes, our resources are distributed asymmetrically, adjusted empirically over the course of testing to obtain the most stable configuration:

| Node | Role | CPU | RAM |
|---|---|---|---|
| `k8s-cp` | Control plane | 4 cores | 8192 MB |
| `k8s-w1` | Worker (attacker node) | 4 cores | 16384 MB |
| `k8s-w2` | Worker (victim node) | 2 cores | 4096 MB |

> **Notable deviations**:
> - **containerd**: major version 2.1.5, versus 1.7.21 in the paper.
> - **Asymmetric CPU/RAM allocation**: the control plane matches the paper (4 cores). The attacker node (`k8s-w1`) was over-provisioned (4 cores, 16 GB), as generating sufficient load proved more resource-intensive on our setup than the paper suggests. The victim node (`k8s-w2`) stays modest (2 cores, 4 GB), running only a lightweight test pod.

```bash
kubectl get nodes -o wide
Client Version: v1.30.14
Kustomize Version: v5.0.4-0.20230601165947-6ce0bf390ce3
Server Version: v1.30.14
NAME     STATUS   ROLES           AGE    VERSION    INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION       CONTAINER-RUNTIME
k8s-cp   Ready    control-plane   293d   v1.30.14   10.10.10.10   <none>        Ubuntu 22.04.5 LTS   5.15.0-187-generic   containerd://2.1.5
k8s-w1   Ready    <none>          293d   v1.30.14   10.10.10.11   <none>        Ubuntu 22.04.5 LTS   5.15.0-190-generic   containerd://2.1.5
k8s-w2   Ready    <none>          293d   v1.30.14   10.10.10.12   <none>        Ubuntu 22.04.5 LTS   5.15.0-177-generic   containerd://2.1.5
```


## 1.2 Why harden the cluster before attacking it?

The paper makes an important point: the attacks do **not** rely on a misconfigured cluster. On the contrary, the authors first apply official Kubernetes security best practices, the *Securing a Cluster* and *Pod Security Standards* documentation, then show that the attacks work **anyway**, because they exploit legitimate control plane interfaces rather than configuration flaws.

Our reproduction follows the same approach in two parts:
1. **Control plane hardening** (API, etcd, kubelet access)
2. **Pod hardening** (Pod Security Standards)

## 1.3 Control plane hardening

The paper points to the official [Securing a Cluster](https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/) documentation to justify its hardening measures. We verified that each of the measures it recommends was indeed in place on our cluster:

**TLS across the API.** Kubernetes expects all API communication to be encrypted by default with TLS. On `kubeadm`, this is enabled automatically via PKI certificates generated at install time, visible in the `--tls-cert-file` and `--tls-private-key-file` flags of the kube-apiserver manifest:

```bash
$ cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep -E "tls-cert-file|tls-private-key-file|client-ca-file"
- --client-ca-file=/etc/kubernetes/pki/ca.crt
- --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
- --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
- --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
```

**API authentication and authorization.** The documentation recommends combining the `Node` and `RBAC` authorizers:

> "It is recommended that you use the Node and RBAC authorizers together"

Our apiserver is configured exactly this way:

```bash
$ cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep "authorization-mode"
- --authorization-mode=Node,RBAC
```

**Kubelet access.** By default, unauthenticated requests can reach the kubelet's API:

> "By default Kubelets allow unauthenticated access to this API"

The documentation recommends enabling authentication and authorization in production. Our kubelet enforces both: `anonymous.enabled: false` rejects unauthenticated requests outright, and `authorization.mode: Webhook` delegates the authorization decision to the kube-apiserver (via a webhook call) rather than allowing every authenticated request through unchecked.

```bash
$ cat /var/lib/kubelet/config.yaml | grep -A3 -E "authentication|authorization"
authentication:
  anonymous:
    enabled: false
  webhook:
--
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 0s
```

**Restricted access to etcd.** The documentation is direct about what write access to etcd actually grants:

> "equivalent to gaining root on the entire cluster"

etcd stores the cluster's entire state, so anyone able to write to it can effectively control every resource Kubernetes manages, not just read sensitive data. On our cluster, this is mitigated on two fronts: `--listen-client-urls` restricts etcd to accept connections only from `127.0.0.1` and the node's own IP, and `--client-cert-auth` / `--peer-client-cert-auth` require every client (including the apiserver itself) to present a valid mTLS certificate before any request is accepted.

```bash
$ cat /etc/kubernetes/manifests/etcd.yaml | grep -E "listen-client-urls|client-cert-auth|peer-client-cert-auth|trusted-ca-file"
- --client-cert-auth=true
- --listen-client-urls=https://127.0.0.1:2379,https://10.10.10.10:2379
- --peer-client-cert-auth=true
- --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
- --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```

**Credential rotation.** Short-lived, automatically rotated certificates are recommended to limit how long a stolen credential remains useful. `rotateCertificates: true` is active on the kubelet side, enabling automatic renewal of its certificates:

```bash
$ cat /var/lib/kubelet/config.yaml | grep -i rotate
rotateCertificates: true
```

## 1.4 Pod hardening (Pod Security Standards)

The paper's own wording is worth quoting directly, since it lists every constraint applied to the malicious and victim containers:

> "we run different users' containers in separate Kubernetes namespaces by setting namespace. We constrain different users' containers running on separate worker nodes by setting nodeName. On each worker node, we run containers with non-root user by setting runAsUser and runAsGroup to 1000."

The paper also disables privilege escalation, drops all capabilities, applies the `RuntimeDefault` seccomp profile, and bans host namespaces, host ports, and hostPath volumes, citing the Kubernetes pod hardening documentation as its source for these settings. That documentation defines the **`restricted`** level of the official [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/), which specifies the exact manifest fields and values a pod must set to be admitted:

The table below lists those required fields; each YAML setting in our manifests, shown further down, is what actually satisfies them.

| Required field | Where | Required value |
|---|---|---|
| `runAsNonRoot` | pod or container | `true` |
| `runAsUser` | pod or container | any non-zero value (or unset) |
| `allowPrivilegeEscalation` | container | `false` |
| `capabilities.drop` | container | must include `ALL` |
| `capabilities.add` | container | unset, or only `NET_BIND_SERVICE` |
| `seccompProfile.type` | pod or container | `RuntimeDefault` or `Localhost` |
| `privileged` | container | `false` (or unset) |
| `hostNetwork` / `hostPID` / `hostIPC` | pod | `false` (or unset) |
| `spec.volumes[*]` | pod | only specific types allowed (no `hostPath`) |
| `hostPort` | container | unset, or `0` |

We enforce this level at the namespace scope, on every namespace we create:

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted
```

### Namespace and node isolation

Each attack uses a dedicated namespace per tenant, and pins that tenant's pods to a specific worker node via `nodeName`, so attacker and victim workloads never share a node, matching the paper's setup.

### securityContext fields

Across our pod manifests, `runAsUser`, `runAsGroup`, `runAsNonRoot`, and `seccompProfile` are placed under `spec.securityContext` (pod level, shared by all containers), while `allowPrivilegeEscalation`, `privileged`, and `capabilities.drop` are placed under `spec.containers[*].securityContext` (container level, since these fields do not exist at the pod level):

```yaml
spec:
  securityContext:        # pod level
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true

  containers:
    - name: example
      securityContext:    # container level
        allowPrivilegeEscalation: false
        privileged: false
        capabilities:
          drop: ["ALL"]
```
```

### What `RuntimeDefault` seccomp actually restricts

Seccomp is a Linux kernel feature, unrelated to Kubernetes itself, that restricts which system calls a process is allowed to make. The [seccomp tutorial](https://kubernetes.io/docs/tutorials/security/seccomp/) explains what setting the profile to `RuntimeDefault` does in practice:

> "the kubelet will use the RuntimeDefault seccomp profile by default"

instead of running the container fully `Unconfined` (no syscall filtering at all, the implicit default when the field is left unset). The exact list of allowed syscalls comes from the container runtime, `containerd` in our case, rather than from Kubernetes itself; it is possible to inspect which profile a running container actually has with `crictl inspect`.

We verified this directly on one of our worker nodes, by inspecting a running container's actual OCI runtime spec, one level below the Kubernetes API:

```bash
$ sudo crictl inspect <container-id> | grep -B2 -A15 "seccomp"
"seccomp": {
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_X32"
  ],
  "syscalls": [
    {
      "names": [
        "accept",
        "accept4",
        "access",
        "adjtimex",
        "alarm",
        "bind",
        ...
```

`defaultAction: SCMP_ACT_ERRNO` means every syscall not explicitly listed is blocked, with the process receiving a standard error instead of being silently killed; the `syscalls.names` array is the actual allow-list `containerd` enforces at the kernel level, confirming that `RuntimeDefault` is not just a declarative label in the YAML but translates into a concrete, inspectable restriction.

**Verification:** a deliberately non-compliant pod (e.g. one requesting `privileged: true`) is rejected outright by Kubernetes, confirming the policy is genuinely enforced before any attack is launched:

```bash
$ kubectl run test-violation -n attacker-ns --image=alpine --privileged
Error from server (Forbidden): pods "test-violation" is forbidden:
violates PodSecurity "restricted:latest": privileged (container "test-violation"
must not set securityContext.privileged=true)
```
