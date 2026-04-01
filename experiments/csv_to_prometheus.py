"""
csv_to_prometheus.py
=====================
Lit results.csv et pousse les métriques MTTD/MTTR
vers Prometheus via Pushgateway.

Les données apparaissent ensuite dans Grafana
exactement comme n'importe quelle métrique Prometheus.

Usage :
  python csv_to_prometheus.py                        # une fois
  python csv_to_prometheus.py --watch                # surveille le CSV en continu
  python csv_to_prometheus.py --gateway http://localhost:9092
"""

import argparse
import csv
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
DEFAULT_GATEWAY  = os.getenv("PUSHGATEWAY_URL", "http://localhost:9092")
DEFAULT_CSV      = os.getenv("RESULTS_CSV",     "results.csv")
JOB_NAME         = "observability_experiment"

LEVEL_NAMES = {
    "0": "no_monitoring",
    "1": "logs_only",
    "2": "logs_and_metrics",
    "3": "full_observability",
}

INCIDENT_NAMES = {
    "1": "db_down",
    "2": "cpu_overload",
    "3": "memory_limit",
    "4": "http_500",
    "5": "high_latency",
    "6": "disk_full",
}


# ──────────────────────────────────────────────
# Lecture du CSV
# ──────────────────────────────────────────────
def load_csv(filepath: str) -> list[dict]:
    rows = []
    with open(filepath, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                row['MTTD_sec'] = float(row['MTTD_sec']) \
                    if row.get('MTTD_sec') not in ('N/A', '', None) else None
                row['MTTR_sec'] = float(row['MTTR_sec']) \
                    if row.get('MTTR_sec') not in ('N/A', '', None) else None
                row['Detected'] = str(row.get('Detected', '')).lower() \
                                  in ('true', '1', 'yes', 'oui')
            except (ValueError, KeyError):
                pass
            rows.append(row)
    return rows


# ──────────────────────────────────────────────
# Construction du payload Prometheus text format
# ──────────────────────────────────────────────
def build_metrics(rows: list[dict]) -> str:
    """
    Construit le payload au format texte Prometheus.
    Chaque ligne du CSV → une métrique avec labels niveau + incident.
    """
    lines = []

    # ── En-têtes HELP et TYPE ──
    lines += [
        '# HELP experiment_mttd_seconds Mean Time To Detect — durée de détection de l\'incident',
        '# TYPE experiment_mttd_seconds gauge',
        '# HELP experiment_mttr_seconds Mean Time To Resolve — durée de résolution de l\'incident',
        '# TYPE experiment_mttr_seconds gauge',
        '# HELP experiment_detected Incident détecté (1=oui, 0=non)',
        '# TYPE experiment_detected gauge',
        '# HELP experiment_detection_rate_percent Taux de détection par niveau (%)',
        '# TYPE experiment_detection_rate_percent gauge',
        '# HELP experiment_mttd_avg_seconds MTTD moyen par niveau',
        '# TYPE experiment_mttd_avg_seconds gauge',
    ]

    # ── Métriques par ligne ──
    for row in rows:
        lvl = row.get('Niveau', '?')
        inc = row.get('Incident', '?')
        lvl_name = LEVEL_NAMES.get(lvl, f'level_{lvl}')
        inc_name = INCIDENT_NAMES.get(inc, f'incident_{inc}')
        labels = f'level="{lvl}",level_name="{lvl_name}",incident="{inc}",incident_name="{inc_name}"'

        # MTTD
        if row.get('MTTD_sec') is not None:
            lines.append(f'experiment_mttd_seconds{{{labels}}} {row["MTTD_sec"]}')

        # MTTR
        if row.get('MTTR_sec') is not None:
            lines.append(f'experiment_mttr_seconds{{{labels}}} {row["MTTR_sec"]}')

        # Detected
        detected_val = 1 if row.get('Detected') else 0
        lines.append(f'experiment_detected{{{labels}}} {detected_val}')

    # ── Agrégats par niveau ──
    from collections import defaultdict
    by_level = defaultdict(lambda: {'mttd': [], 'mttr': [], 'detected': 0, 'total': 0})
    for row in rows:
        lvl = row.get('Niveau', '?')
        by_level[lvl]['total'] += 1
        if row.get('Detected'):
            by_level[lvl]['detected'] += 1
            if row.get('MTTD_sec') is not None:
                by_level[lvl]['mttd'].append(row['MTTD_sec'])
            if row.get('MTTR_sec') is not None:
                by_level[lvl]['mttr'].append(row['MTTR_sec'])

    for lvl, d in by_level.items():
        lvl_name = LEVEL_NAMES.get(lvl, f'level_{lvl}')
        labels_lvl = f'level="{lvl}",level_name="{lvl_name}"'

        # Taux de détection
        rate = round(d['detected'] / d['total'] * 100, 1) if d['total'] > 0 else 0
        lines.append(f'experiment_detection_rate_percent{{{labels_lvl}}} {rate}')

        # MTTD moyen
        if d['mttd']:
            avg_mttd = round(sum(d['mttd']) / len(d['mttd']), 2)
            lines.append(f'experiment_mttd_avg_seconds{{{labels_lvl}}} {avg_mttd}')

        # MTTR moyen
        if d['mttr']:
            avg_mttr = round(sum(d['mttr']) / len(d['mttr']), 2)
            lines.append(f'experiment_mttr_avg_seconds{{{labels_lvl}}} {avg_mttr}')

    return '\n'.join(lines) + '\n'


# ──────────────────────────────────────────────
# Envoi vers Pushgateway
# ──────────────────────────────────────────────
def push_to_gateway(gateway_url: str, payload: str) -> bool:
    """
    Envoie les métriques au Pushgateway via HTTP PUT.
    URL format : http://pushgateway:9091/metrics/job/<job_name>
    """
    # Normalise l'URL (supprime le slash final)
    base = gateway_url.rstrip('/')
    url  = f"{base}/metrics/job/{JOB_NAME}"

    try:
        data = payload.encode('utf-8')
        req  = urllib.request.Request(
            url,
            data=data,
            method='PUT',
            headers={'Content-Type': 'text/plain; charset=utf-8'}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"[OK]  Pushgateway → HTTP {resp.status} | {len(data)} bytes envoyés")
            return True
    except urllib.error.HTTPError as e:
        print(f"[ERR] Pushgateway HTTP {e.code}: {e.reason}")
    except urllib.error.URLError as e:
        print(f"[ERR] Connexion Pushgateway impossible: {e.reason}")
        print(f"      Vérifie que le Pushgateway tourne sur {gateway_url}")
    return False


# ──────────────────────────────────────────────
# Mode watch — surveille le CSV et repousse dès qu'il change
# ──────────────────────────────────────────────
def watch_mode(csv_path: str, gateway_url: str, interval: int = 10):
    print(f"[WATCH] Surveillance de {csv_path} toutes les {interval}s")
    print(f"[WATCH] Pushgateway : {gateway_url}")
    print("[WATCH] Ctrl+C pour arrêter\n")

    last_mtime = 0
    last_size  = 0

    while True:
        try:
            p = Path(csv_path)
            if p.exists():
                mtime = p.stat().st_mtime
                size  = p.stat().st_size
                if mtime != last_mtime or size != last_size:
                    print(f"[WATCH] Changement détecté → rechargement")
                    rows = load_csv(csv_path)
                    payload = build_metrics(rows)
                    push_to_gateway(gateway_url, payload)
                    last_mtime = mtime
                    last_size  = size
                    print(f"[WATCH] {len(rows)} lignes traitées")
                else:
                    print(f"[WATCH] Pas de changement ({size} bytes)")
            else:
                print(f"[WATCH] {csv_path} introuvable — en attente...")
        except KeyboardInterrupt:
            print("\n[WATCH] Arrêt.")
            sys.exit(0)
        except Exception as e:
            print(f"[WARN] Erreur: {e}")

        time.sleep(interval)


# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Pousse les résultats CSV vers Prometheus Pushgateway"
    )
    parser.add_argument(
        '--csv', default=DEFAULT_CSV,
        help=f'Chemin vers results.csv (défaut: {DEFAULT_CSV})'
    )
    parser.add_argument(
        '--gateway', default=DEFAULT_GATEWAY,
        help=f'URL du Pushgateway (défaut: {DEFAULT_GATEWAY})'
    )
    parser.add_argument(
        '--watch', action='store_true',
        help='Surveille le CSV et repousse automatiquement à chaque modification'
    )
    parser.add_argument(
        '--interval', type=int, default=10,
        help='Intervalle en secondes en mode --watch (défaut: 10)'
    )
    args = parser.parse_args()

    if not Path(args.csv).exists():
        print(f"[ERR] Fichier introuvable : {args.csv}")
        print("      Lance d'abord le script PowerShell pour générer des résultats.")
        sys.exit(1)

    if args.watch:
        watch_mode(args.csv, args.gateway, args.interval)
    else:
        print(f"[INFO] Lecture de {args.csv} ...")
        rows = load_csv(args.csv)
        print(f"[INFO] {len(rows)} lignes trouvées")

        payload = build_metrics(rows)
        print(f"[INFO] Payload généré ({len(payload)} chars)")
        print(f"[INFO] Envoi vers {args.gateway} ...")

        success = push_to_gateway(args.gateway, payload)
        if success:
            print("\n[DONE] Métriques disponibles dans Grafana !")
            print("       Requêtes PromQL à utiliser dans Grafana :")
            print("         experiment_mttd_avg_seconds")
            print("         experiment_mttr_avg_seconds")
            print("         experiment_detection_rate_percent")
            print("         experiment_mttd_seconds{level='3'}")
        else:
            print("\n[FAIL] Vérifier que le Pushgateway est démarré.")
            sys.exit(1)


if __name__ == "__main__":
    main()