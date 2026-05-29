# TP PARTIE 5 BONUS — CI/CD Helm : Staging & Production

## Objectif

Mettre en place un pipeline de déploiement continu qui :
1. Valide les charts Helm (lint + rendu)
2. Déploie automatiquement les stacks **monitoring** et **taskflow** en **staging**
3. Déploie en **production** après une **approbation manuelle**

Le cluster utilisé est un cluster **Kind** éphémère créé dans GitHub Actions. En staging le déploiement est entièrement automatique et vérifié par un smoke test. La production est identique mais bloquée par une protection d'environnement GitHub.

---

## Architecture du pipeline

```
Push sur main
     │
     ▼
[CI — Build & Push]          (.github/workflows/ci-cd.yml)
 Build + push images Docker
     │
     │  workflow_run (conclusion == success)
     ▼
[CD — Deploy Helm Stack]     (.github/workflows/deploy.yml)
     │
     ├── [validate]
     │     helm lint monitoring + taskflow (staging + prod)
     │     helm template (rendu des 3 variantes)
     │
     ├── [deploy-staging]   (environment: staging — automatique)
     │     Kind cluster "staging"
     │     helm install monitoring  (values.monitoring.yaml + values.ci.yaml)
     │     helm install taskflow    (values.yaml + values.staging.yaml)
     │     Smoke test : kubectl wait + curl /health
     │
     └── [deploy-production]  (environment: production — APPROBATION MANUELLE)
           Kind cluster "production"
           helm install monitoring  (values.monitoring.yaml + values.ci.yaml)
           helm install taskflow    (values.yaml + values.production.yaml)
           Smoke test : kubectl wait + curl /health
```

> **Note** : Les deux clusters Kind sont éphémères et indépendants. Ils simulent deux environnements isolés. Dans un vrai contexte cloud, `KUBECONFIG_B64` pointerait vers des clusters dédiés (voir questions théoriques).

---

## Mise en place

### Étape 1. Configurer les GitHub Secrets

Analysez le fichier `.github/workflows/deploy.yml` et identifiez tous les secrets référencés via `${{ secrets.* }}`.

Créez-les dans **Settings → Secrets and variables → Actions** de votre dépôt.

> Les secrets SMTP sont optionnels en CI car l'alertmanager est désactivé dans `values.ci.yaml`. Ils seraient injectés dans un vrai cluster production. 

### Étape 2. Créer les GitHub Environments

Le workflow référence deux environnements (`staging` et `production`). Configurez-les dans les paramètres de votre dépôt GitHub de façon à ce que :
- `staging` se déploie automatiquement
- `production` nécessite une approbation manuelle avant de démarrer

> **Doc** : [Using environments for deployment](https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment)


### Étape 3. Compléter le workflow

#### Condition d'exécution du job `validate`

Le job `validate` se déclenche sur deux événements : un `workflow_run` (déclenché par la CI) et un `workflow_dispatch` (déclenchement manuel). Sans condition explicite, le job s'exécuterait aussi quand la CI **échoue**, ce qui est inutile.

Au niveau du job (pas d'un step) ajouter la condition pour qu'il ne s'exécute que dans deux cas :
- le workflow est déclenché manuellement
- **ou** le `workflow_run` qui l'a déclenché s'est terminé avec succès

> Consultez les [contextes GitHub Actions](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/accessing-contextual-information-about-workflow-runs) — les variables `github.event_name` et `github.event.workflow_run.conclusion` sont utiles ici.

#### Lint steps

Complétez les trois commandes `helm lint` dans le job `validate`. Chaque commande doit cibler le bon répertoire de chart et spécifier le `--namespace` correspondant.

- **monitoring** : passez le fichier de valeurs du namespace monitoring. Incluez `values.ci.yaml` pour désactiver les composants lourds (Grafana, Alertmanager) 
- **taskflow (staging)** : passez les fichiers de valeurs nécessaires à cet environnement.
- **taskflow (production)** : passez les fichiers de valeurs nécessaires à cet environnement. Le chart exige que `postgres.password` soit défini — utilisez l'option `--set` (Attention : Un secret réel ne doit jamais apparaître dans un job de validation).

#### Template steps

Complétez les trois commandes dans le job `validate`. 
Utilisez la commande qui effectue un rendu des manifestes Kubernetes (un dry-run côté client).

Chaque commande suit la même structure que le lint, avec deux différences importantes :

- Le **nom de release** est requis.
- Pour les charts taskflow, il faudra injectez le tag d'image dynamique via `--set`.

Les fichiers de valeurs et namespaces à utiliser sont identiques aux lint steps correspondants. Pour la production, appliquez la même stratégie que pour le lint concernant `postgres.password`.

#### Deploy steps — staging

Complétez les deux commandes de déploiement dans le job `deploy-staging`. La commande à utiliser  installe le chart s'il n'existe pas encore, ou met à jour le release existant.

- **monitoring** : déployez le chart monitoring dans son namespace `monitoring`. Passez les mêmes fichiers de valeurs que dans le job `validate`. Ajoutez l'option qui permet de créer le namespace s'il n'existe pas, ainsi que `--timeout 10m` et `--wait` pour attendre que les pods soient prêts.
- **taskflow (staging)** : déployez le chart taskflow dans le namespace `staging`. Passez les fichiers de valeurs staging et injectez le tag d'image dynamique. Ajoutez `--timeout 5m` et `--wait`.

> Le namespace `staging` est créé par le step `Prepare staging namespace` juste au-dessus — pas besoin de créer le namespace pour taskflow.

#### Deploy steps — production

Complétez les deux commandes de déploiement dans le job `deploy-production`. La structure est identique au staging, avec deux différences :

- **monitoring (production)** : en production, l'Alertmanager est actif et nécessite une configuration SMTP. Injectez les cinq secrets SMTP via `--set` en respectant les normes de sécurité. La clé de configuration à cibler est `alertmanagerConfig.smtp.*`.

#### Step manquante

Il manque un `step` dans chaque job. 

Indentifiez la dans votre `REPORT.md` puis corrigez le workflow.

### Étape 4. Pousser sur main

```bash
git add .
git commit -m "feat: add CD pipeline for staging and production"
git push origin main
```

L'enchaînement se déclenche automatiquement :
1. `CI — Build & Push` construit et publie les images
2. `CD — Deploy Helm Stack` se déclenche via `workflow_run`
3. `validate` valide les charts
4. `deploy-staging` crée le cluster Kind et déploie
5. `deploy-production` attend votre approbation dans GitHub Actions

## Collecter les preuves

Dans votre `REPORT.md`, montrer :

- Le workflow `CD — Deploy Helm Stack` avec l'état de chaque job
- La demande d'approbation avant le déploiement production
- Le **log du smoke test** de staging (sortie de `curl /health` visible dans les logs GitHub Actions)

## Questions théoriques

> Répondre dans votre `REPORT.md`.
>
> 1. Le job `deploy-production` utilise `needs: [deploy-staging]`. Qu'est-ce que cela garantit ? Pourquoi est-ce insuffisant seul pour protéger la production ?
>
> 2. Expliquez la différence entre `helm upgrade --install` et `helm install`. Pourquoi utilise-t-on `upgrade --install` en CD ?
>
> 3. Dans ce pipeline, staging et production utilisent des clusters Kind éphémères créés dans le runner GitHub. Quels sont les **deux problèmes concrets** que cela poserait dans un vrai système de production ? Comment les résoudre ?
>
> 4. Le workflow utilise `${{ secrets.POSTGRES_PASSWORD_PROD }}` injecté via `--set`. Citez une limitation de `--set` pour les secrets et proposez une alternative plus sécurisée dans Kubernetes.
> 
> 5. Pourquoi `values.ci.yaml` désactive-t-il Grafana et l'Alertmanager ? Que se passerait-il si on utilisait `values.monitoring.yaml` seul en CI sur un runner GitHub Actions standard (7 Go RAM) ?

---

## Livrable

- `deploy.yml` présent, complet et le pipeline s'exécute sans erreur sur la branche `main`
- Le job `deploy-staging` passe (Kind cluster + smoke test vert)
- Le job `deploy-production` est bloqué par l'approbation manuelle
- Après approbation, `deploy-production` passe
- `REPORT.md` avec captures + log smoke test etc ...
- Aucun secret commité en clair dans le dépôt
