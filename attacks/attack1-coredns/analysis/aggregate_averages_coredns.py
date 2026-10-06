#!/usr/bin/env python3
"""
Aggregates every CSV file matching a given label (e.g. "before", "after")
into a summary table of averages: per-run average and global average
(all OK rows across runs).

Rows where fetch_status != "OK" are excluded (missing measurement, not zero).
tcp_probe_loss_pct is filtered independently on tcp_probe_status == "OK".
cpu_coredns (from <label>_cpu_loop.csv) has no status column, so all its
rows are used as-is.

Usage (run from the folder containing the CSV files, e.g. results/):
    python3 aggregate_averages_coredns.py before
    python3 aggregate_averages_coredns.py after
"""

import argparse
import glob
import os
import sys

import pandas as pd


COLS = [
    "rejects_total",
    "conntrack_count",
    "cpu_us",
    "cpu_sy",
    "dns_req_total",
    "dns_resp_servfail",
    "cpu_coredns",
]

TCP_COL = "tcp_probe_loss_pct"

# Display labels for the notebook.
LABELS = {
    "rejects_total": "MaxConcurrentRejectCount",
    "conntrack_count": "nf_conntrack_count",
    "cpu_us": "CPU user (%)",
    "cpu_sy": "CPU system (%)",
    "dns_req_total": "DNS requests (total)",
    "dns_resp_servfail": "DNS responses SERVFAIL",
    "cpu_coredns": "CPU CoreDNS process (%)",
    "tcp_probe_loss_pct": "TCP packet loss to control plane (%)",
}


def find_csv_files(label: str, base_dir: str) -> list[str]:
    pattern = os.path.join(base_dir, f"{label}*.csv")
    return sorted(glob.glob(pattern))


def load_ok_rows(csv_path: str) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    if "fetch_status" in df.columns:
        df = df[df["fetch_status"] == "OK"]
    for col in COLS:
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
        help="Folder containing the <label>*.csv files (default: current folder)",
    )
    args = parser.parse_args()

    csv_files = find_csv_files(args.label, args.base_dir)
    if not csv_files:
        print(f"No file found for label '{args.label}' in {args.base_dir}")
        print(f"  (looked for: {args.label}*.csv)")
        sys.exit(1)

    print(f"{len(csv_files)} file(s) found for label '{args.label}':")
    for f in csv_files:
        print(f"  - {f}")
    print()

    per_run_rows = []
    all_dfs = []
    all_tcp_dfs = []
    for f in csv_files:
        raw = pd.read_csv(f)
        n_total = len(raw)

        df_ok = load_ok_rows(f)
        n_ok = len(df_ok)
        all_dfs.append(df_ok)

        tcp_ok = load_tcp_ok_rows(f)
        n_tcp_ok = len(tcp_ok)
        all_tcp_dfs.append(tcp_ok)

        run_name = os.path.basename(f)
        row = {
            "run": run_name,
            "OK_samples": f"{n_ok}/{n_total}",
            "TCP_OK_samples": f"{n_tcp_ok}/{n_total}",
        }
        for col in COLS:
            row[col] = round(df_ok[col].mean(), 1) if col in df_ok.columns and n_ok > 0 else "N/A"
        row[TCP_COL] = round(tcp_ok[TCP_COL].mean(), 1) if n_tcp_ok > 0 else "N/A"
        per_run_rows.append(row)

    per_run_table = pd.DataFrame(per_run_rows)
    print("=== Average per run (OK rows only) ===")
    print(per_run_table.to_string(index=False))
    print()

    combined = pd.concat(all_dfs, ignore_index=True)
    n_global = len(combined)

    combined_tcp = pd.concat(all_tcp_dfs, ignore_index=True)
    n_global_tcp = len(combined_tcp)

    all_cols = COLS + [TCP_COL]
    global_row = {"Metric": [], f"Global average ({args.label})": []}
    for col in COLS:
        global_row["Metric"].append(col)
        val = round(combined[col].mean(), 1) if col in combined.columns and n_global > 0 else "N/A"
        global_row[f"Global average ({args.label})"].append(val)
    global_row["Metric"].append(TCP_COL)
    tcp_val = round(combined_tcp[TCP_COL].mean(), 1) if n_global_tcp > 0 else "N/A"
    global_row[f"Global average ({args.label})"].append(tcp_val)

    global_table = pd.DataFrame(global_row)
    print(
        f"=== Global average over {n_global} OK sample(s) "
        f"({n_global_tcp} TCP OK sample(s)), {len(csv_files)} run(s) ==="
    )
    print(global_table.to_string(index=False))

    out_md = f"summary_{args.label}.md"
    with open(out_md, "w") as fh:
        fh.write(
            f"## Global average - {args.label} "
            f"({n_global} OK samples, {n_global_tcp} TCP OK samples, {len(csv_files)} run(s))\n\n"
        )
        fh.write(f"| Metric | Average ({args.label}) |\n")
        fh.write("|---|---|\n")
        for col in COLS:
            val = round(combined[col].mean(), 1) if col in combined.columns and n_global > 0 else "N/A"
            fh.write(f"| `{col}` | {val} |\n")
        fh.write(f"| `{TCP_COL}` | {tcp_val} |\n")

        if len(csv_files) > 1:
            fh.write(f"\n## Per-run detail ({args.label})\n\n")
            fh.write(
                "| Run | OK samples | TCP OK samples | "
                + " | ".join(f"`{c}`" for c in all_cols)
                + " |\n"
            )
            fh.write("|---|---|---|" + "---|" * len(all_cols) + "\n")
            for row in per_run_rows:
                fh.write(
                    f"| {row['run']} | {row['OK_samples']} | {row['TCP_OK_samples']} | "
                    + " | ".join(str(row[c]) for c in all_cols)
                    + " |\n"
                )

    print(f"\nMarkdown table saved -> {out_md}")


if __name__ == "__main__":
    main()