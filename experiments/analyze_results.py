# ==============================================================================
# analyze_results.py
# Analyse et visualisation des résultats MTTD/MTTR
# HAPI FHIR Observability Project — ENSIAS 2026
# Usage : python analyze_results.py
# ==============================================================================

import csv
import json
import os
import sys
from collections import defaultdict

# ── Dépendances optionnelles ──────────────────────────────────────────────────
try:
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
    import numpy as np
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("[WARN] matplotlib non installé. Graphiques désactivés.")
    print("       Installe avec : pip install matplotlib numpy")

RESULTS_FILE = "results_v2.csv"
OUTPUT_DIR   = "charts"

LEVEL_LABELS = {
    "0": "Niveau 0\n(Sans monitoring)",
    "1": "Niveau 1\n(Logs)",
    "2": "Niveau 2\n(Logs + Métriques)",
    "3": "Niveau 3\n(Complet)"
}

INCIDENT_LABELS = {
    "1": "DB Down",
    "2": "CPU Overload",
    "3": "Memory Limit",
    "4": "Erreurs 500",
    "5": "Latence",
    "6": "Disque Plein"
}

COLORS = ["#ef4444", "#f97316", "#eab308", "#22c55e"]  # rouge→vert par niveau


# ── Chargement des données ────────────────────────────────────────────────────
def load_results(filepath: str) -> list[dict]:
    """Charge le CSV et retourne une liste de dicts."""
    if not os.path.exists(filepath):
        # Données d'exemple si pas de fichier réel
        print(f"[WARN] {filepath} introuvable → utilisation de données d'exemple")
        return get_sample_data()

    rows = []
    with open(filepath, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Conversion des types
            row['Niveau']    = row['Niveau'].strip()
            row['Incident']  = row['Incident'].strip()
            row['Detected']  = row['Detected'].strip().lower() in ('true', '1', 'yes', 'oui')
            try:
                row['MTTD_sec'] = float(row['MTTD_sec']) if row['MTTD_sec'] not in ('N/A', '') else None
                row['MTTR_sec'] = float(row['MTTR_sec']) if row['MTTR_sec'] not in ('N/A', '') else None
            except (ValueError, KeyError):
                row['MTTD_sec'] = None
                row['MTTR_sec'] = None
            rows.append(row)
    print(f"[OK] {len(rows)} lignes chargées depuis {filepath}")
    return rows


def get_sample_data() -> list[dict]:
    """Données d'exemple réalistes (à remplacer par vos vrais résultats)."""
    sample = [
        # Niveau 0 — aucun monitoring, temps long ou non détecté
        {"Niveau":"0","Incident":"1","Description":"DB Down",      "Detected":True, "MTTD_sec":300,"MTTR_sec":480},
        {"Niveau":"0","Incident":"2","Description":"CPU Overload",  "Detected":False,"MTTD_sec":None,"MTTR_sec":None},
        {"Niveau":"0","Incident":"3","Description":"Memory Limit",  "Detected":False,"MTTD_sec":None,"MTTR_sec":None},
        {"Niveau":"0","Incident":"4","Description":"Erreurs 500",   "Detected":False,"MTTD_sec":None,"MTTR_sec":None},
        {"Niveau":"0","Incident":"5","Description":"Latence",       "Detected":True, "MTTD_sec":250,"MTTR_sec":400},
        {"Niveau":"0","Incident":"6","Description":"Disque Plein",  "Detected":False,"MTTD_sec":None,"MTTR_sec":None},
        # Niveau 1 — logs seulement
        {"Niveau":"1","Incident":"1","Description":"DB Down",       "Detected":True, "MTTD_sec":45, "MTTR_sec":120},
        {"Niveau":"1","Incident":"2","Description":"CPU Overload",  "Detected":True, "MTTD_sec":90, "MTTR_sec":180},
        {"Niveau":"1","Incident":"3","Description":"Memory Limit",  "Detected":False,"MTTD_sec":None,"MTTR_sec":None},
        {"Niveau":"1","Incident":"4","Description":"Erreurs 500",   "Detected":True, "MTTD_sec":30, "MTTR_sec":60},
        {"Niveau":"1","Incident":"5","Description":"Latence",       "Detected":True, "MTTD_sec":60, "MTTR_sec":150},
        {"Niveau":"1","Incident":"6","Description":"Disque Plein",  "Detected":False,"MTTD_sec":None,"MTTR_sec":None},
        # Niveau 2 — logs + métriques
        {"Niveau":"2","Incident":"1","Description":"DB Down",       "Detected":True, "MTTD_sec":15, "MTTR_sec":60},
        {"Niveau":"2","Incident":"2","Description":"CPU Overload",  "Detected":True, "MTTD_sec":20, "MTTR_sec":75},
        {"Niveau":"2","Incident":"3","Description":"Memory Limit",  "Detected":True, "MTTD_sec":25, "MTTR_sec":90},
        {"Niveau":"2","Incident":"4","Description":"Erreurs 500",   "Detected":True, "MTTD_sec":10, "MTTR_sec":45},
        {"Niveau":"2","Incident":"5","Description":"Latence",       "Detected":True, "MTTD_sec":18, "MTTR_sec":70},
        {"Niveau":"2","Incident":"6","Description":"Disque Plein",  "Detected":True, "MTTD_sec":35, "MTTR_sec":100},
        # Niveau 3 — observabilité complète
        {"Niveau":"3","Incident":"1","Description":"DB Down",       "Detected":True, "MTTD_sec":8,  "MTTR_sec":35},
        {"Niveau":"3","Incident":"2","Description":"CPU Overload",  "Detected":True, "MTTD_sec":12, "MTTR_sec":45},
        {"Niveau":"3","Incident":"3","Description":"Memory Limit",  "Detected":True, "MTTD_sec":10, "MTTR_sec":40},
        {"Niveau":"3","Incident":"4","Description":"Erreurs 500",   "Detected":True, "MTTD_sec":5,  "MTTR_sec":25},
        {"Niveau":"3","Incident":"5","Description":"Latence",       "Detected":True, "MTTD_sec":7,  "MTTR_sec":30},
        {"Niveau":"3","Incident":"6","Description":"Disque Plein",  "Detected":True, "MTTD_sec":15, "MTTR_sec":55},
    ]
    return sample


# ── Agrégation ────────────────────────────────────────────────────────────────
def aggregate(rows: list[dict]) -> dict:
    """Calcule les statistiques par niveau et par incident."""
    by_level    = defaultdict(lambda: {"mttd": [], "mttr": [], "detected": 0, "total": 0})
    by_incident = defaultdict(lambda: defaultdict(lambda: {"mttd": None, "mttr": None, "detected": False}))

    for r in rows:
        lvl = r['Niveau']
        inc = r['Incident']
        by_level[lvl]['total'] += 1
        if r['Detected']:
            by_level[lvl]['detected'] += 1
            if r['MTTD_sec'] is not None: by_level[lvl]['mttd'].append(r['MTTD_sec'])
            if r['MTTR_sec'] is not None: by_level[lvl]['mttr'].append(r['MTTR_sec'])
        by_incident[lvl][inc] = {
            "mttd": r['MTTD_sec'],
            "mttr": r['MTTR_sec'],
            "detected": r['Detected']
        }

    # Moyennes
    stats = {}
    for lvl, d in sorted(by_level.items()):
        stats[lvl] = {
            "avg_mttd":   round(sum(d['mttd']) / len(d['mttd']), 1) if d['mttd'] else None,
            "avg_mttr":   round(sum(d['mttr']) / len(d['mttr']), 1) if d['mttr'] else None,
            "detect_rate": round(d['detected'] / d['total'] * 100, 1),
            "detected":   d['detected'],
            "total":      d['total'],
            "raw":        d
        }

    return {"by_level": stats, "by_incident": by_incident}


# ── Rapport texte ──────────────────────────────────────────────────────────────
def print_report(stats: dict):
    print("\n" + "="*60)
    print("  RAPPORT D'ANALYSE — HAPI FHIR OBSERVABILITY")
    print("="*60)

    print("\nRÉSUMÉ PAR NIVEAU\n")
    print(f"{'Niveau':<8} {'MTTD moy':>10} {'MTTR moy':>10} {'Détection':>12}")
    print("-"*44)
    for lvl, s in sorted(stats['by_level'].items()):
        mttd = f"{s['avg_mttd']}s" if s['avg_mttd'] else "N/A"
        mttr = f"{s['avg_mttr']}s" if s['avg_mttr'] else "N/A"
        rate = f"{s['detect_rate']}%  ({s['detected']}/{s['total']})"
        print(f"  N{lvl}      {mttd:>10} {mttr:>10} {rate:>12}")

    # Calcul de l'amélioration N0→N3
    s0 = stats['by_level'].get('0', {})
    s3 = stats['by_level'].get('3', {})
    if s0.get('avg_mttd') and s3.get('avg_mttd'):
        ratio = round(s0['avg_mttd'] / s3['avg_mttd'], 1)
        print(f"\nAmélioration MTTD N0→N3 : ×{ratio} plus rapide")
    if s0.get('avg_mttr') and s3.get('avg_mttr'):
        ratio = round(s0['avg_mttr'] / s3['avg_mttr'], 1)
        print(f"Amélioration MTTR N0→N3 : ×{ratio} plus rapide")

    print("\nRECOMMANDATION\n")
    print("  • Niveau 2 (Logs+Métriques) → meilleur rapport coût/bénéfice")
    print("  • Niveau 3 (Complet)        → production critique, hôpitaux")
    print("  • Niveau 0                  → à éviter absolument en production")
    print("="*60 + "\n")


# ── Export JSON (pour le dashboard React) ────────────────────────────────────
def export_json(stats: dict, rows: list[dict], filepath: str = "results_analysis.json"):
    payload = {
        "summary": stats['by_level'],
        "raw_rows": rows,
        "by_incident": {
            lvl: dict(inc_data)
            for lvl, inc_data in stats['by_incident'].items()
        }
    }
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
    print(f"[OK] Export JSON → {filepath}")


# ── Graphiques matplotlib ──────────────────────────────────────────────────────
def make_charts(stats: dict, rows: list[dict]):
    if not HAS_MATPLOTLIB:
        print("[SKIP] Graphiques ignorés (matplotlib manquant)")
        return

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    levels = sorted(stats['by_level'].keys())
    level_names = [LEVEL_LABELS.get(l, f"N{l}") for l in levels]

    # ── Graphique 1 : MTTD moyen par niveau ──────────────────────────────────
    fig, ax = plt.subplots(figsize=(10, 5))
    mttd_vals = [stats['by_level'][l]['avg_mttd'] or 0 for l in levels]
    bars = ax.bar(level_names, mttd_vals, color=COLORS[:len(levels)], width=0.5, zorder=3)
    ax.set_title("MTTD moyen par niveau d'observabilité", fontsize=14, fontweight='bold', pad=15)
    ax.set_ylabel("Secondes")
    ax.grid(axis='y', alpha=0.3, zorder=0)
    for bar, val in zip(bars, mttd_vals):
        if val > 0:
            ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 2,
                    f"{val}s", ha='center', va='bottom', fontweight='bold')
    plt.tight_layout()
    out = os.path.join(OUTPUT_DIR, "chart_mttd.png")
    plt.savefig(out, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"[OK] Graphique MTTD → {out}")

    # ── Graphique 2 : MTTR moyen par niveau ──────────────────────────────────
    fig, ax = plt.subplots(figsize=(10, 5))
    mttr_vals = [stats['by_level'][l]['avg_mttr'] or 0 for l in levels]
    bars = ax.bar(level_names, mttr_vals, color=COLORS[:len(levels)], width=0.5, zorder=3)
    ax.set_title("MTTR moyen par niveau d'observabilité", fontsize=14, fontweight='bold', pad=15)
    ax.set_ylabel("Secondes")
    ax.grid(axis='y', alpha=0.3, zorder=0)
    for bar, val in zip(bars, mttr_vals):
        if val > 0:
            ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 2,
                    f"{val}s", ha='center', va='bottom', fontweight='bold')
    plt.tight_layout()
    out = os.path.join(OUTPUT_DIR, "chart_mttr.png")
    plt.savefig(out, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"[OK] Graphique MTTR → {out}")

    # ── Graphique 3 : Taux de détection ──────────────────────────────────────
    fig, ax = plt.subplots(figsize=(10, 5))
    detect_vals = [stats['by_level'][l]['detect_rate'] for l in levels]
    bars = ax.bar(level_names, detect_vals, color=COLORS[:len(levels)], width=0.5, zorder=3)
    ax.set_title("Taux de détection des incidents par niveau", fontsize=14, fontweight='bold', pad=15)
    ax.set_ylabel("Pourcentage (%)")
    ax.set_ylim(0, 110)
    ax.grid(axis='y', alpha=0.3, zorder=0)
    for bar, val in zip(bars, detect_vals):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 1,
                f"{val}%", ha='center', va='bottom', fontweight='bold')
    plt.tight_layout()
    out = os.path.join(OUTPUT_DIR, "chart_detection.png")
    plt.savefig(out, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"[OK] Graphique détection → {out}")

    # ── Graphique 4 : Heatmap MTTD par incident × niveau ─────────────────────
    incidents = sorted(set(r['Incident'] for r in rows))
    matrix = []
    for lvl in levels:
        row_data = []
        for inc in incidents:
            d = stats['by_incident'].get(lvl, {}).get(inc, {})
            row_data.append(d.get('mttd') or 0)
        matrix.append(row_data)

    matrix_np = np.array(matrix, dtype=float)
    fig, ax = plt.subplots(figsize=(11, 5))
    im = ax.imshow(matrix_np, cmap='RdYlGn_r', aspect='auto')
    ax.set_xticks(range(len(incidents)))
    ax.set_yticks(range(len(levels)))
    ax.set_xticklabels([INCIDENT_LABELS.get(i, i) for i in incidents], rotation=30, ha='right')
    ax.set_yticklabels([LEVEL_LABELS.get(l, l).replace('\n', ' ') for l in levels])
    ax.set_title("Heatmap MTTD (secondes) — Niveau × Incident", fontsize=13, fontweight='bold', pad=15)
    plt.colorbar(im, ax=ax, label="MTTD (s)")
    for i in range(len(levels)):
        for j in range(len(incidents)):
            val = matrix_np[i, j]
            txt = f"{int(val)}s" if val > 0 else "N/D"
            ax.text(j, i, txt, ha='center', va='center', fontsize=9,
                    color='white' if val > 100 else 'black', fontweight='bold')
    plt.tight_layout()
    out = os.path.join(OUTPUT_DIR, "chart_heatmap.png")
    plt.savefig(out, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"[OK] Heatmap → {out}")

    print(f"\n[OK] Tous les graphiques dans le dossier : ./{OUTPUT_DIR}/")


# ── MAIN ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    filepath = sys.argv[1] if len(sys.argv) > 1 else RESULTS_FILE
    rows  = load_results(filepath)
    stats = aggregate(rows)
    print_report(stats)
    export_json(stats, rows)
    make_charts(stats, rows)
    print("[DONE] Analyse terminée. Lance le dashboard : ouvrir index.html dans le navigateur.")
