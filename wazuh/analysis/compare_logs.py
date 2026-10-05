import pandas as pd
from pathlib import Path

# ---- Configuration ----
BASE_DIR = Path("../exports")
BASELINE_DIR = BASE_DIR / "baseline"

try:
    ATTACK_DIR
except NameError:
    ATTACK_DIR = BASE_DIR / "attack1-dns-flood"

BASELINE_SUFFIX = "baseline"

try:
    ATTACK_SUFFIX
except NameError:
    ATTACK_SUFFIX = "attack1"

BASELINE_DURATION_MIN = 5
ATTACK_DURATION_MIN = 5  # <-- ajuste selon la durée réelle de ta capture d'attaque

TERMS_FILES = [
    "verb",
    "objectRef_resource",
    "objectRef_namespace",
    "objectRef_subresource",
    "responseStatus_code",
    "authorization_decision",
    "authorization_reason",
    "sourceIPs",
    "user_groups",
    "user_username",
    "userAgent",
]

OUTPUT_DIR = Path("analysis_results") / ATTACK_SUFFIX
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# ---- Fonctions : tables Terms (2 colonnes) ----
def load_terms_csv(path):
    df = pd.read_csv(path)
    df.columns = ["category", "count"]
    return df


def load_scalar_csv(path):
    df = pd.read_csv(path)
    return int(df.iloc[0, -1])


def compare_field(field_name, baseline_dir, attack_dir, baseline_suffix, attack_suffix):
    base = load_terms_csv(baseline_dir / f"{field_name}_{baseline_suffix}.csv")
    attack = load_terms_csv(attack_dir / f"{field_name}_{attack_suffix}.csv")

    merged = pd.merge(
        base, attack,
        on="category", how="outer",
        suffixes=("_baseline", "_attack")
    ).fillna(0)

    merged["count_baseline"] = merged["count_baseline"].astype(int)
    merged["count_attack"] = merged["count_attack"].astype(int)

    merged["taux_baseline_par_min"] = merged["count_baseline"] / BASELINE_DURATION_MIN
    merged["taux_attack_par_min"] = merged["count_attack"] / ATTACK_DURATION_MIN

    merged["variation_absolue"] = merged["count_attack"] - merged["count_baseline"]
    merged["variation_taux_par_min"] = merged["taux_attack_par_min"] - merged["taux_baseline_par_min"]

    merged = merged.sort_values("count_attack", ascending=False).reset_index(drop=True)
    return merged


# ---- Fonctions : table imbriquée resource x verb (3 colonnes) ----
def load_resource_x_verb(path):
    df = pd.read_csv(path)
    df.columns = ["resource", "verb", "count"]
    return df


def compare_resource_x_verb(baseline_dir, attack_dir, baseline_suffix, attack_suffix):
    base = load_resource_x_verb(baseline_dir / f"resource_x_verb_{baseline_suffix}.csv")
    attack = load_resource_x_verb(attack_dir / f"resource_x_verb_{attack_suffix}.csv")

    merged = pd.merge(
        base, attack,
        on=["resource", "verb"], how="outer",
        suffixes=("_baseline", "_attack")
    ).fillna(0)
    merged["count_baseline"] = merged["count_baseline"].astype(int)
    merged["count_attack"] = merged["count_attack"].astype(int)
    merged["variation"] = merged["count_attack"] - merged["count_baseline"]
    merged = merged.sort_values("variation", ascending=False).reset_index(drop=True)
    return merged


# ---- Fonctions : série temporelle events per second ----
def load_events_per_second(path):
    df = pd.read_csv(path)
    df.columns = ["timestamp", "count"]
    df["timestamp"] = pd.to_datetime(df["timestamp"])
    return df


def compare_events_per_second(baseline_dir, attack_dir, baseline_suffix, attack_suffix):
    base = load_events_per_second(baseline_dir / f"events_per_second_{baseline_suffix}.csv")
    attack = load_events_per_second(attack_dir / f"events_per_second_{attack_suffix}.csv")

    stats = pd.DataFrame({
        "métrique": ["max_events_par_sec", "moyenne_events_par_sec"],
        "baseline": [base["count"].max(), round(base["count"].mean(), 2)],
        "attack": [attack["count"].max(), round(attack["count"].mean(), 2)],
    })
    stats["variation"] = stats["attack"] - stats["baseline"]
    return base, attack, stats


# ---- Comparaison globale ----
def run_comparison():
    results = {}
    for field in TERMS_FILES:
        try:
            results[field] = compare_field(
                field, BASELINE_DIR, ATTACK_DIR,
                BASELINE_SUFFIX, ATTACK_SUFFIX
            )
        except FileNotFoundError as e:
            print(f"Fichier manquant pour '{field}': {e}")

    summary = pd.DataFrame({
        "métrique": ["total_events", "patch_on_pods"],
        "baseline": [
            load_scalar_csv(BASELINE_DIR / f"total_events_{BASELINE_SUFFIX}.csv"),
            load_scalar_csv(BASELINE_DIR / f"patch_on_pods_{BASELINE_SUFFIX}.csv"),
        ],
        "attack": [
            load_scalar_csv(ATTACK_DIR / f"total_events_{ATTACK_SUFFIX}.csv"),
            load_scalar_csv(ATTACK_DIR / f"patch_on_pods_{ATTACK_SUFFIX}.csv"),
        ],
    })
    summary["variation"] = summary["attack"] - summary["baseline"]

    resource_x_verb = compare_resource_x_verb(
        BASELINE_DIR, ATTACK_DIR, BASELINE_SUFFIX, ATTACK_SUFFIX
    )

    eps_baseline, eps_attack, eps_stats = compare_events_per_second(
        BASELINE_DIR, ATTACK_DIR, BASELINE_SUFFIX, ATTACK_SUFFIX
    )

    # Export CSV de tout
    for field, df in results.items():
        df.to_csv(OUTPUT_DIR / f"compare_{field}.csv", index=False)
    summary.to_csv(OUTPUT_DIR / "compare_summary.csv", index=False)
    resource_x_verb.to_csv(OUTPUT_DIR / "compare_resource_x_verb.csv", index=False)
    eps_stats.to_csv(OUTPUT_DIR / "compare_events_per_second_stats.csv", index=False)

    return results, summary, resource_x_verb, eps_baseline, eps_attack, eps_stats


if __name__ == "__main__":
    results, summary, resource_x_verb, eps_baseline, eps_attack, eps_stats = run_comparison()
    print(summary)