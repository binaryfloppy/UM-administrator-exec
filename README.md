# Projet UM — cluster webMethods Universal Messaging 12.1

Trois conteneurs UM (image `ibmwebmethods.azurecr.io/universalmessaging-server:12.1`, linux/amd64, émulée sur Mac arm64), une interface web pour créer le cluster et le reconstruire sans perte.

## Démarrage & Déploiement automatisé

Pour déployer l'intégralité du projet (nœuds UM + conteneur `um_admin` avec IHM et Prometheus) dans un nouvel environnement :

```bash
cd UM
./deploy.sh [deploy.conf]
```

Le fichier de configuration [`deploy.conf`](deploy.conf) permet de personnaliser :
- L'image de l'IHM d'administration (`UM_ADMIN_IMAGE="um_admin:latest"` ou image sur registre)
- L'image UM (`UM_IMAGE="ibmwebmethods.azurecr.io/universalmessaging-server:12.1"`)
- Les ports externes des nœuds UM (`UM1_PORT=2001`, `UM2_PORT=2002`, `UM3_PORT=2003`)
- Le port de l'IHM web (`UM_ADMIN_PORT=8088`) et de Prometheus (`PROMETHEUS_PORT=9090`)
- Le nom du réseau Docker (`DOCKER_NETWORK=um_default`) et le nom du cluster (`CLUSTER_NAME=umcluster`)
- Le mot de passe éventuel (`UM_ADMIN_UM_PASSWORD`)

### Déploiement dans un nouvel environnement sans partager le code source

Un dépôt dédié **[`UM-administrator-exec`](https://github.com/binaryfloppy/UM-administrator-exec)** est disponible pour déployer la solution sans distribuer les sources Python (`ui/`, `um_admin/Dockerfile`) :
- Il contient les fichiers : `docker-compose.yml`, `docker-compose.um_admin.yml`, `deploy.conf`, `deploy.sh`, `scripts/` et l'image Docker pré-packagée `um_admin.tar` (suivie via Git LFS).
- Sur la machine cible, il suffit de cloner le dépôt et d'exécuter :
  ```bash
  ./deploy.sh
  ```
  Le script charge automatiquement l'image `um_admin.tar` si elle n'est pas encore présente dans Docker et démarre l'ensemble des services.

Ou manuellement :
```bash
cd UM
docker compose up -d              # 3 conteneurs um1..um3
python3 ui/server.py              # UI sur http://localhost:8088 (127.0.0.1 uniquement)
```

| Conteneur | Hostname interne | REALM_NAME | Port externe → interne |
|-----------|------------------|------------|------------------------|
| um1 | um1 | umnode1 | 2001 → 9000 |
| um2 | um2 | umnode2 | 2002 → 9000 |
| um3 | um3 | umnode3 | 2003 → 9000 |

Volumes par nœud : `data`, `logs`, `conf` (`/opt/webmethods/common/conf`, contient `users.txt`).

## Point d'attention : `REALM_NAME` ≥ 6 caractères

Le serveur utilise le nom du realm comme mot de passe du keystore cluster (`data/RealmSpecific/server.jks`). Avec `um1`, le démarrage du cluster échoue (`Key password must be at least 6 characters`, puis NPE `KeyStoreManager`). Les realms s'appellent donc `umnode1..3`, alors que conteneurs et hostnames restent `um1..3`.

## Création du cluster

Exécutée depuis `um1` avec l'outil CLI de l'image :

```bash
docker exec um1 /opt/webmethods/UniversalMessaging/tools/runner/runUMTool.sh CreateCluster \
  -clustername=umcluster -convertlocal=true \
  -rnames=nsp://um1:9000,nsp://um2:9000,nsp://um3:9000
```

Résultat attendu : 1 Master + 2 Slave (quorum à 3 nœuds).

## Interface web (`ui/`)

- `settings.py` : paramètres (valeurs par défaut, validation stricte, persistance dans `ui/settings.json`).
- `admin.py` : lecture des métriques (3 sources), `runUMTool`, vérifications d'environnement, `EnableMetricsMonitoring`.
- `diagnostic.py` : collecte et règles de détection de l'onglet Diagnostic.
- `server.py` : serveur HTTP en bibliothèque standard Python, pilote `docker` et `runUMTool.sh`.
- `index.html` : cinq onglets (les cartouches « Etat du trafic » et « Synthese » du Diagnostic se réduisent/agrandissent ; les pastilles de la synthèse filtrent par gravité). **Cluster** (état des nœuds, stores repliés par défaut, version UM affichée, **Créer le cluster**, **Sauvegarder**, **Reconstruire**, sauvegardes supprimables une à une ou toutes, journal), **Monitoring** (détail par queue et topic, replié par défaut, filtre de recherche, métriques et purge), **Diagnostic**, **Scripts** (génération de scripts autonomes avec aide intégrée) et **Administration**.

API :

| Route | Rôle |
|-------|------|
| `GET /api/status` | État des conteneurs, rôle, nombre d'événements par queue/channel |
| `GET /api/monitoring` | Métriques détaillées des queues et topics (éléments, publiés, consommés, en attente, connexions, mémoire, disque, répartition par nœud) |
| `POST /api/purge` | `{"store": "nom"}` ou `{"stores": [...]}` ou `{"all": true, "kind": "queue"|"topic"}` : purge les événements des stores spécifiés via `PurgeEvents` |
| `GET /api/diagnostic` | Diagnostic complet (onglet Diagnostic), 5 à 60 s |
| `GET /api/job` | Avancement/journal de la tâche en cours |
| `GET /api/backups` | Liste des sauvegardes (avec version UM) |
| `GET /api/settings` | Paramètres courants, valeurs par défaut, fichier de configuration |
| `POST /api/settings` | Valide et enregistre les paramètres (400 + message si invalide) |
| `GET /api/checks` | Vérifications d'environnement + état de `EnableMetricsMonitoring` par nœud |
| `POST /api/metrics-monitoring` | `{"node": "um1", "enabled": true}` : active/désactive les métriques du cluster |
| `POST /api/generate-script` | `{"filename": "um_cluster.sh"}` : génère un script Bash autonome dans le répertoire cible configuré |
| `POST /api/create-cluster` | Crée un cluster **vierge**. Si aucun nœud ne tourne, recrée d'abord conteneurs et volumes (`compose down -v` puis `up -d`) ; ne restaure jamais une sauvegarde |
| `POST /api/backup` | Sauvegarde les 3 nœuds. Corps `{"mode": "froid"}` (défaut, service interrompu) ou `{"mode": "chaud"}` (service maintenu, un nœud à la fois) |
| `POST /api/rebuild` | Reconstruit depuis une sauvegarde |
| `POST /api/rebuild-node` | `{"node": "um1"}` : recrée un nœud dont le conteneur est absent, sans toucher aux autres (volumes présents : conteneur seul ; sinon restauration depuis la dernière sauvegarde) |

Le statut s'appuie sur les métriques Prometheus exposées par chaque nœud sur le port 9200 :

- rôle : `sag_um_cluster_currentstate{cluster_name,current_node,state}`
- événements des queues : `sag_um_queue_events{name}`
- événements des channels : `sag_um_topic_noofevents{name}`

## Onglet Monitoring

Surveillance détaillée et gestion des queues et topics (channels) du cluster :
- **Synthèse** : nombre total de queues, topics, événements en file, total publiés et total consommés.
- **Filtre de recherche directe** : recherche textuelle instantanée sur les noms de queues et topics avec compteur visible/total et réinitialisation rapide.
- **Queues (replié par défaut)** : nom, nombre d'éléments en file, consommés, publiés, en attente (`pending`), consommateurs actifs, espace disque, mémoire, répartition des événements par nœud (avec rôle Master/Slave).
- **Topics / Channels (replié par défaut)** : nom, nombre d'éléments, consommés, publiés, consommateurs actifs, espace disque, mémoire, répartition par nœud.
- **Option de purge** : purge individuelle par queue/topic ou purge globale de toutes les queues / tous les topics, avec confirmation pour éviter toute perte accidentelle.

## Onglet Administration

Permet d'utiliser l'IHM hors de l'environnement de référence. Rien n'est codé en dur : sans `settings.json`, les valeurs par défaut reproduisent `um1..um3`.

- **Vérifications** : Docker et plugin compose, fichier compose, répertoire de sauvegarde inscriptible, pour chaque nœud conteneur / `runUMTool` / répertoire du realm / `curl` / métriques lisibles / `EnableMetricsMonitoring`, et Prometheus (prêt, cible `instance="hote:port"` présente et `up`). Chaque anomalie indique une piste de correction. Les pastilles du résumé (critique / alerte / info / OK) sont cliquables et filtrent la liste ; un second clic retire le filtre.
- **`EnableMetricsMonitoring`** : un seul interrupteur pour le cluster. Le réglage (`Monitoring_Config`) est **répliqué sur tous les nœuds** et effectif sans redémarrage ; le désactiver coupe donc les métriques de tout le cluster (confirmation demandée).
- **Paramètres** : nœuds (nom, conteneur, rname, URL des métriques, ajout/retrait), nom du cluster, **connection factory JMS** (défaut `local_um`), image, **réseau Docker des conteneurs** (défaut `um_default`, vérifié et créé/connecté automatiquement à la création et reconstruction), projet / fichier compose, motif des volumes, volumes sauvegardés, répertoire de sauvegarde, **répertoire cible de génération des scripts** (`script_dir`, défaut `scripts/`), chemin de `runUMTool`, répertoire du realm, utilisateur UM, source des métriques, URL de Prometheus, fichier de cibles. **Exporter / Importer** : l'export télécharge la configuration enregistrée en JSON (sans mot de passe UM) ; l'import (fichier exporté ou `settings.json`) remplit le formulaire sans rien appliquer, il faut ensuite cliquer sur Enregistrer, où la validation a lieu. Les valeurs invalides sont refusées avec un message (certaines sont injectées dans un script exécuté dans les conteneurs).

## Onglet Scripts

Permet de générer un script Bash **100 % autonome** pour piloter le cluster UM directement en ligne de commande :
- **Intégration des paramètres** : reprend automatiquement toutes les propriétés d'administration enregistrées (nœuds, rnames, ports, chemins compose et volumes, nom de cluster, connection factory JMS).
- **Aperçu et téléchargement** : visualisable en direct dans l'IHM, copiable dans le presse-papier ou téléchargeable en fichier `.sh` (enregistré avec droits `755` dans le répertoire cible `script_dir`).
- **Commandes embarquées** :
  - `./um_cluster.sh create` : crée un cluster vierge (avec réinitialisation propre des volumes si conteneurs arrêtés).
  - `./um_cluster.sh rebuild [ID]` : reconstruit le cluster depuis une sauvegarde spécifiée en paramètre/variable (ou la plus récente par défaut).
  - `./um_cluster.sh status` : affiche l'état des conteneurs, les rôles Master/Slave et les métriques.
  - `./um_cluster.sh backup [froid|chaud]` : effectue une sauvegarde des volumes.
  - `./um_cluster.sh help` : documentation détaillée et liste des variables d'environnement surchargeables.

Sources de métriques (`metrics_source`) :

| Source | Lecture | Quand l'utiliser |
|--------|---------|------------------|
| `docker` | `docker exec <conteneur> curl http://localhost:<port>/metrics` | par défaut, hors conteneur |
| `http` | GET direct sur l'URL des métriques | l'IHM joint les nœuds en réseau (`um_default`) |
| `prometheus` | API `/api/v1/query` d'un serveur Prometheus | le serveur Prometheus existe déjà ; valeurs en retard d'un intervalle de scrape |

Les opérations qui doivent voir l'état réel (création, attente de formation du cluster, contrôle après reconstruction) lisent toujours les nœuds en direct.

Variables d'environnement : `UM_ADMIN_CONFIG` (chemin du JSON, défaut `ui/settings.json`), `UM_ADMIN_HOST` (défaut `127.0.0.1`), `UM_ADMIN_PORT` (défaut `8088`), `UM_ADMIN_UM_PASSWORD` (mot de passe UM, jamais écrit sur disque).

## Conteneur `um_admin` (IHM + Prometheus)

Un seul conteneur, nommé `um_admin`, qui lance Prometheus (port 9090) puis l'IHM (port 8088) et s'arrête si l'un des deux s'arrête. Il rejoint le réseau `um_default` : le cluster doit donc avoir été démarré au moins une fois.

```bash
cd UM
docker compose up -d                                                    # les 3 nœuds (crée le réseau um_default)
UM_HOST_DIR="$PWD" docker compose -f docker-compose.um_admin.yml up -d --build
# IHM : http://localhost:8088   Prometheus : http://localhost:9090
```

Fichiers : `um_admin/Dockerfile` (Python + binaire `prometheus` + CLI `docker` et plugin compose copiés depuis les images officielles), `um_admin/entrypoint.sh`, `um_admin/prometheus.yml`, `docker-compose.um_admin.yml`, `.dockerignore` (exclut `backups/`).

- Premier démarrage : `entrypoint.sh` écrit `/data/settings.json` avec `metrics_source=prometheus`, `prometheus_url=http://localhost:9090` et un fichier de cibles `/data/targets/um.json`. Chaque enregistrement de l'onglet Administration réécrit ce fichier ; Prometheus le relit toutes les 15 s (`file_sd_configs`). Les cibles portent `instance="hote:port"`, que l'IHM utilise pour retrouver chaque nœud.
- **Socket Docker** (`/var/run/docker.sock`) : indispensable (sauvegarde, reconstruction, diagnostic) mais donne un accès très étendu à l'hôte. À n'utiliser qu'en local. L'IHM n'a pas d'authentification.
- **`UM_HOST_DIR`** : le dossier du projet est monté **au même chemin que sur l'hôte**, car les chemins de `backups/` sont transmis tels quels au démon Docker de l'hôte (`docker run -v`).
- Volumes : `um_admin-data` (configuration et cibles), `um_admin-prom` (données Prometheus, rétention 15 jours). `restart: unless-stopped`.
- Pour repartir de la configuration initiale : `docker exec um_admin rm /data/settings.json && docker restart um_admin`.

## Sauvegarde et reconstruction sans perte

La documentation UM impose d'arrêter les realms pour sauvegarder. Stratégie :

1. Arrêt des 3 conteneurs.
2. Archive `tar` non compressée (l'image n'a pas `gzip`) des volumes `data` et `conf` de chaque nœud, dans `backups/<horodatage>/`, avec un `manifest.json` (nombre d'événements par store, rôle).
3. Redémarrage des nœuds.

**Sauvegarde à chaud** (liste déroulante à côté du bouton) : le service reste disponible. Un nœud à la fois est arrêté proprement, archivé, redémarré, et doit rejoindre le cluster (état Master/Slave) avant de passer au suivant ; le quorum (2 nœuds sur 3) est donc maintenu en permanence. Aucun volume n'est copié en marche : la doc UM déclare qu'une copie de `<DataDir>` pendant que le realm tourne peut être incohérente ou corrompue. Limites : cluster formé de 3 nœuds minimum (sinon refus avant tout arrêt) ; les nœuds sont pris à des instants différents alors que la doc demande de les sauvegarder « dans la même fenêtre de temps », donc les compteurs d'événements peuvent différer d'un nœud à l'autre ; la reconstruction depuis une sauvegarde à chaud signale les écarts en avertissement au lieu d'échouer. Le mode (froid/chaud) est enregistré dans `manifest.json` et affiché dans la liste des sauvegardes.

**Nœud absent** : quand le conteneur d'un nœud a été supprimé, sa carte (onglet Cluster) affiche un bouton « Reconstruire umN ». Seul ce nœud est recréé ; il rejoint le cluster et se resynchronise depuis le Master. Si ses volumes ont aussi disparu, ils sont restaurés depuis la sauvegarde la plus récente.

Reconstruction (5 étapes) : sauvegarde de sécurité de l'état actuel (ou choix d'une sauvegarde existante), `docker compose down -v`, `docker compose up --no-start`, restauration des `tar` dans les volumes, démarrage, attente du cluster, puis comparaison du nombre d'événements avec le manifest (erreur si écart). Les volumes contiennent configuration, ACL, interfaces, certificats, realm/cluster et événements persistés.

**Suppression** : chaque sauvegarde a un bouton « Supprimer », et « Supprimer toutes les sauvegardes » vide `backups/`. Refusé pendant une sauvegarde ou une reconstruction (une reconstruction peut lire la sauvegarde). Définitif.

Tests réalisés : reconstruction depuis l'état courant (51 événements identiques sur les 3 nœuds, Master + 2 Slave), création de cluster depuis zéro, reconstruction depuis une sauvegarde.

## Volumétrie et robustesse

Principe : **le coût d'une collecte ne dépend ni de la taille des logs, ni du nombre de stores, ni du nombre de clients**, et une panne de docker ou un volume lent dégrade l'affichage sans jamais faire tomber le serveur.

| Sujet | Mécanisme |
|-------|-----------|
| Gros logs | seules les `TAIL_BYTES` (8 Mo) de fin de `nirvana.log` sont relues (`tail -c`), jamais le fichier entier. Mesuré : 594 Mo de log, collecte en 0,05 s contre 1,3 s en relecture complète |
| Gros `data` (millions de fichiers) | une seule passe `find` + `awk` (total, nombre, 5 plus gros fichiers, sans tri complet), bornée par `timeout`, **mise en cache 120 s par nœud**. Si elle dépasse le délai, l'écran affiche « mesure trop longue » au lieu d'un faux 0 |
| Beaucoup de stores | l'API et l'écran ne reçoivent que les **200 stores les plus remplis** par nœud (`MAX_STORES`, `SCREEN_STORES`) ; les totaux exacts (`stores_total`, `stores_events`) sont toujours fournis, l'écran dit « … et N autres ». Une règle qui produirait un constat par store est limitée à 15 constats + une ligne de synthèse. Les comparaisons avant/après sauvegarde et reconstruction utilisent **tous** les stores (`status(full=True)`) |
| Plusieurs navigateurs | `Shared` : un seul calcul à la fois, partagé ; résultat réutilisé 2 s ; 20 clients simultanés = 1 calcul. En cas d'échec ou de calcul lent, le dernier bon résultat est renvoyé avec `meta.stale = true` et la raison |
| Rafraîchissement | cadence adaptative côté navigateur : 2 × la durée réelle de collecte (4 s à 60 s), doublée après chaque échec (jusqu'à 60 s), jamais deux collectes en parallèle, 60 s quand l'onglet est masqué. Messages d'état : « Données en retard », « Collecte lente », « Serveur injoignable » |
| Serveur HTTP | corps de requête limité à 1 Mo, JSON non objet refusé, dernier filet `try/except` par requête, `daemon_threads`, erreurs d'écriture vers un navigateur parti ignorées |
| Sauvegarde | **avant d'arrêter quoi que ce soit** : taille des volumes (`du`) et espace libre du dossier de sauvegarde ; refus clair (« Aucun nœud n'a été arrêté ») si `taille × 1,15` ne tient pas. Délai du `tar` proportionnel à la taille (5 min à 6 h). Sauvegarde partielle supprimée et nœuds redémarrés en cas d'échec |
| Reconstruction | **avant tout `down -v`** : espace Docker disponible ≥ taille des archives × 1,15, sinon refus (« Rien n'a été supprimé »). Délais de restauration et de reformation du cluster proportionnels aux données. Écarts affichés : 30 lignes + « … et N autres » |
| Journal des jobs | borné à 600 lignes (début et fin conservés) |
| Liste des sauvegardes | résumé (nombre de stores, événements, octets) ; le détail des stores reste dans `manifest.json` |

**Non validé sur de gros volumes** : tout ce qui précède est testé par simulation (20 000 stores, 594 Mo de log, 20 000 fichiers dans `data`, 20 navigateurs, disque plein simulé, `tar` en échec), pas sur plusieurs dizaines de Go de données réelles. Les délais sont dimensionnés sur un débit minimal supposé de 5 Mo/s (`MIN_IO_RATE`) : à vérifier sur la vraie infrastructure. La sauvegarde reste **à froid** (nœuds arrêtés pendant toute la copie) : sur de très gros volumes, l'indisponibilité dure autant que le `tar`. Les valeurs de Prometheus (source par défaut de l'onglet Cluster) ont jusqu'à 15 s de retard après un redémarrage.

## Onglet Diagnostic (UM seul, sans Integration Server)

Prévu pour analyser un cluster en panne ou ce qu'il en reste : fonctionne **nœuds arrêtés** (logs et `data` relus depuis les volumes en lecture seule). Le rapport est téléchargeable en JSON. Rien n'est mis en cache : chaque analyse relit les nœuds à cet instant. Deux modes :

| Mode | Contenu | Durée | Historique |
|------|---------|-------|------------|
| **Temps réel** (ouvert par défaut) | état du trafic + détail par nœud, rafraîchi toutes les 4 s avec un décompte animé ; sans synthèse ni `ClusterState`/`HealthChecker` | ≈ 1 s | jamais enregistré |
| **Snapshot** | diagnostic complet (synthèse, `ClusterState`, `HealthChecker`) | ≈ 8 s | enregistré ; met le temps réel en pause |

Le temps réel est allégé parce que `ClusterState`/`HealthChecker` (via `runUMTool`) coûtent à eux seuls ≈ 7 s. Il se met en pause quand l'onglet est masqué.

**Historique** : chaque diagnostic est enregistré dans `diagnostics/<AAAAMMJJ-HHMMSS>.json` (à côté de `settings.json`, donc dans le volume `/data` du conteneur `um_admin`). La liste en haut de l'onglet permet de rouvrir un ancien diagnostic, affiché avec le bandeau « ARCHIVE » (données de l'époque, pas l'état actuel). Seuls les N plus récents sont gardés (seuil `history_keep`, 50 par défaut).

**Seuils d'alerte** : réglables dans Administration > « Seuils d'alerte du diagnostic » (clé `thresholds` de `settings.json`) :

| Clé | Défaut | Effet |
|-----|--------|-------|
| `drop_ratio_pct` | 20 | chute de débit si débit récent < X % du débit de référence ; 0 désactive l'alerte |
| `drop_min_base` | 0,2 | débit de référence minimal (evt/s) pour juger une chute |
| `drop_on_zero` | 1 | 0 = ne pas alerter quand le débit ou les connexions tombent à 0 (fin de test normale) |
| `queued_warn` | 1 | alerte si la moyenne de tâches en file des 3 dernières minutes ≥ X ; 0 désactive |
| `cpu_warn_pct` | 85 | alerte CPU JVM au-dessus de X % |
| `history_keep` | 50 | nombre de diagnostics conservés |

Sources collectées par nœud : `docker inspect` (code de sortie, OOMKilled, redémarrages, limite mémoire), métriques Prometheus 9200, `/health`, `nirvana.log` (le `ServerStatusLog`, toutes les 5 s, donne l'historique du débit publié/consommé, mémoire libre, CPU, tâches en file, connexions, file cluster), `UMRealmService.log` (wrapper Tanuki), `Server_Common.conf`, heap dumps, plus gros fichiers, latence HTTP vers les pairs, et pour le cluster `ClusterState` et `HealthChecker`.

Règles principales (issues de la doc UM 12.1 : *Troubleshooting*, *Out-of-memory protection*, *Cluster quorum*, *Running a configuration health check*) :

| Symptôme | Détection |
|----------|-----------|
| Chute brutale de la vitesse de consommation/publication | débit des 3 dernières minutes < `drop_ratio_pct` % (20 par défaut) du débit de référence (90e centile) ; la fiche affiche l'évolution mémoire, CPU, tâches en file, connexions avant → après |
| Cluster qui ne se reforme pas | quorum (51 %, donc 2 nœuds sur 3), absence de Master, plusieurs Masters, état `Offline`, « Waiting for cluster to achieve quorum », pair injoignable ou lent |
| JVM gelée / trop lente | trous dans le `ServerStatusLog`, log qui ne progresse plus, temps de GC, `Pinging the JVM took`, SIGKILL, `Timed out waiting for signal` |
| Mémoire | heap/direct/événements vs seuils de flow control (70/80/90/94 %), `OutOfMemoryError`, heap dumps, heap+direct > 80 % de la RAM disponible, heap/direct différents entre nœuds |
| Ressources | disque, descripteurs de fichiers, deadlocks, pools de threads bloqués |
| Cluster | stores désynchronisés entre nœuds, recovery en boucle (`.mem` corrompu), keep-alive coupé, `HealthChecker` |

### Cartouche « Etat du trafic »

En haut de l'onglet, un cartouche coloré donne le verdict global et un commentaire en clair, puis une carte par nœud avec 7 indicateurs (pastille verte/orange/rouge/grise) :

| Indicateur | Rouge / orange quand | Cause évoquée dans le commentaire |
|------------|----------------------|-----------------------------------|
| Noeud | conteneur arrêté, état cluster ≠ Master/Slave | nœud hors cluster |
| Débit | chute < 20 % du débit de référence (rouge), publié sans aucune consommation (orange) | si aucune jauge UM n'a varié : cause hors UM (consommateurs lents, acquittements, réseau) |
| Mémoire / flow control | événements ≥ 70 % du heap (orange), ≥ 90 % (rouge) | producteurs ralentis par le flow control |
| JVM | trous de log récents (< 3 min), log figé, SIGKILL / timeout récent du wrapper | GC, swap, famine CPU ; keep-alive cluster qui échouent |
| Pools de threads | tâches bloquées (rouge) ou saturation instantanée / moyenne de tâches en attente ≥ `queued_warn` (orange) | saturation interne |
| File cluster | non vide (orange), croissante (rouge) | le nœud ne suit plus les messages cluster |
| Connexions clients | valeur instantanée ; chute à 0 (rouge, sauf `drop_on_zero` = 0), division par 2 (orange) | clients déconnectés |

Couleurs : vert = trafic sain ; orange = à surveiller ; rouge = problème ; gris = aucun trafic à juger (pas de chute détectable). Le verdict global passe en rouge si le quorum est perdu. Les connexions ne sont évaluées que s'il y a eu du trafic (sinon on ne verrait que les outils d'administration). Les seuils sont ceux de la doc UM (flow control 70/80/90/94 %).

Limites : l'historique va jusqu'à 1 h (720 échantillons) ; les trous causés par un arrêt/redémarrage propre du realm sont ignorés ; sans trafic réel, la détection de chute de débit n'a été validée que sur une série synthétique ; les consommateurs lents (« Consumer Warning ») ne sont visibles que si le log est au niveau Warning ou plus.

## Limites

- Les 3 nœuds sont arrêtés pendant la sauvegarde (interruption de service).
- Les `logs` ne sont pas sauvegardés.
- Pas de suppression du cluster ni de purge des sauvegardes dans l'UI.
- Le contrôle d'intégrité se fait uniquement par nombre d'événements.
- `backups/` contient clés et certificats : ne pas versionner (ajouter au `.gitignore`).
- L'UI n'a aucune authentification : hors conteneur elle n'écoute que sur 127.0.0.1. Dans `um_admin` elle écoute sur 0.0.0.0 et les ports 8088/9090 sont publiés sur toutes les interfaces de l'hôte : restreindre (`127.0.0.1:8088:8088`) hors poste local.

## Arborescence

```
UM/
├── docker-compose.yml
├── README.md
├── docker-compose.um_admin.yml
├── .dockerignore
├── um_admin/               # Dockerfile, entrypoint.sh, prometheus.yml
├── ui/
│   ├── server.py
│   ├── settings.py
│   ├── admin.py
│   ├── diagnostic.py
│   ├── script_gen.py
│   └── index.html
├── scripts/                # Répertoire cible des scripts générés (configurable)
│   └── um_cluster.sh
└── backups/<horodatage>/   # *.tar + manifest.json
```

Un skill Bob sur l'API JavaScript d'UM est disponible dans `.bob/skills/um-javascript-api/SKILL.md`.
