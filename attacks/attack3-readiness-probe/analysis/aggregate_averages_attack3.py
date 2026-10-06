#!/usr/bin/env python3
"""
Aggregates every CSV file matching a given label (e.g. "before", "after")
into a summary table of averages: per-run average and global average
(all rows across runs).

cpu_kube_apiserver, cpu_etcd and cpu_total come from
capture-cpu-loop-attack3.sh, no status column, every row used as-is.

Usage (run from the folder containing the CSV files, e.g. results/):
    python3 aggregate_averages_attack3.py before
    python3 aggregate_averages_attack3.py after
"""

import argparse
import glob
import os
import sys

import pandas as pd


COLS = [
    "cpu_kube_apiserver",
    "cpu_etcd",
    "cpu_total",
]

# Display labels for the notebook.
LABELS = {
    "cpu_kube_apiserver": "CPU kube-apiserver process (%)",
    "cpu_etcd": "CPU etcd process (%)",
    "cpu_total": "CPU kube-apiserver + etcd (%)",
}


def find_csv_files(label: str, base_dir: str) -> list[str]:
    pattern = os.path.join(base_dir, f"{label}*.csv")
    return sorted(glob.glob(pattern))


def load_rows(csv_path: str) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    for col in COLS:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
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
    for f in csv_files:
        df = load_rows(f)
        n = len(df)
        all_dfs.append(df)

        run_name = os.path.basename(f)
        row = {"run": run_name, "samples": n}
        for col in COLS:
            row[col] = round(df[col].mean(), 1) if col in df.columns and n > 0 else "N/A"
        per_run_rows.append(row)

    per_run_table = pd.DataFrame(per_run_rows)
    print("=== Average per run ===")
    print(per_run_table.to_string(index=False))
    print()

    combined = pd.concat(all_dfs, ignore_index=True)
    n_global = len(combined)

    global_row = {"Metric": [], f"Global average ({args.label})": []}
    for col in COLS:
        global_row["Metric"].append(col)
        val = round(combined[col].mean(), 1) if col in combined.columns and n_global > 0 else "N/A"
        global_row[f"Global average ({args.label})"].append(val)

    global_table = pd.DataFrame(global_row)
    print(f"=== Global average over {n_global} sample(s), {len(csv_files)} run(s) ===")
    print(global_table.to_string(index=False))

    out_md = f"summary_{args.label}.md"
    with open(out_md, "w") as fh:
        fh.write(
            f"## Global average - {args.label} "
            f"({n_global} samples, {len(csv_files)} run(s))\n\n"
        )
        fh.write(f"| Metric | Average ({args.label}) |\n")
        fh.write("|---|---|\n")
        for col in COLS:
            val = round(combined[col].mean(), 1) if col in combined.columns and n_global > 0 else "N/A"
            fh.write(f"| `{col}` | {val} |\n")

        if len(csv_files) > 1:
            fh.write(f"\n## Per-run detail ({args.label})\n\n")
            fh.write(
                "| Run | Samples | " + " | ".join(f"`{c}`" for c in COLS) + " |\n"
            )
            fh.write("|---|---|" + "---|" * len(COLS) + "\n")
            for row in per_run_rows:
                fh.write(
                    f"| {row['run']} | {row['samples']} | "
                    + " | ".join(str(row[c]) for c in COLS)
                    + " |\n"
                )

    print(f"\nMarkdown table saved -> {out_md}")


if __name__ == "__main__":
    main()