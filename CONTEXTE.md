# Reprise de contexte — projet UM (webMethods Universal Messaging 12.1)

Dernière mise à jour : 2026-11-23 (Dépôts Git distants GitHub initialisés et synchronisés : `UM-administrator` pour les sources complètes et `UM-administrator-exec` pour le package de déploiement exécutable sans sources avec Git LFS).
L'utilisateur est francophone : répondre en français, de façon directe et technique, avec des modifications minimales.
**Consigne permanente** : après toute modification de `ui/`, `um_admin/` ou `docker-compose.um_admin.yml`, reconstruire l'image et recréer le conteneur sans attendre qu'on le demande (`cd UM && docker build -t um_admin:latest -f um_admin/Dockerfile . && UM_HOST_DIR="$PWD" docker compose -f docker-compose.um_admin.yml up -d` ; le compose n'a pas de `build`, `--build` seul ne fait rien), puis vérifier que le code embarqué est le bon (`docker exec um_admin grep ... /app/ui/...`) et que `/api/status` répond. Le code est copié dans l'image, pas monté.
Le fichier [`README.md`](README.md) décrit le projet côté utilisateur. Celui-ci décrit l'état du travail et ce qui reste à faire.

## 1. Demande précédente : terminée (2026-11-16)

> Onglet Administration (paramètres, vérification et bascule de `EnableMetricsMonitoring`) + conteneur `um_admin` (IHM + Prometheus).

| Étape | État |
|-------|------|
| Backend paramétrable (`settings.py`, `admin.py`, `server.py`, `diagnostic.py`) | Fait et testé |
| Onglet Administration (`tabBtnSet` / `tabSet`), ancien écran renommé « Cluster » | Fait (`node --check`, ids, rendu Chrome headless) |
| Conteneur `um_admin` : `um_admin/`, `docker-compose.um_admin.yml`, `.dockerignore` | Fait, en marche (8088 et 9090) |
| README | À jour |
| Non-régression depuis `um_admin` (source Prometheus) | Sauvegarde OK, reconstruction OK (51 événements), création de cluster depuis zéro OK |

Correctifs faits pendant les tests : label de cible Prometheus `um_node` (et non `node`, qui cassait le motif `{name="..."}` de `server.py`), et `status(live=True)` : création, attente de formation et contrôle après reconstruction lisent les nœuds en direct (`docker exec`) même si la source est `prometheus` (valeurs en retard d'un scrape, ce qui faisait échouer la vérification après reconstruction).
Non relancé après ce dernier correctif : une création de cluster depuis zéro (elle avait réussi avant, avec la même logique hors `live`).

Idées non demandées : authentification de l'IHM, publier 8088/9090 sur 127.0.0.1 seulement, `.gitignore` (`backups/`, `ui/settings.json`), conversion cluster vers standalone.

## 1bis. Évolutions de l'onglet Diagnostic et des sauvegardes (2026-11-16, terminées et testées sur le cluster)

| Sujet | Ce qui a été fait |
|-------|-------------------|
| Seuils d'alerte | `settings.THRESHOLDS` (source unique ; `diagnostic.DEFAULT_THR` en dérive), clé `thresholds` de `settings.json`, formulaire dans Administration. `drop_ratio_pct`, `drop_min_base`, `drop_on_zero`, `queued_warn`, `cpu_warn_pct`, `history_keep` |
| Mode **Temps réel** | `GET /api/diagnostic/live` = `diagnose(live=True)` : état du trafic + détail par nœud, sans synthèse ni `ClusterState`/`HealthChecker` (`runUMTool` coûte ≈ 7 s ; le live prend ≈ 1 s). Rafraîchi toutes les 4 s côté navigateur avec décompte animé, en pause si l'onglet est masqué. Jamais enregistré |
| Mode **Snapshot** | `GET /api/diagnostic` (≈ 8 s) : diagnostic complet, enregistré dans `diagnostics/<AAAAMMJJ-HHMMSS>.json` (à côté de `settings.json`, donc dans `/data` pour `um_admin`) ; arrête le temps réel |
| Historique | `GET /api/diagnostic/history`, `GET /api/diagnostic/history/<id>`, `POST /api/diagnostic/history/delete`. Bandeau « ARCHIVE » à la consultation. Rotation à `history_keep` |
| Suppression | `POST /api/backups/delete` et `.../history/delete` : même contrat `{"ids": [...]}` ou `{"all": true}`, table `DELETE_ROUTES` dans `server.py`. Suppression de sauvegarde refusée (409) pendant un job. Identifiants validés par regex (pas de traversée de chemin) |
| Stores | repliés par défaut (volet `<details>`, trié par nombre d'événements) dans Cluster et dans « Détail par nœud » ; l'état ouvert survit au rafraîchissement |

Corrections de défauts trouvés pendant ces tests (à ne pas réintroduire) :
- `sag_um_server_cpu_usage_ratio` est **déjà en pourcents** (33,8 = 33,8 %) : ne pas multiplier par 100 (l'UI affichait 3542 %, la règle CPU comparait à 0,85).
- Pools de threads : l'alerte se déclenche si la **moyenne** de `Queued` ≥ `queued_warn`, pas dès qu'elle est non nulle (0,4 s'affichait « 0 » mais était orange).
- Connexions clients : valeur **instantanée** (métrique, sinon dernier `ServerStatusLog`), pas la moyenne des 3 dernières minutes (retard de plusieurs minutes). Le diagnostic lit les métriques en `docker exec` (instantané) et ne passe par Prometheus (échantillon toutes les 15 s) qu'en repli.
- `drop_on_zero = 0` désactive aussi l'alerte « connexions tombées à 0 » (fin de test normale).

**Créer le cluster** (`create_cluster`) : si **aucun** nœud ne tourne, il fait `compose down -v` puis `up -d` (conteneurs ET volumes recréés à neuf, sinon un simple `up -d` reprend l'ancien cluster et ses données), attend `healthy`, puis `CreateCluster`. Il ne lit jamais `backups/` (seul « Reconstruire » restaure). Si seulement certains nœuds sont arrêtés : refus (on ne supprime pas les volumes de nœuds qui tournent). L'UI demande confirmation quand tout est arrêté (volumes supprimés). Testé : 0 événement, 0 store par nœud, volumes datés du moment du clic, 1 Master + 2 Slave.

**Création de cluster : aucun store applicatif (vérifié 2026-11-18)** : `create_cluster` ne fait que `CreateCluster -convertlocal=true` puis `ensure_connection_factory`. Aucun `CreateChannel`/`CreateQueue`/`CreateJMSQueue` dans `UM/`. Sur un cluster recréé par l'utilisateur, chaque nœud n'a qu'**un store : `/naming/defaultContext`** (le JNDI, qui contient la connection factory ; comptée comme 1 événement). Une instance UM vierge (`um_probe`) n'a aucun store. Les stores `orders`, `events`, `/stress/q1..5`, `/stress/t1..5` vus auparavant venaient des tests de l'utilisateur, pas de la création. Réponse déjà donnée : s'il est vide, le champ « Connection factory JMS » supprime aussi ce store.

**Sauvegarde à froid / à chaud (2026-11-18)** : `POST /api/backup` accepte `{"mode": "froid"|"chaud"}` ; `backup_core(log, keep_stopped, mode)` délègue à `backup_rolling()` pour le chaud (arrêt/archivage/redémarrage d'un nœud à la fois, `wait_formed` entre chaque, cluster formé et 3 nœuds minimum exigés avant tout arrêt, nettoyage et redémarrage du nœud courant en cas d'échec). `manifest.json` porte `mode` ; `rebuild` n'échoue pas sur un écart d'événements si `mode == "chaud"` (avertissement). Testé : 3 nœuds sauvegardés, `2001..2003/health` : au moins 2 nœuds joignables en permanence. **Non testé** : une reconstruction depuis une sauvegarde à chaud.
- La sauvegarde à chaud ne copie jamais un volume en marche (doc UM : risque de corruption) ; c'est une sauvegarde « roulante », pas un snapshot instantané.

**Progression par nœud et connection factory JMS (2026-11-18)** :
- `server.py` : `node_progress()` (0 % conteneur absent, 10 % métriques illisibles, 20 % + jusqu'à 50 % selon les événements retrouvés / attendus du manifest, + 30 % une fois Master/Slave) ; `wait_formed(log, timeout, expected)` renseigne `JOB.progress` (exposé par `GET /api/job`, champ `progress`) et journalise `Progression : um1 70 % ...`. Estimation : UM n'expose aucun pourcentage de recovery. Barres affichées au-dessus du journal (`#jobprog`).
- Retouches de l'utilisateur dans `node_progress` : des caractères parasites (`ion`, ` f`, `l`) ont rendu `server.py` non compilable ; corrigé. Toujours lancer `python3 -m py_compile ui/*.py` après une modification, même quand l'utilisateur a édité le fichier entre-temps.
- `ensure_connection_factory()` : appelée en fin de `create_cluster` et de `rebuild` (cluster formé). Crée la factory JMS (réglage `jms_connection_factory`, défaut `local_um`, **vide = ne rien créer**) avec `-connectionurl=` la liste des rnames. Idempotente (`ViewConnectionFactory` rc 0 = présente, rc 48 = absente ; `CreateConnectionFactory` sur un nom existant échoue en `NameAlreadyBoundException`). Le JNDI est répliqué : une création sur un nœud suffit. Utile pour l'alias JMS d'Integration Server (l'IHM ne s'y connecte pas elle-même). `DeleteConnectionFactory` existe pour la retirer.


**Correctif chemins dans `um_admin` (2026-11-18)** : `/data/settings.json` du conteneur contenait `compose_file=/app/docker-compose.yml` et `backup_dir=/app/backups` (inexistants dans le conteneur, où seul `ui/` est copié dans `/app`) : « Fichier compose introuvable » à la sauvegarde. Corrigé dans le fichier de config et dans le code : `settings.PROJECT_DIR` = `UM_HOST_DIR` si défini, sinon le dossier parent de `ui/` ; les valeurs par défaut `compose_file` et `backup_dir` en dérivent, donc « Valeurs par défaut » + Enregistrer ne réécrit plus `/app/...`. Piège : après une erreur de ce type, un dossier de sauvegarde vide peut rester dans `/app/backups` du conteneur (supprimé à la main).

**Correctif `inspect_all` (2026-11-18)** : quand un conteneur est supprimé (ex. `docker rm -f um1`), `docker inspect um1 um2 um3` affiche le JSON des conteneurs présents **puis** `error: no such object: um1` sur stderr ; `run()` concatène stdout+stderr, donc `json.loads` échouait et **tous** les nœuds passaient « absent » (UI tout éteinte alors que um2/um3 tournaient). `admin.inspect_all` lit maintenant uniquement le premier document avec `json.JSONDecoder().raw_decode`. Vérifié : um1 absent, um2 Master, um3 Slave, état `degraded`. Piège : le fichier compose de `um_admin` n'a pas de section `build`, donc `up -d --build` ne reconstruit rien : lancer `docker build -t um_admin:latest -f um_admin/Dockerfile .` depuis `UM/` puis `UM_HOST_DIR="$PWD" docker compose -f docker-compose.um_admin.yml up -d`.

**Reconstruction d'un seul nœud absent (2026-11-18)** : sur la carte d'un nœud dont le conteneur est « absent », bouton « Reconstruire umN » (`data-rebuildnode`, `index.html`) → `POST /api/rebuild-node {"node": "um1"}` → `server.rebuild_node()`. Refuse si le nœud n'est pas absent ou si aucun autre nœud ne tourne. Volumes présents (cas d'un simple `docker rm`) : `compose up -d <nœud>` seulement, le nœud rejoint le cluster et se resynchronise depuis le Master (doc UM : ne restaurer que le nœud en défaut). Volumes absents : `compose up --no-start <nœud>`, restauration des `tar` du nœud depuis la sauvegarde la plus récente qui les contient, puis démarrage. Testé sur `um1` supprimé, volumes présents : Slave à 100 % en ~20 s, `local_um` déjà présente. **Non testé** : la branche volumes manquants (restauration d'un `tar` ancien dans un cluster vivant ; la resynchronisation depuis le Master n'est pas vérifiée).

**Diagnostic : nœud recréé resté vert (2026-11-18)** : `node_traffic` utilisait `rows[-3:]` = les 3 dernières *lignes* de la série par minute. Un nœud recréé n'écrit pas de ligne pour les minutes où il était absent, donc ces 3 lignes dataient d'avant l'arrêt (avec leur trafic) et l'indicateur Débit restait vert jusqu'à 3 nouvelles minutes. Maintenant `recent` = lignes des 3 dernières minutes **réelles** (selon `log.now`), et `quick` = minute courante + précédente : sans client (`Connections == 0`) et sans débit sur `quick`, le débit passe tout de suite en « aucun trafic (repos) ». Testé sur cas synthétique (`node_traffic`) ; non rejoué sur un vrai nœud recréé. Si `drop_on_zero = 1` (défaut), « Connexions clients » reste rouge après une chute à 0 ; à 0 elle passe en repos.

**Diagnostic (2026-11-18)** : la cartouche « Synthèse » est réduite par défaut (`sumOpen = false` dans `index.html`). L'ancienne auto-ouverture quand `counts.critical > 0` a été retirée ; le bouton « Agrandir » et les pastilles (filtre) déplient. Non vérifié visuellement dans un navigateur.

Constat sur le cluster de test : après des tests de charge intensifs, `um1` (Master) conserve les buffers `DirectMemory` (~945 Mo / 1 Go) alloués, ce qui déclenche le seuil interne `MemoryManager: DirectMemory: Warning threshold reached` qui boucle activement pour tenter de forcer le GC, générant 35-40 % de CPU au repos.
- **Diagnostic temps réel optimisé** :
  - **Ping JVM & Wrapper** : filtrés temporellement (< 3 min) pour ne pas afficher en direct un ralentissement JVM survenu 15 minutes plus tôt pendant le tir.
  - **Pools de threads** : n'alerte que si la file instantanée est saturée (`q_now >= queued_warn`), sans alerte trompeuse quand le pic est terminé et absorbé.
  - **Débit au repos** : si le débit est à 0 et qu'aucun client n'est connecté (`drop_on_zero = 0`), affiché en `idle` (« aucun trafic (repos) ») au lieu d'une alerte critique.

### Volumétrie et robustesse (2026-11-16)

Détail et chiffres dans la section « Volumétrie et robustesse » du [`README.md`](README.md). Points de code à connaître :
- `diagnostic.py` : constantes `TAIL_BYTES`, `DATA_SCAN_TTL`, `CMD_TIMEOUT`, `MAX_STORES`, `MAX_FINDINGS_PER_RULE` ; `SCRIPT` (collecte, `tail -c` + `T()` = `timeout`) et `DATA_SCRIPT` (parcours de `data/`, un seul `find|awk`) ; `_DATA_CACHE`, `_build_script`, `_finish_sections` ; `cap_stores()` appelé en fin de `diagnose`.
- `server.py` : `Shared` (cache + verrou + repli `stale`), `LIVE` et `STATUS` ; `status(live, full)` (`full=True` obligatoire pour toute comparaison de stores) ; `measure_volumes`, `io_timeout`, `settle_timeout`, `fmt_bytes`, `SAFETY` (1,15), `MIN_IO_RATE` ; `Job.log` borné ; `MAX_BODY` ; `Handler._post` enveloppé dans un `try/except`.
- `index.html` : `nextDelay`, `pace`, `freshness`, `nf`, `evtOf`, `storesOf` ; `tick()` s'auto-planifie avec `setTimeout` (ne jamais revenir à `setInterval`).
- Les réponses `/api/status` et `/api/diagnostic/live` portent `meta` (`age`, `took`, `stale`, `error`, `ttl`).
- Piège : `/api/status` suit la source de métriques configurée (Prometheus = retard jusqu'à 15 s) ; juste après un redémarrage de nœuds il peut afficher « Aucun cluster » quelques secondes alors que `wait_formed` (lecture directe) a déjà vu le cluster formé.
- Limite connue : la sauvegarde est à froid et séquentielle ; non testée au-delà de 50 Mo de données réelles.

## 2. Environnement de référence et Dépôts Git

### Dépôts Git GitHub associés au projet
1. **Dépôt avec code source complet : `UM-administrator`**
   - **URL distante** : `https://github.com/binaryfloppy/UM-administrator`
   - **Dossier local** : `/Users/julien/.bob/playground/UM`
   - **Contenu** : sources Python de l'IHM (`ui/`), Dockerfile (`um_admin/`), fichiers compose, scripts shell, configurations et documentations Markdown (`README.md`, `CONTEXTE.md`).
   - **Exclusions (`.gitignore`)** : `backups/`, `__pycache__/`, `.DS_Store`, `diagnostics/`, `ui/settings.json`.

2. **Dépôt exécutable / déploiement autonome sans sources : `UM-administrator-exec`**
   - **URL distante** : `https://github.com/binaryfloppy/UM-administrator-exec`
   - **Dossier local** : `/Users/julien/Documents/bob/um_admin`
   - **Contenu** : scripts de déploiement (`deploy.sh`, `deploy.conf`), fichiers compose (`docker-compose.yml`, `docker-compose.um_admin.yml`), scripts utilitaires (`scripts/um_cluster.sh`), documentations (`README.md`, `CONTEXTE.md`), et image Docker pré-packagée (`um_admin.tar` gérée via **Git LFS**). Permet de déployer sans partager le code source Python.

### Caractéristiques de l'environnement
- Dossier de travail : `/Users/julien/.bob/playground`, projet dans `UM/`. Mac arm64, Docker 29.1.3.
- Image : `ibmwebmethods.azurecr.io/universalmessaging-server:12.1` (linux/amd64, émulée). Écoute sur 9000 (nhp), exporteur Prometheus sur 9200 (`curl` présent dans l'image, **pas de gzip** : `tar` non compressé).
- 3 conteneurs `um1`, `um2`, `um3` (hostnames identiques), ports hôte 2001, 2002, 2003 vers 9000. Realms `umnode1..3`.
- **`REALM_NAME` doit faire au moins 6 caractères** : le serveur s'en sert comme mot de passe du keystore cluster. Avec `um1`, le cluster ne se forme pas.
- Cluster `umcluster` créé avec `CreateCluster -clustername=umcluster -convertlocal=true -rnames=nsp://um1:9000,nsp://um2:9000,nsp://um3:9000`. État : 1 Master + 2 Slave (le Master change après un redémarrage de nœud ; au 2026-11-18 11:06 : `um1`). L'utilisateur recrée le cluster à volonté pour ses tests : **ne pas supposer un nombre de stores** (13 avec des stores de test, 1 sur un cluster neuf : `/naming/defaultContext`). Sauvegardes présentes : seulement `20261118-104005` (froid) ; celles du 16/11 et d'autres du 18/11 ont été supprimées.
- Réseau compose : `um_default`. Volumes : `um_um{1,2,3}-{data,logs,conf}`.
- Outil CLI : `/opt/webmethods/UniversalMessaging/tools/runner/runUMTool.sh`. Répertoire du realm : `/opt/webmethods/UniversalMessaging/server/umserver`.
- Il n'y a pas d'Integration Server dans ce projet, seulement UM. L'utilisateur en a un à part : son alias JMS utilise la connection factory `local_um` (JNDI du cluster UM) ; l'IHM ne s'y connecte pas.
- Docs locales : `documentation webMethods/SSEUZ5Z_12.1.0_20261103/content/SSEUZ5Z_12.1.0/*.html` et `documentation webMethods/wm-um-12.1.0/*.txt`.

## 3. Arborescence

```
UM/
├── docker-compose.yml        # 3 services, projet "um"
├── README.md                 # doc utilisateur
├── docker-compose.um_admin.yml, .dockerignore
├── um_admin/                 # Dockerfile, entrypoint.sh, prometheus.yml
├── CONTEXTE.md               # ce fichier
├── scripts/                  # Répertoire cible des scripts autonomes générés (um_cluster.sh)
├── backups/<AAAAMMJJ-HHMMSS>/  # *.tar + manifest.json (contient clés et certificats : ne pas versionner)
├── (settings.json, diagnostics/*.json)  # dans /data du conteneur um_admin, ou ui/ hors conteneur
└── ui/
    ├── server.py             # HTTP + jobs (création cluster, sauvegarde, reconstruction, génération de scripts)
    ├── settings.py           # paramètres, validation, persistance ui/settings.json (absent tant qu'on n'enregistre rien)
    ├── admin.py              # métriques (3 sources), runUMTool, vérifications, EnableMetricsMonitoring
    ├── diagnostic.py         # diagnostic complet / temps réel, historique, cartouche « État du trafic »
    ├── script_gen.py         # générateur du script Bash autonome
    └── index.html            # IHM (onglets Cluster, Monitoring, Diagnostic, Scripts, Administration)
.bob/skills/um-javascript-api/SKILL.md   # skill Bob sur l'API JS Nirvana (non enregistré dans la liste des skills actifs)
```

## 4. Backend : comment ça marche

### `settings.py`
- Valeurs par défaut identiques à l'environnement de référence : sans `settings.json`, rien ne change.
- Clés : `cluster_name`, `nodes[]` (`name`, `container`, `rname`, `metrics_url`), `image`, `docker_network` (défaut `um_default`), `compose_project`, `compose_file`, `volume_pattern` (`{project}_{node}-{vol}`), `backed_volumes` (`data`, `conf`), `backup_dir`, `runner`, `realm_dir`, `um_username`, `metrics_source` (`docker` | `http` | `prometheus`), `prometheus_url`, `prometheus_targets_file`, `jms_connection_factory` (défaut `local_um`, vide = non créée), `thresholds` (voir §1bis). `PROJECT_DIR` (dérivé de `UM_HOST_DIR`) fournit les défauts de `compose_file` et `backup_dir`.
- Variables d'environnement : `UM_ADMIN_CONFIG` (chemin du JSON), `UM_ADMIN_HOST` (défaut `127.0.0.1`), `UM_ADMIN_PORT` (défaut `8088`), `UM_ADMIN_UM_PASSWORD` (jamais écrit sur disque).
- Validation stricte par expressions régulières : certaines valeurs (`realm_dir`, hôtes, ports) sont injectées dans un script shell exécuté dans les conteneurs. Les refus testés : nom avec `;`, `file://` comme URL de métriques, `realm_dir` avec espace ou `;`, `metrics_source=prometheus` sans URL.
- `save()` écrit le JSON de façon atomique et génère le fichier de cibles Prometheus (`file_sd`) si `prometheus_targets_file` est renseigné.

### `admin.py`
- `fetch_metrics(run, cfg, nd)` retourne `(texte, erreur)`. Sources :
  - `docker` : `docker exec <conteneur> curl http://localhost:<port><chemin>` ;
  - `http` : GET direct sur `metrics_url` ;
  - `prometheus` : API `/api/v1/query?query={instance="hote:port"}`, reconstitution du format texte (les labels `instance`, `job`, `__name__` sont retirés).
- `um_tool(run, cfg, nd, tool, *args, with_rname=True)` : `docker exec <conteneur> <runner> <tool> -rname=...` ; ajoute `-username/-password` si `um_username` est renseigné.
- `metrics_enabled` / `set_metrics_enabled` : lecture par `EditRealmConfiguration -listgroupconfiguration=Monitoring_Config`, écriture par `-Monitoring_Config.EnableMetricsMonitoring=true|false`, puis relecture.
- `run_checks(run, cfg)` retourne `{"checks": [{scope, level (ok|warning|critical|info), title, detail, fix}], "metrics_config": [{node, enabled, error}]}`.
- **Piège 1 :** `/api/checks` utilise `_collect` (une closure `add` par nœud) : ne pas retoucher sans relancer le test (21 contrôles OK attendus).
- **Piège 2 :** `EnableMetricsMonitoring` est répliqué dans tout le cluster. Désactivé sur `um3`, il l'a été sur `um1`, `um2` et `um3` ; réactivé sur `um3`, il l'a été partout. Effet immédiat, sans redémarrage. L'écran doit donc proposer **un seul interrupteur pour le cluster**, pas un par nœud.

### `server.py` — routes
| Route | Rôle |
|-------|------|
| `GET /api/status` | État par nœud : conteneur, rôle, événements par queue/channel, `metrics_error` |
| `GET /api/monitoring` | Métriques détaillées des queues et topics (éléments, publiés, consommés, en attente, connexions, mémoire, disque, répartition par nœud) |
| `POST /api/purge` | `{"store": "nom"}` ou `{"stores": [...]}` ou `{"all": true, "kind": "queue"|"topic"}` : purge les événements via `PurgeEvents` |
| `GET /api/job` | Journal de la tâche en cours + `progress` (`{noeud: %}` pendant la formation du cluster) |
| `GET /api/backups` | Liste des sauvegardes |
| `GET /api/diagnostic` | Snapshot complet (≈ 8 s), enregistré dans l'historique (`history_id` dans la réponse) |
| `GET /api/diagnostic/live` | Version légère (≈ 1 s), jamais enregistrée |
| `GET /api/diagnostic/history`, `/history/<id>` | Liste (id, date, niveau, compteurs) / rapport archivé |
| `POST /api/diagnostic/history/delete`, `POST /api/backups/delete` | `{"ids": [...]}` ou `{"all": true}` ; 400 id invalide, 409 job en cours (sauvegardes) |
| `GET /api/settings` | `{settings, defaults, file, um_password_set}` |
| `POST /api/settings` | Valide et enregistre (400 + message si invalide) |
| `GET /api/checks` | Vérifications d'environnement (voir `admin.run_checks`) |
| `POST /api/metrics-monitoring` | `{"node": "...", "enabled": true|false}` |
| `POST /api/create-cluster`, `/api/backup`, `/api/rebuild` | Jobs asynchrones (un seul à la fois, 409 sinon). `/api/backup` accepte `{"mode": "froid"\|"chaud"}` (défaut froid, 400 sinon) |

### `diagnostic.py`
- Collecte par nœud, **nœuds arrêtés compris** (volumes `data`/`logs` relus en lecture seule via `docker run`). Sources : `docker inspect`, métriques, `/health`, `nirvana.log` (le `ServerStatusLog`, toutes les 5 s, sert d'historique : débit publié/consommé, mémoire, CPU, tâches en file, file cluster), `UMRealmService.log`, `Server_Common.conf`, heap dumps, `ClusterState`, `HealthChecker`.
- Règles : quorum, Master absent ou multiples, état Offline, pairs injoignables, trous de log (JVM gelée ; les arrêts propres sont ignorés), GC, flow control (70/80/90/94 % du heap), OutOfMemory, disque, descripteurs de fichiers, deadlocks, pools de threads, recovery en boucle, stores désynchronisés.
- Cartouche « État du trafic » : 7 indicateurs par nœud (nœud, débit, mémoire, JVM, pools de threads, file cluster, connexions) et un verdict vert/orange/rouge/gris avec commentaire. Chute de débit : débit des 3 dernières minutes < `drop_ratio_pct` % (20) du 90e centile de référence (calculé sur la dernière heure, non réglable directement ; régler `drop_min_base` et `drop_on_zero`).
- Les connexions ne sont évaluées que s'il y a eu du trafic (sinon on voit seulement les outils d'administration).

## 5. Conteneur `um_admin`

- Lancement : `cd UM && UM_HOST_DIR="$PWD" docker compose -f docker-compose.um_admin.yml up -d --build`. Reconstruire après toute modification de `ui/` (le code est copié dans l'image, pas monté).
- Un seul conteneur : `entrypoint.sh` lance `prometheus` et `python3 /app/ui/server.py` et sort dès que l'un s'arrête. Config initiale écrite dans `/data/settings.json` (source `prometheus`, cibles `/data/targets/um.json`).
- Montages : socket Docker, projet UM au même chemin que sur l'hôte, volumes `um_admin-data` et `um_admin-prom`. Réseau externe `um_default`.
- Le serveur local `python3 ui/server.py` (hôte) et `um_admin` utilisent tous deux le port 8088 : arrêter l'un avant l'autre. Actuellement seul `um_admin` tourne.

## 5bis. Reste éventuel

Voir « Idées non demandées » au §1.
**Non testé au 2026-11-18** : reconstruction depuis une sauvegarde à chaud ; reconstruction et création complètes avec les nouveaux chemins (`PROJECT_DIR`) et la progression par nœud (seule la sauvegarde froide et chaude l'ont exercée, plus une création faite par l'utilisateur : OK, `local_um` créée, 3 nœuds à 100 %) ; sauvegarde à chaud sous trafic client réel ; barres de progression et liste « froid/chaud » à l'écran.
Non vérifié visuellement dans un navigateur : décompte animé du temps réel, boutons de suppression, volets de stores (JS validé par `node --check`, API testées). Pour valider un changement du backend dans `um_admin` : reconstruire l'image, puis `/api/checks` (25 contrôles OK attendus), `/api/status`, `/api/diagnostic/live`, `/api/diagnostic`, et si le code de jobs a changé, `/api/backup` puis `/api/rebuild`.

## 6. Pièges rencontrés (à ne pas refaire)

- **Lancement du serveur :** un processus lancé avec `&` meurt à la fin de la commande. Utiliser `execute_command` avec `background: true` et `exec python3 ui/server.py`, depuis `UM/`. Avant de relancer, `pkill -f ui/server.py`, attendre 2 s et vérifier avec `pgrep -fl ui/server.py` : sinon l'ancien processus tient le port 8088 et le nouveau sort avec le code 1.
- **`apply_diff` sur `index.html`** : les blocs multilignes échouent parfois (« Unable to apply all diff parts ») ; passer par un script Python avec `assert s.count(a)==1` puis `s.replace`, et valider avec `node --check` sur le `<script>` extrait. Le fichier est aussi modifié hors de la session : le relire avant de l'éditer.
- **Tests des suppressions** : n'utiliser que des sauvegardes factices (`20990101-00000x`) ; ne jamais lancer `{"all": true}` sur `/api/backups/delete` hors test jetable (efface les vraies sauvegardes). Remettre les seuils à leur valeur après un test qui les change (`drop_on_zero` notamment).
- **`sed -i` sur macOS** exige un suffixe (`sed -i ''`). Préférer des scripts Python pour les modifications multiples. Une commande chaînée avec `&&` après un `sed` en échec n'exécute pas la suite.
- **`update_todo_list`** refuse la suppression d'éléments terminés : conserver toute la liste précédente telle quelle si on l'utilise.
- **Le skill `um-javascript-api`** n'est pas appelable par `use_skill` (non enregistré) : lire directement `.bob/skills/um-javascript-api/SKILL.md`. Il décrit l'API cliente pub/sub ; les realms ne servent pas la bibliothèque JS en HTTP (404 sur 2001), donc il n'a pas servi de sonde.
- **Les ports UM 2001..2003** répondent en HTTP (`/health/`, `/health/isMaster`, `/health/getClusterState`) : utiles pour une vérification externe.
- **`HealthChecker`** affiche des avertissements sur `wrapper.key` (valeur aléatoire par nœud, bénigne) et sur le cache des stores (info).
- **Dans `um_admin`**, les noms de conteneurs `um1..3` ne se résolvent que sur le réseau `um_default` ; sans cela, la source `http` échoue.
- **Image `um_admin` périmée** : le code est copié, pas monté. Après toute modification de `ui/`, reconstruire (voir la consigne permanente en tête) et comparer `md5 -q ui/<f>` avec `docker exec um_admin md5sum /app/ui/<f>`. `CONTEXTE.md` et `README.md` sont exclus de l'image par `.dockerignore` : pas de reconstruction pour eux.
- **`apply_diff`** : les numéros de ligne glissent après un premier édit dans le même fichier ; en cas d'échec partiel, relire le fichier puis utiliser `search_and_replace` (texte exact sur une ligne).
- **Commandes Docker interrompues** : une commande tuée en cours peut laisser des conteneurs ou réseaux de test (`um_probe`, `umprobe`). Les supprimer ensuite et ne toucher qu'à ses propres conteneurs ; l'utilisateur supprime parfois `um1..3` lui-même pour refaire un test.
- **ViewConnectionFactory** : code retour 0 = présente, 48 = absente (`Name not found`) ; `CreateConnectionFactory` sur un nom existant → rc 48 + `NameAlreadyBoundException`.

## 7. Décisions et réponses déjà données à l'utilisateur

- Sauvegarde « à chaud » : refusée en copie de volume en marche (la doc UM déclare une copie en marche potentiellement corrompue, `guide-backup-recovery.txt`) ; implémentée en **sauvegarde roulante** nœud par nœud. Limites annoncées : 3 nœuds minimum, nœuds pris à des instants différents, écarts d'événements possibles à la restauration (avertissement), reconstruction depuis une sauvegarde à chaud **non testée**.
- Indicateurs de reconstruction : UM n'expose pas de pourcentage de recovery (doc : état *recovery* jusqu'à validation des stores contre le Master) ; le % par nœud est une estimation (conteneur, métriques, événements retrouvés, rôle). Indicateurs natifs utiles : `sag_um_cluster_currentstate` (label `state` : Master/Slave sain, autre = instable), files `sag_um_cluster_{process,client,comms}queue` (> 100 et en hausse = retard), `ServerStatusLog`, `ClusterState`, `HealthChecker`, callbacks `nClusterEventListener` (`stateChange`, `quorumReached`, `quorumLost`).
- Prometheus **serveur** n'est pas embarqué dans UM. L'**exporteur** de métriques fait partie du produit (jars `prometheus-metrics-*` dans `lib/`) ; dans l'image conteneur il est activé par défaut sur le port 9200. Sur une installation classique, il faut mettre `EnableMetricsMonitoring=true` (Monitoring Config).
- L'UI n'a **pas besoin** d'un serveur Prometheus : elle lit directement `/metrics`. Le serveur Prometheus ne sert qu'à l'historique long (l'UI se limite à ~1 h via le `ServerStatusLog`).
- Conversion cluster vers standalone : possible sans perte avec `DeleteCluster -deletestores=false` (stores convertis en locaux) ou via « Modify Cluster Members », mais **pas sans interruption** : la doc demande d'arrêter les publishers, de vider les stores et de prendre un snapshot ; les durables ne sont pas recréés ; les clients doivent changer d'URL. Ce scénario n'a pas été testé et n'a pas de bouton dans l'UI (proposé, non demandé).
- Le diagnostic aide à cerner la cause d'une chute de trafic (flow control, JVM gelée, saturation, file cluster, clients partis, ou cause hors UM) mais ne la détermine pas avec certitude. Limites : historique d'environ 1 h, détection de chute validée seulement sur série simulée (aucun trafic réel sur ces conteneurs), pas de thread dump ni heap dump pris pendant l'incident. Un trafic réel a depuis été observé (≈ 60 évt/s en pointe, 8 minutes actives sur 60) : le 90e centile de référence vient alors de pics courts, d'où `drop_min_base` et `drop_on_zero`.

## 8. Commandes utiles

```bash
# Démarrer / état
cd /Users/julien/.bob/playground/UM && docker compose up -d
curl -s localhost:8088/api/status | python3 -m json.tool | head -30
curl -s localhost:2001/health/getClusterState        # MASTER / SLAVE

# Serveur UI hors conteneur (depuis UM/, background: true ; arrêter um_admin avant, même port 8088)
pkill -f ui/server.py; sleep 2; exec python3 ui/server.py

# Contrôles
python3 -m py_compile ui/settings.py ui/admin.py ui/diagnostic.py ui/server.py
curl -s -m 120 localhost:8088/api/checks | python3 -m json.tool | head -60

# runUMTool dans un nœud
docker exec um1 /opt/webmethods/UniversalMessaging/tools/runner/runUMTool.sh ClusterState -rname=nsp://um1:9000
docker exec um1 /opt/webmethods/UniversalMessaging/tools/runner/runUMTool.sh EditRealmConfiguration \
  -rname=nsp://um1:9000 -listgroupconfiguration=Monitoring_Config
```
