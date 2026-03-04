

```markdown
# HAPI FHIR Observabilite — Projet DevOps ENSIAS 2026

> Observabilite d'un serveur de sante FHIR avec Prometheus, Grafana, Loki et Tempo.  
> Soutenance : 5 Mars 2026

---

## Equipe

| Membre   | Role                          |
|----------|-------------------------------|
| Membre A | Infrastructure & Docker       |
| Membre B | Observabilite & Dashboards    |
| Membre C | Chaos Engineering & Tests     |
| Membre D | Analyse & Redaction           |

---

## Description du projet

Ce projet mesure l'impact de l'observabilite sur la detection et resolution d'incidents
dans un systeme de sante reel (HAPI FHIR).

On compare 4 niveaux d'observabilite :

| Niveau | Logs | Metriques | Traces | Stack                      |
|--------|------|-----------|--------|----------------------------|
| 0      | Non  | Non       | Non    | Aucun                      |
| 1      | Oui  | Non       | Non    | Loki + Promtail + Grafana  |
| 2      | Oui  | Oui       | Non    | + Prometheus               |
| 3      | Oui  | Oui       | Oui    | + Tempo (complet)          |

On simule 6 incidents et on mesure le MTTD (temps de detection)
et le MTTR (temps de resolution) pour chaque niveau.

---

## Architecture

```
+-----------------------------------------------------+
|                    Docker Compose                   |
|                                                     |
|  +----------+    +------------+    +-------------+  |
|  | HAPI FHIR|--->| Prometheus |--->|   Grafana   |  |
|  | :8080    |    | :9090      |    |   :3000     |  |
|  +----------+    +------------+    +-------------+  |
|       |                                  ^          |
|       |          +------------+          |          |
|       +--------->|    Loki    |----------+          |
|                  | :3100      |                     |
|  +----------+    +------------+                     |
|  | Postgres |    +------------+                     |
|  |          |    |   Tempo    |                     |
|  +----------+    +------------+                     |
+-----------------------------------------------------+
```

---

## Lancement rapide

### Prerequis

- Docker Desktop installe et en cours d'execution
- Git

### Installation

```bash
git clone https://github.com/hapifhir/hapi-fhir-jpaserver-starter.git
cd hapi-fhir-jpaserver-starter
```

### Lancer chaque niveau

```bash
# Niveau 0 - Application seule (sans monitoring)
docker compose up hapi-fhir hapi-fhir-postgres -d

# Niveau 1 - Logs uniquement
docker compose --profile logs up -d

# Niveau 2 - Logs + Metriques
docker compose --profile logs --profile metrics up -d

# Niveau 3 - Observabilite complete
docker compose --profile logs --profile metrics --profile traces up -d
```

---

## Acces aux interfaces

| Service    | URL                                    | Identifiants  |
|------------|----------------------------------------|---------------|
| HAPI FHIR  | http://localhost:8080/fhir/metadata    | —             |
| Grafana    | http://localhost:3000                  | admin / admin |
| Prometheus | http://localhost:9090                  | —             |
| Loki       | http://localhost:3100                  | —             |

---

## Scenarios d'incidents

| #  | Incident              | Commande de simulation                          |
|----|-----------------------|-------------------------------------------------|
| 1  | Base de donnees down  | docker compose stop hapi-fhir-postgres          |
| 2  | Surcharge CPU         | k6 run load-test.js (1000 req/sec)              |
| 3  | Fuite memoire         | Limiter le conteneur a 256 Mo                   |
| 4  | Latence reseau        | tc netem — delai artificiel de 2s               |
| 5  | Erreurs 500           | Requetes FHIR invalides en masse                |
| 6  | Disque plein          | Remplissage du volume avec fichiers temporaires |

### Protocole pour chaque experience

```
1. Lancer le niveau d'observabilite
2. Attendre 1 minute (stabilisation)
3. Noter T0 -> injecter l'incident
4. Detecter dans Grafana/logs -> noter T1
5. Resoudre -> noter T2
6. MTTD = T1 - T0 | MTTR = T2 - T0
7. docker compose down -> recommencer
```

---

## Resultats

Les resultats sont stockes dans `results/experiments.xlsx`.

| Niveau | Incident | T0       | T1       | T2       | MTTD | MTTR |
|--------|----------|----------|----------|----------|------|------|
| 0      | DB down  | 14:00:00 | ?        | ?        | ?    | ?    |
| 1      | DB down  | 14:15:00 | 14:15:30 | 14:16:00 | 30s  | 60s  |

> 24 lignes au total : 4 niveaux x 6 incidents

Generer les graphiques automatiquement :

```bash
python analyze_results.py
```

---

## Structure du projet

```
.
├── docker-compose.yml
├── grafana/
│   ├── dashboards/
│   └── datasources/
├── prometheus/
│   └── prometheus.yml
├── loki/
│   └── loki-config.yml
├── tempo/
│   └── tempo-config.yml
├── incidents/
│   ├── 01_db_down.sh
│   ├── 02_cpu_stress.sh
│   ├── 03_memory_limit.sh
│   ├── 04_network_latency.sh
│   ├── 05_errors_500.sh
│   └── 06_disk_full.sh
├── results/
│   ├── experiments.xlsx
│   └── graphs/
├── analyze_results.py
└── README.md
```

---

## Commandes utiles

```bash
docker compose up -d        # Lancer tout
docker compose stop         # Arreter sans supprimer
docker compose down         # Arreter + supprimer conteneurs
docker compose down -v      # Tout supprimer (conteneurs + donnees)
docker compose logs -f      # Voir les logs en direct
docker ps                   # Voir les conteneurs actifs
```

---

## Concepts cles

| Terme             | Definition                                                  |
|-------------------|-------------------------------------------------------------|
| MTTD              | Mean Time To Detect — temps moyen pour detecter un incident |
| MTTR              | Mean Time To Resolve — temps moyen pour resoudre un incident|
| FHIR              | Standard international d'echange de donnees de sante        |
| Observabilite     | Comprendre un systeme via ses logs, metriques et traces     |
| Chaos Engineering | Injecter des pannes volontaires pour tester la resilience   |

---

## References

- HAPI FHIR : https://hapifhir.io/
- Prometheus : https://prometheus.io/docs/
- Grafana    : https://grafana.com/docs/
- Loki       : https://grafana.com/docs/loki/
- Tempo      : https://grafana.com/docs/tempo/

---

ENSIAS — Projet Fiche 3 — Fevrier 2026
```
