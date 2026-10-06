# Kubernetes Attack Detection - Reproduction and Detection via Audit Logs

This project reproduces four control-plane attacks from Wang et al., *Losing control*, against a local Kubernetes cluster, measures their impact, and evaluates whether each attack is detectable in the API server's audit logs analyzed via Wazuh. The audit-log detection approach, and the audit policy used, follow Franzil et al., *Sharpening Kubernetes Audit Logs with Context Awareness*.

## Prerequisites

- Access to a test Kubernetes cluster with `kubectl` configured (see `docs/attack-environment.md` for environment details)
- Audit logging enabled on the API server (policy: `level: RequestResponse`, see `docs/`)
- Wazuh deployed and configured to ingest the audit logs (see `wazuh/config/wazuh-configuration.md`)
- Python (+ pandas) to run `compare_logs.py` and the notebooks

## Reproducing an Attack

Each attack has its own directory under `attacks/` (`attack1-coredns`, `attack2-kube-apiserver`, `attack3-readiness-probe`, `attack4-endpoints-flooding`), structured as follows:

- `manifests/` - Kubernetes manifests to deploy
- `scripts/` - attack execution and measurement scripts
- `analysis/` - attack-specific analysis (mechanism, impact, detectability)
- `results/` - raw measurement data (CSV)

Generic steps:

1. Apply the manifests from the attack's `manifests/` directory
2. Run the corresponding script in `scripts/`: `./launch-attack<number>.sh`

Impact and audit-log capture are run as **separate** measurements over the same attack, not point-to-point against each other.

## Analyzing the Logs

For each attack:

1. Capture a baseline (logs under normal conditions) before launching the attack
2. Export the logs during the attack
3. Run the corresponding notebook in `wazuh/`, or `wazuh/compare_logs.py` to compare baseline vs. attack (volume, event rate, per-field deltas)
4. Comparison results are stored in `wazuh/analysis/analysis_results/<attackN>/`

## Results per Attack

| Attack | Layer it operates at | Impact reproduced | Detectable in audit logs? |
|---|---|---|---|
| 1 - CoreDNS flood | DNS / network (outside API server) | Yes (conntrack saturation, packet loss) | **No** - never reaches the API server |
| 2 - Kube-apiserver flood | TCP / conntrack (below HTTP layer) | Yes (conntrack saturation, apiserver CPU) | **Indirect only** - the flood saturates below the audited layer; the attacker's own requests are absent |
| 3 - Readiness-probe | Through the API (`pods/status` patch) | Yes (apiserver + etcd CPU) | **Yes** - strong, specific signature |
| 4 - Endpoints flooding | Through the API (+ kube-proxy fan-out) | Yes (apiserver CPU, all-nodes iptables reprogramming) | **Yes** - two dependency chains, strongest signature |

## Key finding

Detectability in the audit logs does not track an attack's severity, but the **layer at which it operates**. Attacks that do their damage in the network or kernel layer (CoreDNS, kube-apiserver flood) are invisible or near-invisible to API-level auditing, however disruptive they are; attacks that act through the API (readiness probe, endpoints flooding) are trivially visible, because every step becomes an audited request. Kubernetes audit logs are therefore a necessary but insufficient telemetry source: detecting the low-level attacks requires kernel- or service-level metrics (`nf_conntrack` occupancy, per-service health counters), which is precisely what we used to measure their impact, since the audit log could not see them.

A full analysis per attack (mechanism, impact vs. the paper, and detectability) is in each attack's `analysis/` directory.

## References

- `papers/losing-control-k8s-control-plane-interfaces.pdf` - C. Wang, H. Tang, Y. Zhao, W. You, J. Yang, H. Qiu, *Losing control: Exposing security weaknesses of Kubernetes control plane interfaces*. Source of the four reproduced attacks (its Cases 1–4).
- `papers/sharpening-k8s-audit-logs-context-awareness.pdf` - M. Franzil, V. Armani, L. A. Dias Knob, D. Siracusa, *Sharpening Kubernetes Audit Logs with Context Awareness*. Basis for the audit-log detection approach and the audit policy used here.
