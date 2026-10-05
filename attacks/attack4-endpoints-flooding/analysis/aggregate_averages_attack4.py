#!/usr/bin/env python3
"""
Aggregates the two measurement streams collected for the endpoints
flooding attack (Case 4) into a summary table of averages.

Two different kinds of CSV, from two different scripts:
  - <label>_cpu_loop.csv (k8s-cp): CPU usage of the kube-apiserver
    process specifically (capture-cpu-loop-attack4.sh), no status
    column, every row used.
  - <label>_iptables_<hostname>.csv (one per worker node, k8s-w1 and
    k8s-w2): local iptables rule counts (capture-iptables-snapshot.sh),
    no status column, every row used. Kept separate per node rather
    than merged, since the two nodes show different magnitudes (see
    the Results discussion on the k8s-w1/k8s-w2 asymmetry).

Usage (run from analysis/, with results/ as a sibling folder):
    python3 aggregate_averages_attack4.py before
    python3 aggregate_averages_attack4.py after
"""

import argparse
import glob
import os

import pandas as pd


CPU_COLS = [
    "cpu_kube_apiserver",
]

IPTABLES_COLS = [
    "total_rules",
    "endpoints_flood_svc_rules",
]

NODES = ["k8s-w1", "k8s-w2"]

LABELS = {
    "cpu_kube_apiserver": "CPU kube-apiserver process (%)",
    "total_rules": "iptables total rules",
    "endpoints_flood_svc_rules": "iptables rules referencing the attack Service",
}


def find_cpu_loop_files(label: str, base_dir: str) -> list[str]:
    return sorted(glob.glob(os.path.join(base_dir, f"{label}_cpu_loop*.csv")))


def find_iptables_files(label: str, node: str, base_dir: str) -> list[str]:
    return sorted(glob.glob(os.path.join(base_dir, f"{label}_iptables_{node}*.csv")))


def load_rows(csv_path: str, cols: list[str]) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    for col in cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    return df


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label", help="Run label (e.g. before, after)")
    parser.add_argument("--base-dir", default=".", help="Folder containing the CSVs")
    args = parser.parse_args()

    cpu_files = find_cpu_loop_files(args.label, args.base_dir)
    cpu_dfs = [load_rows(f, CPU_COLS) for f in cpu_files]
    cpu_combined = pd.concat(cpu_dfs, ignore_index=True) if cpu_dfs else pd.DataFrame(columns=CPU_COLS)

    node_combined = {}
    for node in NODES:
        files = find_iptables_files(args.label, node, args.base_dir)
        dfs = [load_rows(f, IPTABLES_COLS) for f in files]
        node_combined[node] = pd.concat(dfs, ignore_index=True) if dfs else pd.DataFrame(columns=IPTABLES_COLS)

    print(f"=== {args.label}: kube-apiserver CPU, {len(cpu_combined)} sample(s) ===")
    for col in CPU_COLS:
        val = round(cpu_combined[col].mean(), 1) if len(cpu_combined) > 0 else "N/A"
        print(f"  {col}: {val}")

    for node in NODES:
        df = node_combined[node]
        print(f"=== {args.label}: iptables on {node}, {len(df)} sample(s) ===")
        for col in IPTABLES_COLS:
            val = round(df[col].mean(), 1) if len(df) > 0 else "N/A"
            print(f"  {col}: {val}")

    out_md = f"summary_{args.label}.md"
    with open(out_md, "w") as fh:
        fh.write(f"## Global average - {args.label}\n\n")
        fh.write("| Metric | Average |\n|---|---|\n")
        for col in CPU_COLS:
            val = round(cpu_combined[col].mean(), 1) if len(cpu_combined) > 0 else "N/A"
            fh.write(f"| `{col}` | {val} |\n")
        for node in NODES:
            df = node_combined[node]
            for col in IPTABLES_COLS:
                val = round(df[col].mean(), 1) if len(df) > 0 else "N/A"
                fh.write(f"| `{col}` ({node}) | {val} |\n")

    print(f"\nMarkdown table saved -> {out_md}")


if __name__ == "__main__":
    main()