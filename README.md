# LearningSteps Evolution

Cybersteps, Modul 3, Projekt 2. Die LearningSteps-App (FastAPI + PostgreSQL) läuft hier nicht mehr auf manuell gebauten VMs, sondern automatisiert, selbstheilend und überwacht auf Azure.

- **Infrastruktur als Code:** Terraform (19 Ressourcen: VNet, AKS, PostgreSQL Flexible Server, Key Vault, ACR, Identitäten)
- **Container:** Docker, Azure Container Registry
- **Orchestrierung:** Azure Kubernetes Service mit LoadBalancer, ConfigMap und HPA
- **Secrets:** Azure Key Vault + Workload Identity (keine gespeicherten Schlüssel)
- **CI/CD:** GitHub Actions mit OIDC-Login und DevSecOps (Trivy, GitHub Secret Scanning)
- **Monitoring:** Prometheus und Grafana in AKS

Ergebnis: Jeder Push auf `main` wird geprüft, gebaut und automatisch nach AKS ausgerollt. Unsichere Pakete oder Terraform-Regeln stoppen die Pipeline vor dem Push. Die ganze Umgebung wurde per `terraform destroy` und `apply` in rund 28 Minuten neu erzeugt.

## Architektur

```mermaid
flowchart TB
    user[Nutzer im Internet]
    gh[GitHub Actions ci-cd<br/>security, build, deploy<br/>Login per OIDC]

    subgraph azure[Azure: rg-lsevo, swedencentral]
        acr[Container Registry<br/>acrlsevocybersec, Basic]
        kv[Key Vault<br/>kv-lsevo-cybersec]
        id[Pod-Identität<br/>id-lsevo-app]
        subgraph vnet[VNet vnet-lsevo 10.10.0.0/16]
            subgraph aks[snet-aks 10.10.1.0/24, AKS aks-lsevo]
                lb[LoadBalancer<br/>Port 80 → 8000]
                pods[App-Pods<br/>HPA 2 bis 4]
                mon[Prometheus + Grafana<br/>Namespace monitoring]
            end
            subgraph db[snet-db 10.10.2.0/24, delegiert]
                pg[(PostgreSQL 16<br/>nur privat)]
            end
        end
    end

    user -->|HTTP| lb --> pods -->|SQL, SSL| pg
    gh -->|Push, AcrPush| acr
    gh -->|kubectl set image| pods
    acr -->|Pull, AcrPull| pods
    kv -->|database-url| pods
    id -.->|Workload Identity| pods
    mon -->|holt /metrics| pods
```

Nur der LoadBalancer ist öffentlich. Die Datenbank liegt in einem delegierten Subnet ohne öffentlichen Zugang. Prometheus und Grafana sind nur per `kubectl port-forward` erreichbar.

## Repository-Struktur

```
api/                    FastAPI-Code (inkl. /version und /metrics)
infra-terraform/        versions, variables, main (Netz), services, aks, outputs, Lock-Datei
k8s-manifests/          00-namespace bis 40-hpa (App), 50-prometheus, 51-grafana (11 Dateien)
.github/workflows/      ci-cd.yml
docs/images/            Screenshots von Prometheus und Grafana
Dockerfile              python:3.12-slim, läuft als uid 10001
.trivyignore            bewusst akzeptierte Funde mit Begründung
```

## Ressourcen

| Ressource | Name | SKU / Wert |
| --- | --- | --- |
| Resource Group | rg-lsevo | swedencentral |
| VNet | vnet-lsevo | 10.10.0.0/16 |
| Subnets | snet-aks, snet-db | 10.10.1.0/24; 10.10.2.0/24 (an PostgreSQL delegiert) |
| Private DNS-Zone | lsevo.private.postgres.database.azure.com | mit dem VNet verknüpft |
| AKS | aks-lsevo | 1 Node Standard_D2s_v6, Tier Free, Azure CNI Overlay, RBAC, OIDC, Workload Identity |
| Kubernetes-Netze | | Pod-CIDR 10.244.0.0/16, Service-CIDR 10.20.0.0/16, DNS-IP 10.20.0.10 |
| PostgreSQL | psql-lsevo-cybersec | Flexible Server 16, B_Standard_B1ms, 32 GB, nur privat, Datenbank `learning_journal` |
| Key Vault | kv-lsevo-cybersec | Standard, Secrets `db-password`, `database-url` |
| Container Registry | acrlsevocybersec | Basic, Admin-Benutzer aus |
| Pod-Identität | id-lsevo-app | Key Vault nur Get/List, Federated Credential `fic-lsevo-app` |

Region `swedencentral`, weil PostgreSQL Flexible Server in `germanywestcentral` für Azure for Students gesperrt ist.

Kubernetes (Namespace `learningsteps`): Deployment `learningsteps` mit 2 Replicas (Requests 100m / 128Mi, Limits 500m / 256Mi), Service vom Typ LoadBalancer (Port 80 → 8000), ConfigMap `learningsteps-config` (`PGSSLMODE=require`), SecretProviderClass `learningsteps-kv`, HPA (2 bis 4 Pods, Ziel 70 % CPU) und Job `db-schema` für das Datenbankschema.

## CI/CD-Pipeline

Jeder Push startet `.github/workflows/ci-cd.yml`. Die Jobs laufen nacheinander; scheitert einer, werden die folgenden übersprungen.

1. **security:** Trivy prüft Abhängigkeiten, eingecheckte Secrets und IaC (Terraform, Kubernetes, Dockerfile). HIGH oder CRITICAL bricht ab.
2. **build:** ruff (Lint), Docker-Build, Smoke-Test, Trivy-Image-Scan, dann Azure-Login per OIDC und Push in die ACR. Das Image-Tag ist der Commit-Hash.
3. **deploy:** `kubectl set image` und `kubectl rollout status` (Timeout 180 s) auf AKS.

Zusätzlich ist GitHub Secret Scanning mit Push Protection aktiv. Die Pipeline hat nur `AcrPush` auf die ACR und die `Azure Kubernetes Service Cluster User Role` auf AKS. Das Federated Credential `gh-main` erlaubt nur den Branch `main`. Es gibt kein Client-Secret. `terraform apply` läuft bewusst nicht in der Pipeline, weil der State Geheimnisse enthält.

## Nachweise

| Erfolgskriterium | Beleg |
| --- | --- |
| Continuous Deployment | Commit `7b7778d`, Run 45035445934: `GET /version` vorher 404, nachher 200 |
| Security: verwundbares Paket | Run 45035894362 rot: `PyYAML==5.3`, 2 × CRITICAL (CVE-2020-14343, CVE-2020-1747), build und deploy übersprungen |
| Security: unsichere Terraform-Regel | Run 45036098930 rot: 5 Funde (HIGH: 3, CRITICAL: 2), build und deploy übersprungen |
| Grünlauf nach Rücknahme | Run 45036474437 (Commit `0bdb614`): security, build, deploy erfolgreich |
| Selbstheilung | Pod gelöscht, Ersatz nach 3 s gestartet, nach 36 s wieder 2/2 Pods bereit, `GET /entries` 200 |
| Monitoring | Commits `719eff1`, `e3217fc`; Runs 45038117028, 45039056018; Prometheus 2/2 UP |
| Infrastructure Recovery | `terraform destroy` (19 Ressourcen, 7 min 27 s) und `apply` (19 Ressourcen, 8 min 10 s) ohne Fehler; nach Wiedereinrichtung Run 45047939536 grün, alle Endpunkte 200 (gesamt ca. 28 min) |

Die Läufe sind unter *Actions* in diesem Repo einsehbar.

![Prometheus Targets](docs/images/prometheus-targets.png)

![Grafana-Dashboard LearningSteps API](docs/images/grafana-dashboard.png)

Das Dashboard zeigt Requests pro Sekunde nach Pfad, die Latenz p95, die Datenbank-Gesundheit (`db_up`) und die Requests der letzten 5 Minuten nach Status.

## Sicherheitsentscheidungen

- Das DB-Passwort erzeugt Terraform zufällig und legt es im Key Vault ab. Es steht nie im Code.
- Die Pods lesen `database-url` per Workload Identity ohne gespeicherten Schlüssel (nur Get/List).
- Die Pipeline nutzt OIDC statt Client-Secret, mit minimalen Rechten und Bindung an `main`.
- Scans laufen vor dem Push, ein verwundbares Image erreicht die ACR nie.
- Die Pods laufen ohne Root, mit `readOnlyRootFilesystem`, ohne Capabilities und mit gesetzten Requests und Limits.
- Die Datenbank ist nur privat erreichbar, SSL ist erzwungen (`PGSSLMODE=require`).
- Prometheus und Grafana sind nur intern (ClusterIP); das Grafana-Passwort liegt als Zufallswert im Secret `grafana-admin`.
- Der Terraform-State bleibt lokal. `.gitignore` schließt `.env`, `*.tfstate*`, `.terraform/`, `*.tfvars`, `*.tfplan`, `kubeconfig`, `*.pem` und `*.key` aus.

Bewusst akzeptiert (`.trivyignore`, Student-Budget): AKS-API ohne IP-Beschränkung (AZU-0041, wechselnde Runner-IPs), keine Network Policy (AZU-0043, erfordert Neuaufbau), Key Vault ohne Netzwerk-ACL (AZU-0013, Private Endpoint kostet extra).

## Bekannte Grenzen

- Keine Unit-Tests in der Pipeline, nur Lint und Smoke-Test (`test_api.py` aus dem Original-Code ist ein manuelles Skript).
- HPA ist eingerichtet und misst Werte, eine Skalierung unter Last ist nicht belegt.
- `k8s-manifests/20-deployment.yaml` enthält noch das Tag `v1`. Die Pipeline setzt das Image nur im laufenden Cluster.
- Pipeline-Rollen, Client-ID in den Manifesten, Prometheus, Grafana und das Secret `grafana-admin` werden nicht von Terraform bzw. der Pipeline verwaltet.
- `/metrics` ist über den öffentlichen LoadBalancer erreichbar (enthält keine Daten).
- Prometheus speichert in `emptyDir`; nach einem Neustart ist das Dashboard leer.
- Restguthaben im eigenen Konto nicht einsehbar (Abo vermutlich über die Schule).

## Nutzung

```bash
# Infrastruktur (Subscription-ID per Umgebungsvariable)
export ARM_SUBSCRIPTION_ID=<SUBSCRIPTION_ID>
cd infra-terraform && terraform init && terraform apply

# Cluster-Zugriff und öffentliche IP (ändert sich nach jedem Neuaufbau)
az aks get-credentials -g rg-lsevo -n aks-lsevo --overwrite-existing
kubectl get svc learningsteps -n learningsteps

# Grafana lokal öffnen
kubectl port-forward -n monitoring svc/grafana 3000:3000

# Starten nach einer Pause (erst PostgreSQL, dann AKS)
az postgres flexible-server start -g rg-lsevo -n psql-lsevo-cybersec
az aks start -g rg-lsevo -n aks-lsevo

# Kosten sparen in Pausen (erst AKS, dann PostgreSQL)
az aks stop -g rg-lsevo -n aks-lsevo
az postgres flexible-server stop -g rg-lsevo -n psql-lsevo-cybersec
```

## Infrastructure Recovery: Nacharbeiten nach `terraform apply`

Terraform baut die Azure-Ressourcen. Danach sind diese Schritte nötig:

1. `az aks get-credentials` (neuer Cluster)
2. Pipeline-Rollen AcrPush (ACR) und Cluster User Role (AKS) neu vergeben
3. Neue Client-ID von `id-lsevo-app` (`terraform output app_identity_client_id`) in `01-serviceaccount.yaml` und `02-secretproviderclass.yaml` eintragen
4. `kubectl apply -f k8s-manifests/` (inkl. Schema-Job)
5. Secret `grafana-admin` mit Zufallswert anlegen
6. Commit und Push: Die Pipeline baut das Image, pusht es in die neue ACR und deployt es

Der ausführliche Projektbericht wird separat abgegeben.
