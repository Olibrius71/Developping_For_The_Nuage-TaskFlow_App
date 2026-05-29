# RAPPORT PARTIE 5 BONUS

## La step manquante

**La step manquante dans chaque job est la resolution des dependances de chart** : `helm dependency update`.

**Pourquoi** : le chart `monitoring` depend de `kube-prometheus-stack` et le chart `taskflow` depend de `bitnami/redis` (declares dans leurs `Chart.yaml`). Sur un checkout neuf (CI), le dossier `charts/` n'existe pas (il est gitignore). Sans resoudre ces dependances, **toutes** les commandes `helm lint`, `helm template` et `helm upgrade` echouent avec :

```
Error: found in Chart.yaml, but missing in charts/ directory: redis
```

`**update` plutot que `build**` : j'ai d'abord essaye `helm dependency build`, qui echoue avec :

```
Error: no repository definition for https://charts.bitnami.com/bitnami. Please add the missing repos via 'helm repo add'
```

`build` exige un `helm repo add` prealable. `helm dependency update` resout directement les **URLs completes** declarees dans `Chart.yaml` (« unmanaged Helm repositories »), sans `helm repo add`. C'est donc la commande retenue, ajoutee comme step `Update Helm dependencies` dans les 3 jobs (validate, deploy-staging, deploy-production), juste apres `Install Helm`.

---

## Questions theoriques

### 1. `needs: [deploy-staging]` — qu'est-ce que ca garantit ? Pourquoi insuffisant seul ?

`needs: [deploy-staging]` garantit que `deploy-production` **ne demarre que si `deploy-staging` a reussi** : c'est une dependance d'ordre + de succes. Si staging echoue, production ne se lance jamais.

**Insuffisant seul** pour deux raisons :

- Il ne verifie que le **succes technique** du deploiement staging (pods up + smoke test minimal), pas que l'application se comporte correctement fonctionnellement.
- Il **n'ajoute aucune barriere humaine** : sans la protection d'environnement GitHub, la production se deploierait **automatiquement** des que staging passe. La vraie protection vient de l'`environment: production` avec une **regle d'approbation manuelle** (required reviewers). `needs` = enchainement automatique ; l'approbation = controle humain. Les deux sont complementaires.

### 2. `helm upgrade --install` vs `helm install` ? Pourquoi `upgrade --install` en CD ?

- `helm install` **echoue si la release existe deja** (`cannot re-use a name that is still in use`).
- `helm upgrade` **echoue si la release n'existe pas encore**.
- `helm upgrade --install` : **installe si absente, met a jour si presente** — idempotent.

En CD, le pipeline tourne a chaque push. La 1ere fois la release n'existe pas (install), les fois suivantes elle existe (upgrade). `upgrade --install` gere les deux cas **sans connaitre l'etat prealable** ni brancher de condition. C'est le pattern standard pour un deploiement repetable.

### 3. Clusters Kind ephemeres — deux problemes en vrai systeme de prod ? Solutions ?

1. **Ephemere = aucune persistance.** A la fin du job, le cluster est detruit (avec PostgreSQL et l'historique des releases Helm). En prod, l'etat doit survivre entre deux deploiements. → **Solution** : cibler un **cluster manage permanent** (EKS/GKE/AKS) via un `KUBECONFIG` stocke en secret, au lieu de recreer un kind a chaque run.
2. **Pas de realisme / pas d'isolation reelle.** Un kind mono-machine dans un runner 7 Go ne reflete pas la prod : pas de multi-noeuds, pas de vrai stockage reseau, pas de LoadBalancer cloud, ressources tres limitees. Les tests « passent » sans rien garantir sur la vraie infra. → **Solution** : un environnement de staging **iso-prod** provisionne par IaC (Terraform), sur le meme type d'infra que la prod, pour garantir la parite.

(En complement : ici le job « production » deploie sur un kind jetable, pas sur la vraie prod. En vrai, `KUBECONFIG_B64` pointerait vers le cluster de production dedie.)

### 4. Limitation de `--set` pour les secrets ? Alternative plus securisee ?

**Limitation** : `--set postgres.password=$X` fait transiter le secret par la **ligne de commande** (visible dans la liste des process / certains logs), et surtout il finit **stocke en clair** dans l'objet Secret de la release Helm (`helm get values`) et dans les variables d'environnement du pod. GitHub masque la valeur dans les logs si elle vient de `secrets.`*, mais elle existe quand meme en clair dans le cluster.

**Alternatives plus sures dans Kubernetes** :

- **External Secrets Operator** + coffre (Vault, AWS/GCP Secrets Manager) : le secret n'entre jamais dans le pipeline, le cluster le tire directement du coffre.
- **Sealed Secrets** (Bitnami) : on commit un secret **chiffre** dans Git, dechiffre uniquement dans le cluster par le controller.
- **SOPS / helm-secrets** : fichiers de values chiffres (GPG/KMS), dechiffres a la volee au deploiement.
- En complement : **chiffrement d'etcd at-rest** + **RBAC** strict sur les Secrets.

### 5. Pourquoi `values.ci.yaml` desactive Grafana/Alertmanager ? Que se passerait-il avec `values.monitoring.yaml` seul sur un runner 7 Go ?

`values.ci.yaml` desactive **Grafana, Alertmanager, node-exporter** et reduit Prometheus (retention 1h, ressources minimales) parce qu'un runner GitHub standard n'a que ~7 Go de RAM. Le but de la CI est de **valider** que le deploiement fonctionne (pods up + smoke test), pas de faire tourner une stack d'observabilite complete.

Avec `**values.monitoring.yaml` seul** (stack complete) sur un runner 7 Go : Prometheus (512Mi-1Gi) + Grafana (3 conteneurs) + Alertmanager + node-exporter(s) + kube-state-metrics + les ~10 pods de TaskFlow + le control-plane kind **depassent la RAM disponible**. Resultat : des pods restent en `Pending` (ressources insuffisantes) ou se font `OOMKilled`, le `--wait` finit en **timeout**, et le **job echoue**. De plus, l'Alertmanager actif exigerait les secrets SMTP (sinon l'operateur ne reconcilie pas le Secret de config).

Pour les images voir fichier doc_bonus
