#!/usr/bin/env python3
"""
Aggregates the three measurement streams collected for the kube-apiserver
attack (Case 2) into a summary table of averages.

Three CSV sources:
  - watch_apiserver_<label>.csv (k8s-cp): nf_conntrack occupancy and
    whole-node CPU usage, every row used.
  - <label>_cpu_loop.csv (k8s-cp): CPU usage of kube-apiserver and etcd
    specifically, no status column, every row used.
  - <label>_tcp_loss_loop<n>.csv (k8s-w2): TCP packet loss on the victim
    pod, only tcp_probe_status == OK rows averaged.

Usage (run from analysis/, with results/ as a sibling folder):
    python3 aggregate_averages.py before
    python3 aggregate_averages.py after
"""

import argparse
import glob
import os
import sys

import pandas as pd


# nf_conntrack occupancy and whole-node CPU, from watch_apiserver_<label>.csv.
COLS = [
    "conntrack_count",
    "cpu_us",
    "cpu_sy",
]

# kube-apiserver / etcd process CPU, from <label>_cpu_loop.csv.
CPU_LOOP_COLS = [
    "cpu_kube_apiserver",
    "cpu_etcd",
    "cpu_total",
]

# TCP packet loss on the victim container, from <label>_tcp_loss_loop*.csv.
TCP_COL = "tcp_probe_loss_pct"

# Display labels for the notebook.
LABELS = {
    "conntrack_count": "nf_conntrack_count",
    "cpu_us": "CPU user, whole node (%)",
    "cpu_sy": "CPU system, whole node (%)",
    "cpu_kube_apiserver": "CPU kube-apiserver process (%)",
    "cpu_etcd": "CPU etcd process (%)",
    "cpu_total": "CPU kube-apiserver + etcd (%)",
    "tcp_probe_loss_pct": "TCP packet loss to control plane (%)",
}


def find_watch_file(label: str, base_dir: str) -> list[str]:
    pattern = os.path.join(base_dir, f"watch_apiserver_{label}*.csv")
    return sorted(glob.glob(pattern))


def find_cpu_loop_files(label: str, base_dir: str) -> list[str]:
    pattern = os.path.join(base_dir, f"{label}_cpu_loop*.csv")
    return sorted(glob.glob(pattern))


def find_tcp_loss_files(label: str, base_dir: str) -> list[str]:
    pattern = os.path.join(base_dir, f"{label}_tcp_loss_loop*.csv")
    return sorted(glob.glob(pattern))


def load_watch_rows(csv_path: str) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    for col in COLS:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    return df


def load_cpu_loop_rows(csv_path: str) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    for col in CPU_LOOP_COLS:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    return df


def load_tcp_ok_rows(csv_path: str) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    if "tcp_probe_status" in df.columns:
        df = df[df["tcp_probe_status"] == "OK"]
    else:
        df = df.iloc[0:0]
    if TCP_COL in df.columns:
        df[TCP_COL] = pd.to_numeric(df[TCP_COL], errors="coerce")
    return df


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label", help="Run label (e.g. before, after)")
    parser.add_argument(
        "--base-dir",
        default=".",
        help="Folder containing the CSVs (default: current folder)",
    )
    args = parser.parse_args()

    watch_files = find_watch_file(args.label, args.base_dir)
    cpu_loop_files = find_cpu_loop_files(args.label, args.base_dir)
    tcp_files = find_tcp_loss_files(args.label, args.base_dir)

    if not watch_files and not cpu_loop_files and not tcp_files:
        print(f"No file found for label '{args.label}' in {args.base_dir}")
        print(
            f"  (looked for: watch_apiserver_{args.label}*.csv, "
            f"{args.label}_cpu_loop*.csv and {args.label}_tcp_loss_loop*.csv)"
        )
        sys.exit(1)

    print(f"Conntrack/whole-node CPU file(s) found for '{args.label}':")
    for f in watch_files:
        print(f"  - {f}")
    print(f"kube-apiserver/etcd CPU file(s) found for '{args.label}':")
    for f in cpu_loop_files:
        print(f"  - {f}")
    print(f"TCP loss file(s) found for '{args.label}':")
    for f in tcp_files:
        print(f"  - {f}")
    print()

    watch_dfs = [load_watch_rows(f) for f in watch_files]
    combined_watch = pd.concat(watch_dfs, ignore_index=True) if watch_dfs else pd.DataFrame(columns=COLS)
    n_watch = len(combined_watch)

    cpu_loop_dfs = [load_cpu_loop_rows(f) for f in cpu_loop_files]
    combined_cpu_loop = pd.concat(cpu_loop_dfs, ignore_index=True) if cpu_loop_dfs else pd.DataFrame(columns=CPU_LOOP_COLS)
    n_cpu_loop = len(combined_cpu_loop)

    tcp_dfs = [load_tcp_ok_rows(f) for f in tcp_files]
    combined_tcp = pd.concat(tcp_dfs, ignore_index=True) if tcp_dfs else pd.DataFrame(columns=[TCP_COL])
    n_tcp_ok = len(combined_tcp)
    n_tcp_total = sum(len(pd.read_csv(f)) for f in tcp_files) if tcp_files else 0

    saturated_pct = None
    if "saturated" in combined_watch.columns and n_watch > 0:
        saturated_pct = round(100 * combined_watch["saturated"].astype(str).str.lower().eq("true").mean(), 1)

    all_cols = COLS + CPU_LOOP_COLS + [TCP_COL]
    global_row = {"Metric": [], f"Global average ({args.label})": []}
    for col in COLS:
        global_row["Metric"].append(col)
        val = round(combined_watch[col].mean(), 1) if n_watch > 0 else "N/A"
        global_row[f"Global average ({args.label})"].append(val)
    for col in CPU_LOOP_COLS:
        global_row["Metric"].append(col)
        val = round(combined_cpu_loop[col].mean(), 1) if n_cpu_loop > 0 else "N/A"
        global_row[f"Global average ({args.label})"].append(val)
    global_row["Metric"].append(TCP_COL)
    tcp_val = round(combined_tcp[TCP_COL].mean(), 1) if n_tcp_ok > 0 else "N/A"
    global_row[f"Global average ({args.label})"].append(tcp_val)

    global_table = pd.DataFrame(global_row)
    print(
        f"=== Global average over {n_watch} conntrack/whole-node sample(s), "
        f"{n_cpu_loop} kube-apiserver/etcd sample(s), "
        f"{n_tcp_ok}/{n_tcp_total} TCP OK sample(s) ==="
    )
    print(global_table.to_string(index=False))
    if saturated_pct is not None:
        print(f"\nShare of time observed near saturation (>=90%): {saturated_pct}%")

    out_md = f"summary_{args.label}.md"
    with open(out_md, "w") as fh:
        fh.write(
            f"## Global average - {args.label} "
            f"({n_watch} conntrack/whole-node samples, "
            f"{n_cpu_loop} kube-apiserver/etcd samples, "
            f"{n_tcp_ok}/{n_tcp_total} TCP OK samples)\n\n"
        )
        fh.write(f"| Metric | Average ({args.label}) |\n")
        fh.write("|---|---|\n")
        for col in COLS:
            val = round(combined_watch[col].mean(), 1) if n_watch > 0 else "N/A"
            fh.write(f"| `{col}` | {val} |\n")
        for col in CPU_LOOP_COLS:
            val = round(combined_cpu_loop[col].mean(), 1) if n_cpu_loop > 0 else "N/A"
            fh.write(f"| `{col}` | {val} |\n")
        fh.write(f"| `{TCP_COL}` | {tcp_val} |\n")
        if saturated_pct is not None:
            fh.write(f"| `saturated (>=90%)` | {saturated_pct}% |\n")

    print(f"\nMarkdown table saved -> {out_md}")


if __name__ == "__main__":
    main()