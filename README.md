# Kubernetes Attack Detection — Reproduction and Detection via Audit Logs

This project reproduces attacks from two research papers against a Kubernetes cluster, then evaluates whether these attacks are detectable in the API server's audit logs, analyzed via Wazuh.

## Prerequisites

- Access to a test Kubernetes cluster with `kubectl` configured (see `docs/attack-environment.md` for environment details)
- Audit logging enabled on the API server
- Wazuh deployed and configured to ingest the audit logs (see `wazuh/config/wazuh-configuration.md`)
- Python [+ dependencies, e.g. pandas] to run `compare_logs.py` and the notebooks

## Reproducing an Attack

Each attack has its own directory under `attacks/` (`attack1-coredns`, `attack2-kube-apiserver`, `attack3-readiness-probe`, `attack4-endpoints-flooding`), structured as follows:

- `manifests/` — Kubernetes manifests to deploy
- `scripts/` — attack execution scripts
- `analysis/` — attack-specific analysis
- `results/` — results obtained

Generic steps:

1. Apply the manifests from the attack's `manifests/` directory
2. Run the corresponding script in `scripts/`: `./launch-attack<number>` (e.g. `./launch-attack1` for CoreDNS Flood)

## Analyzing the Logs

For each attack:

1. Capture a baseline (logs under normal conditions) before launching the attack
2. Export the logs during the attack
3. Run the corresponding notebook in `wazuh/` (`attack1-dns-flood.ipynb`, etc.) for detailed analysis, or `wazuh/compare_logs.py` to compare baseline vs. attack (volume, event rate, deltas)
4. Comparison results are stored in `wazuh/analysis/analysis_results/<attackN>/`

## Results per Attack

| Attack | Detected? | Notes |
|---|---|---|
| Attack 1 — CoreDNS Flood | Not detected | DNS traffic doesn't pass through the API server, so nothing appears in the audit logs |
| Attack 2 — Kube-apiserver | Detected | |
| Attack 3 — Readiness probe | Detected | |
| Attack 4 — Endpoints flooding | Detected | |

## References

- `papers/losing-control-k8s-control-plane-interfaces.pdf` — Chen Wang, Hongbo Tang, Yu Zhao, Wei You, Jie Yang, Hang Qiu, *Losing control: Exposing security weaknesses of Kubernetes control plane interfaces*
- `papers/sharpening-k8s-audit-logs-context-awareness.pdf` — *Sharpening Kubernetes Audit Logs with Context Awareness*