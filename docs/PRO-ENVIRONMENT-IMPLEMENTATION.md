# Implementazione Ambiente PRO (Produzione) — AuxDromos

**Data**: 2026-03-21
**Autore**: Claude Code (analisi automatizzata)
**Stato**: Proposta
**Branch di riferimento**: `pro`

---

## 1. Contesto e Obiettivo

AuxDromos e PagoDesk sono piattaforme per la gestione di dati catastali e calcolo tributi per enti locali italiani, con integrazione PagoPA per i pagamenti. Attualmente l'unico ambiente operativo e' **SIT** (System Integration Testing), deployato automaticamente dal branch `main`.

L'obiettivo di questo documento e' definire tutto il necessario per creare un **ambiente di produzione (PRO)**, triggerato dal branch `pro` su GitHub, con infrastruttura AWS in **eu-central-1 (Francoforte)** per conformita' GDPR.

---

## 2. Stato Attuale vs Target

| Componente | SIT (attuale) | PRO (target) |
|---|---|---|
| Branch trigger | `main` | `pro` |
| AWS Region | us-east-1 | **eu-central-1 (Francoforte)** |
| EC2 | us-east-1 (t3.micro/small) | eu-central-1 (t3.large o superiore) |
| RDS PostgreSQL | eu-central-1 | eu-central-1 (nuova istanza, Multi-AZ) |
| ECR | us-east-1 | eu-central-1 |
| S3 Artifacts | us-east-1 | eu-central-1 |
| SSM Parameters | `/auxdromos/sit/*` | `/auxdromos/pro/*` |
| Maven Profile | `-Psit` | `-Ppro` |
| Spring Profile | `sit` | `pro` |
| Docker Compose | `aws/sit/docker/` | `aws/pro/docker/` |
| Deploy Script | `aws/sit/script/` | `aws/pro/script/` |
| Config Server label | branch `main` | branch `pro` (o tag dedicato) |

### Ambienti attuali nel repository

```
aws/
├── local/          # Sviluppo locale
└── sit/            # System Integration Testing
    ├── docker/     # docker-compose.yml + override
    ├── script/     # deploy_module.sh
    └── setup/      # .env, keycloak-setup.sh
```

**Non esiste** ancora la directory `aws/pro/`.

---

## 3. Strategia di Branch

### Flusso di promozione del codice

```
feature/** ──> develop ──> main (SIT auto-deploy) ──> pro (PRO deploy con approval)
```

- Il codice entra in `main` dopo PR review e merge da `develop`
- Il branch `pro` viene aggiornato **esclusivamente tramite merge da `main`**
- Il deploy in PRO avviene solo dopo che il codice e' stato validato in SIT
- Mai merge diretto da `develop` o `feature/**` verso `pro`

### Branch Protection Rules per `pro`

Configurare su GitHub Settings > Branches > Add rule per `pro`:

| Regola | Valore |
|---|---|
| Require pull request reviews | Si (minimo 1 approvazione) |
| Require status checks to pass | Si (build + test) |
| Require branches to be up to date | Si |
| Restrict who can push | Solo maintainer/admin |
| Allow force pushes | **No** |
| Allow deletions | **No** |

---

## 4. Infrastruttura AWS (eu-central-1)

### 4.1. Risorse da creare

#### Networking

| Risorsa | Specifiche |
|---|---|
| VPC | CIDR dedicato (es. 10.1.0.0/16), separato da SIT |
| Subnet pubbliche | 2 AZ (eu-central-1a, eu-central-1b) per ALB |
| Subnet private | 2 AZ per EC2 e RDS |
| NAT Gateway | Per accesso internet dalle subnet private |
| Internet Gateway | Per le subnet pubbliche |

#### Compute

| Risorsa | Specifiche |
|---|---|
| EC2 | t3.large (2 vCPU, 8 GB RAM) minimo, Amazon Linux 2023 |
| EC2 Software | Docker, Docker Compose v2, AWS CLI v2, jq |
| Security Group EC2 | Ingresso: porta 8080 solo da ALB; SSH solo da IP gestione |
| Key Pair | Nuova coppia di chiavi dedicata PRO |

#### Database

| Risorsa | Specifiche |
|---|---|
| RDS PostgreSQL | Versione 17.x, db.r6g.large o superiore |
| Multi-AZ | **Si** (alta disponibilita') |
| Storage | gp3, encrypted (AWS KMS) |
| Backup | Automatico, retention 30 giorni |
| Maintenance Window | Domenica 03:00-04:00 CET |
| Security Group RDS | Ingresso: porta 5432 solo da SG dell'EC2 |

#### Container Registry

| Risorsa | Specifiche |
|---|---|
| ECR Repositories | Uno per modulo, in eu-central-1 |

Repository da creare:
- `auxdromos-config`
- `auxdromos-rdbms`
- `auxdromos-idp`
- `auxdromos-backend`
- `auxdromos-gateway`
- `auxdromos-print-service`
- `auxdromos-admin-dashboard`

> **Nota**: E' possibile utilizzare la **cross-region replication** di ECR per replicare le immagini da us-east-1 a eu-central-1, evitando di rebuildarle. In alternativa, il workflow puo' pushare direttamente in eu-central-1.

#### Storage S3

| Bucket | Scopo | Region |
|---|---|---|
| `auxdromos-artifacts-pro` | Artifacts CI/CD (JAR, ZIP, build-info) | eu-central-1 |
| `auxdromos-print-pro` | Output PDF del print-service | eu-central-1 |
| `pagopa-notices-pdf-pro` | Avvisi di pagamento PagoPA | eu-central-1 |
| `auxdromos-pagopa-bulk-uploads-pro` | Upload massivi PagoPA | eu-central-1 |
| `auxdromos-print-jobs-pro` | Job di stampa > 1MB | eu-central-1 |

Tutti i bucket devono avere:
- Server-side encryption (SSE-KMS)
- Versioning abilitato
- Lifecycle policy per pulizia artifacts vecchi
- Block public access

#### Load Balancer

| Risorsa | Specifiche |
|---|---|
| ALB | Application Load Balancer in subnet pubbliche |
| Target Group | EC2 PRO, porta 8080, health check su `/actuator/health` |
| Listener HTTPS | Porta 443, certificato ACM |
| Listener HTTP | Porta 80, redirect a HTTPS |
| ACM Certificate | Per il dominio di produzione (es. `api.auxdromos.it`) |

#### WAF (Web Application Firewall)

| Regola | Scopo |
|---|---|
| AWS Managed Core Rule Set | Protezione OWASP Top 10 |
| SQL Injection Rule Set | Protezione SQL injection |
| Rate Limiting | Max 2000 req/5min per IP |
| IP Reputation List | Blocco IP malevoli noti |

#### IAM

| Risorsa | Specifiche |
|---|---|
| OIDC Provider | `token.actions.githubusercontent.com` (gia' esistente) |
| IAM Role | `GitHubActions-AuxDromos-DeployRole-PRO` |

Trust Policy per il nuovo role (scoped al branch `pro`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::463470955561:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:Auxdromos/*:ref:refs/heads/pro"
        }
      }
    }
  ]
}
```

Permissions policy: ECR (push/pull), S3 (read/write su bucket PRO), SSM (read), EC2 (describe), CloudWatch (put metrics/logs).

#### Monitoring

| Risorsa | Specifiche |
|---|---|
| CloudWatch Log Groups | `/auxdromos/pro/{service}` per ogni servizio |
| CloudWatch Alarms | CPU > 80%, Memory > 85%, Disk > 90%, Health check failure |
| SNS Topic | `auxdromos-pro-alerts` per notifiche |
| Slack Integration | Canale dedicato `#auxdromos-pro-alerts` |

---

### 4.2. SSM Parameter Store — Parametri da creare

#### Path: `/auxdromos/pro/global`

| Parametro | Tipo | Descrizione |
|---|---|---|
| `AWS_ACCOUNT_ID` | String | ID account AWS |
| `AWS_DEFAULT_REGION` | String | `eu-central-1` |
| `ENV_NAME` | String | `pro` |
| `DB_URL` | SecureString | JDBC URL del database PRO |
| `DB_USERNAME` | SecureString | Username database PRO |
| `DB_PASSWORD` | SecureString | Password database PRO |
| `SLACK_WEBHOOK_URL` | SecureString | Webhook Slack per notifiche PRO |
| `PAGOPA_RECEIPTS_SUBSCRIPTION_KEY` | SecureString | Chiave PagoPA Receipts (produzione) |
| `PAGOPA_GDP_SUBSCRIPTION_KEY` | SecureString | Chiave PagoPA GDP (produzione) |
| `PAGOPA_PRINT_SUBSCRIPTION_KEY` | SecureString | Chiave PagoPA Print (produzione) |
| `PAGOPA_FDR_SUBSCRIPTION_KEY` | SecureString | Chiave PagoPA FDR (produzione) |
| `PAGOPA_HMAC_SECRET` | SecureString | HMAC secret PagoPA (produzione) |
| `PAGOPA_RECEIPT_HMAC_SECRET_KEY` | SecureString | HMAC receipt key (produzione) |
| `COGNITO_CLIENT_SECRET` | SecureString | Cognito client secret PRO |
| `SPRING_CLOUD_CONFIG_SERVER_GIT_URI` | String | URI repo configurazione |
| `SPRING_CLOUD_CONFIG_SERVER_GIT_USERNAME` | SecureString | Username Git config |
| `SPRING_CLOUD_CONFIG_SERVER_GIT_PASSWORD` | SecureString | Password/token Git config |
| `SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL` | String | `pro` |
| `SPRING_CLOUD_CONFIG_SERVER_GIT_SEARCH_PATHS` | String | Path di ricerca config |

#### Path: `/auxdromos/pro/script`

| Parametro | Tipo | Descrizione |
|---|---|---|
| `MODULE_ORDER` | String | `config rdbms idp backend gateway print-service admin-dashboard` |

#### Path: `/github/pro`

| Parametro | Tipo | Descrizione |
|---|---|---|
| `ec2_user` | String | Username SSH per EC2 PRO |
| `ec2_host` | String | IP/hostname EC2 PRO |
| `ec2_private_key` | SecureString | Chiave privata SSH per EC2 PRO |

#### Path: `/github/common` (aggiornamento)

| Parametro | Tipo | Descrizione |
|---|---|---|
| `s3_bucket_name_pro` | String | Nome bucket S3 artifacts PRO |

---

## 5. Modifiche al Repository auxdromos-distro

### 5.1. Struttura directory da creare

```
aws/pro/
├── docker/
│   ├── docker-compose.yml
│   └── docker-compose.override.yml
├── script/
│   └── deploy_module.sh
└── setup/
    └── README.md       # Istruzioni setup iniziale (NO secrets nel repo!)
```

### 5.2. Workflow GitHub Actions

#### `.github/workflows/main.yml` — Modifiche

```yaml
name: DISTRO CI/CD

on:
  push:
    branches:
      - main
      - pro              # AGGIUNTA
      - develop
      - 'feature/**'
  pull_request:
    branches:
      - main
      - pro              # AGGIUNTA
      - develop

jobs:
  call-reusable-pipeline:
    name: Run Shared AuxDromos CI/CD
    uses: ./.github/workflows/reusable-ci-template.yml
    permissions:
      id-token: write
      contents: read
      actions: write
    with:
      java-version: '17'
      artifact-retention-days: 7
      # Profilo Maven dinamico in base al branch
      maven-profiles: ${{ github.ref_name == 'pro' && '-Ppro' || '-Psit' }}
    secrets:
      GITHUB_PACKAGES_TOKEN: ${{ secrets.GH_PACKAGES_TOKEN }}
```

#### `.github/workflows/reusable-ci-template.yml` — Modifiche

Le modifiche al template riutilizzabile sono le piu' significative. Di seguito le sezioni da modificare:

**a) Variabile regione dinamica (riga 38)**

```yaml
# DA:
env:
  AWS_REGION: us-east-1

# A:
env:
  AWS_REGION: us-east-1  # Default, override nei job PRO
```

Ogni job che interagisce con AWS deve usare la regione appropriata. Aggiungere un job di setup o usare espressioni condizionali:

```yaml
env:
  AWS_REGION: ${{ github.ref_name == 'pro' && 'eu-central-1' || 'us-east-1' }}
```

**b) Condizioni di esecuzione dei job (tutte le occorrenze)**

```yaml
# DA (ogni job con condizione branch):
if: github.event_name == 'push' && github.ref_name == 'main'

# A:
if: github.event_name == 'push' && (github.ref_name == 'main' || github.ref_name == 'pro')
```

Job interessati: `check_version`, `package_configs`, `build_docker`, `upload_to_s3`, `tag_latest`.

**c) IAM Role dinamico (ogni step `configure-aws-credentials`)**

```yaml
# DA:
role-to-assume: arn:aws:iam::463470955561:role/GitHubActions-AuxDromos-DeployRole

# A:
role-to-assume: ${{ github.ref_name == 'pro'
  && 'arn:aws:iam::463470955561:role/GitHubActions-AuxDromos-DeployRole-PRO'
  || 'arn:aws:iam::463470955561:role/GitHubActions-AuxDromos-DeployRole' }}
```

**d) Nuovo job `deploy_pro` (dopo `deploy_sit`)**

```yaml
deploy_pro:
  name: Deploy to PRO Environment
  runs-on: ubuntu-latest
  needs: [extract_module_info, upload_to_s3, build_docker]
  if: github.event_name == 'push' && github.ref_name == 'pro'
  environment:
    name: production
    # Richiede approvazione manuale su GitHub
  env:
    MODULE_NAME: ${{ needs.extract_module_info.outputs.module_name }}
    VERSION: ${{ needs.extract_module_info.outputs.version }}
    SSM_EC2_USER_PARAM: '/github/pro/ec2_user'
    SSM_EC2_HOST_PARAM: '/github/pro/ec2_host'
    SSM_EC2_KEY_PARAM: '/github/pro/ec2_private_key'
    SSM_S3_BUCKET_PARAM: '/github/common/s3_bucket_name_pro'
  permissions:
    id-token: write
    contents: read
  steps:
    # Stessa logica di deploy_sit ma con:
    # - Parametri SSM /github/pro/*
    # - Script path: /app/distro/artifacts/aws/pro/script/deploy_module.sh
    # - environment: production (richiede approval)
    # ...
```

> **Importante**: il campo `environment: production` abilita l'**approval gate** di GitHub. Configurare su Settings > Environments > New environment "production" con required reviewers.

**e) Slack notification — parametro SSM dinamico**

```yaml
SSM_SLACK_WEBHOOK_PARAM: ${{ github.ref_name == 'pro'
  && '/auxdromos/pro/global/slack_webhook_url'
  || '/auxdromos/sit/global/slack_webhook_url' }}
```

**f) Upload S3 — supporto branch `pro`**

```yaml
# Nel job upload_to_s3, modificare la condizione:
if: (github.ref_name == 'main' || github.ref_name == 'pro') && github.event_name == 'push'

# E nel path S3:
if [[ "${{ github.ref_name }}" == "main" || "${{ github.ref_name }}" == "pro" ]]; then
  S3_PATH="${MODULE_NAME}/${VERSION}/"
fi
```

### 5.3. Docker Compose PRO

#### `aws/pro/docker/docker-compose.yml`

Identico a `aws/sit/docker/docker-compose.yml` con queste differenze:

| Parametro | SIT | PRO |
|---|---|---|
| `SPRING_PROFILES_ACTIVE` | `sit` | `pro` |
| `PROFILE` | `sit` | `pro` |
| Memory limits (backend) | 1G | 2G |
| Memory limits (print-service) | 1G | 2G |
| Memory limits (gateway) | 768M | 1G |
| Memory limits (config) | 512M | 512M |
| Memory limits (rdbms) | 768M | 1G |

#### `aws/pro/docker/docker-compose.override.yml`

```yaml
version: '3.8'

services:
  config:
    command: >
      bash -c "java -XX:ReservedCodeCacheSize=64M -Xss512K
      -XX:MaxMetaspaceSize=128M -XX:MaxRAMPercentage=75.0
      -XX:ActiveProcessorCount=2 -Xmx512m -jar app.jar"

  rdbms:
    command: >
      bash -c "java -XX:MaxRAMPercentage=75.0
      -XX:ActiveProcessorCount=2 -Xmx768m -jar app.jar"

  idp:
    command: >
      bash -c "java -XX:MaxRAMPercentage=75.0
      -XX:ActiveProcessorCount=2 -Xmx768m -jar app.jar"

  backend:
    command: >
      bash -c "java -XX:MaxRAMPercentage=75.0
      -XX:ActiveProcessorCount=2 -Xmx1536m -jar app.jar"

  gateway:
    command: >
      bash -c "java -XX:MaxRAMPercentage=75.0
      -XX:ActiveProcessorCount=2 -Xmx768m -jar app.jar"

  print-service:
    command: >
      bash -c "java -XX:MaxRAMPercentage=75.0
      -XX:ActiveProcessorCount=2 -Xmx1536m -jar app.jar"

  admin-dashboard:
    command: >
      bash -c "java -XX:MaxRAMPercentage=75.0
      -XX:ActiveProcessorCount=2 -Xmx768m -jar app.jar"
```

### 5.4. Deploy Script PRO

#### `aws/pro/script/deploy_module.sh`

Lo script e' strutturalmente identico a `aws/sit/script/deploy_module.sh` con due differenze:

```bash
# Riga 14-15: Cambiare i path SSM
GLOBAL_PARAM_PATH="/auxdromos/pro/global"
SCRIPT_PARAM_PATH="/auxdromos/pro/script"

# Riga 96: Path parametri modulo
local MODULE_PARAM_PATH="/auxdromos/pro/${module_to_deploy}"

# Riga 116: ENV_NAME default
ENV_NAME="${ENV_NAME:-pro}"
```

> **Raccomandazione**: Refactorizzare lo script per accettare l'ambiente come parametro:
> ```bash
> # Uso: deploy_module.sh <env> <module> [version]
> # Es:  deploy_module.sh pro backend 1.130
> ```
> Questo elimina la duplicazione del file tra `aws/sit/script/` e `aws/pro/script/`.

---

## 6. Configurazione Spring (auxdromos-configuration)

Nel repository `auxdromos-configuration` creare i file di profilo `pro` per ogni servizio. Questi file contengono la configurazione specifica per l'ambiente di produzione.

### File da creare

| File | Servizio |
|---|---|
| `application-pro.yml` | Configurazione comune a tutti i servizi |
| `backend-pro.yml` | Backend API |
| `gateway-pro.yml` | API Gateway |
| `idp-pro.yml` | Identity Provider |
| `rdbms-pro.yml` | Database migrations |
| `print-service-pro.yml` | Servizio stampa PDF |
| `admin-dashboard-pro.yml` | Dashboard amministrativa |

### Differenze chiave rispetto ai profili SIT

| Proprieta' | SIT | PRO |
|---|---|---|
| `logging.level.root` | INFO/DEBUG | WARN |
| `logging.level.com.auxdromos` | DEBUG | INFO |
| `spring.datasource.hikari.maximum-pool-size` | 5-10 | 20-30 |
| `spring.datasource.hikari.minimum-idle` | 2 | 5 |
| URL PagoPA | Sandbox/Test | **Produzione** |
| Cognito | Pool di test | Pool di produzione |
| S3 buckets | `*-sit` | `*-pro` |
| `spring.security.enabled` | Puo' essere false | **Sempre true** |
| `notify.enabled` | true (canale test) | true (canale produzione) |
| `print.service.large-data-threshold` | 1MB | 1MB |

### Esempio `application-pro.yml`

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 25
      minimum-idle: 5
      connection-timeout: 30000
      idle-timeout: 600000
      max-lifetime: 1800000

logging:
  level:
    root: WARN
    com.auxdromos: INFO
    org.springframework: WARN
    org.hibernate.SQL: WARN

management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus
  endpoint:
    health:
      show-details: when-authorized

notify:
  enabled: true
```

---

## 7. Frontend — Deploy PRO

### Auxdromos Frontend (`frontend/`)

| Aspetto | Dettaglio |
|---|---|
| Hosting | Vercel oppure S3 + CloudFront |
| Dominio | `app.auxdromos.it` (esempio) |
| `.env.production` | `NEXT_PUBLIC_API_URL=https://api.auxdromos.it` |
| Cognito | Pool di produzione, client ID/secret PRO |
| Build command | `yarn build` |
| Node version | 20.x |

### PagoDesk Frontend (`pago-desk/`)

| Aspetto | Dettaglio |
|---|---|
| Hosting | Vercel oppure S3 + CloudFront |
| Dominio | `pagodesk.auxdromos.it` (esempio) |
| `.env.production` | `NEXT_PUBLIC_API_URL=https://api.auxdromos.it` |
| Cognito | Pool di produzione (credentials provider) |
| Build command | `yarn build` |
| Node version | 20.x |

### CI/CD Frontend

Opzioni:
1. **Vercel**: Collegare il branch `pro` come production branch — deploy automatico
2. **S3 + CloudFront**: Aggiungere un job nel workflow GitHub Actions per build e sync su S3

---

## 8. Sicurezza — Requisiti e Azioni

### 8.1. Azione immediata: Credenziali esposte

I seguenti file contengono **AWS access keys in chiaro** nel repository:

- `docker/.env` (riga con `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY`)
- `aws/sit/setup/.env` (stesse credenziali)

**Azioni richieste**:
1. Revocare immediatamente le chiavi esposte dalla console IAM
2. Rimuovere i file `.env` dal repository o sostituire i valori con placeholder
3. Aggiungere `*.env` al `.gitignore` (se non gia' presente)
4. Verificare con `git log` se altri secrets sono stati committati in passato
5. Considerare l'uso di `git-secrets` o `trufflehog` per prevenire futuri leak

### 8.2. Requisiti di sicurezza per PRO

| Area | Requisito |
|---|---|
| **Autenticazione** | Cognito pool dedicato PRO, MFA obbligatoria per admin |
| **Encryption in transit** | TLS 1.2+ obbligatorio (ALB + ACM) |
| **Encryption at rest** | RDS: AWS KMS; S3: SSE-KMS; EBS: encrypted |
| **Network** | VPC dedicata, SG restrittivi, no accesso DB diretto |
| **Secrets** | Solo SSM Parameter Store (SecureString), no file nel repo |
| **Logging** | No PII (codici fiscali, IBAN) a livello DEBUG; solo WARN+ in PRO |
| **Backup** | RDS: backup automatici 30+ giorni; S3: versioning |
| **Audit** | CloudTrail abilitato per tutte le API calls |
| **WAF** | AWS WAF con regole OWASP davanti all'ALB |
| **Patching** | Aggiornamenti OS automatici (SSM Patch Manager) |

### 8.3. Separazione degli accessi

| Ruolo | Accesso SIT | Accesso PRO |
|---|---|---|
| Sviluppatore | SSH, console, deploy | Solo lettura log (CloudWatch) |
| DevOps/Admin | Tutto | SSH, deploy, console |
| CI/CD (GitHub Actions) | Deploy automatico | Deploy con approval gate |
| Applicazione | DB read/write, S3 | DB read/write, S3 (scoped) |

---

## 9. Conformita' GDPR e Normativa PA

### 9.1. Requisiti di localizzazione dati

Tutti i dati personali dei cittadini (codici fiscali, IBAN, dati catastali, ricevute di pagamento) devono risiedere **esclusivamente nell'Unione Europea**, preferibilmente in Italia.

| Dato | Storage | Region richiesta |
|---|---|---|
| Database (dati personali, tributi) | RDS PostgreSQL | eu-central-1 (Francoforte) |
| Ricevute PagoPA (PDF) | S3 `pagopa-notices-pdf-pro` | eu-central-1 |
| Documenti stampati | S3 `auxdromos-print-pro` | eu-central-1 |
| Upload massivi | S3 `auxdromos-pagopa-bulk-uploads-pro` | eu-central-1 |
| Log applicativi | CloudWatch | eu-central-1 |
| Docker images | ECR | eu-central-1 |
| Artifacts CI/CD | S3 `auxdromos-artifacts-pro` | eu-central-1 |

### 9.2. PagoPA — Requisiti di produzione

| Requisito | Dettaglio |
|---|---|
| Idempotency | Obbligatoria su tutti gli endpoint `controller/pagopa` |
| Subscription keys | Chiavi di produzione (non sandbox) |
| HMAC | Secret di produzione per firma ricevute |
| Certificati | Certificati di produzione per mTLS con PagoPA |
| Endpoint | URL di produzione PagoPA (non `api.uat.platform.pagopa.it`) |

---

## 10. Piano di Implementazione

### Fase 1 — Infrastruttura AWS (1-2 settimane)

**Responsabile**: DevOps / Cloud Engineer
**Prerequisiti**: Accesso alla console AWS, budget approvato

- [ ] 1.1. Creare VPC + Subnet in eu-central-1
- [ ] 1.2. Creare Security Groups (EC2, RDS, ALB)
- [ ] 1.3. Creare istanza EC2 PRO + installare Docker, Docker Compose, AWS CLI
- [ ] 1.4. Creare RDS PostgreSQL PRO (Multi-AZ, encrypted)
- [ ] 1.5. Creare 7 ECR repositories in eu-central-1
- [ ] 1.6. Creare S3 buckets (artifacts, print, pagopa, bulk-uploads, print-jobs)
- [ ] 1.7. Creare IAM Role OIDC `GitHubActions-AuxDromos-DeployRole-PRO`
- [ ] 1.8. Creare tutti i parametri SSM sotto `/auxdromos/pro/`
- [ ] 1.9. Creare tutti i parametri SSM sotto `/github/pro/`
- [ ] 1.10. Creare ALB + Target Group + Listener HTTPS
- [ ] 1.11. Richiedere/importare certificato ACM per il dominio
- [ ] 1.12. Configurare WAF (opzionale, raccomandato)
- [ ] 1.13. Configurare CloudWatch Log Groups e Alarms
- [ ] 1.14. Configurare CloudTrail
- [ ] 1.15. Creare GitHub Environment "production" con required reviewers

### Fase 2 — Configurazione Applicativa (3-5 giorni)

**Responsabile**: Backend Developer
**Prerequisiti**: Fase 1 completata (almeno RDS e Cognito)

- [ ] 2.1. Creare profili Spring `*-pro.yml` in `auxdromos-configuration`
- [ ] 2.2. Configurare Cognito User Pool PRO (se non esiste)
- [ ] 2.3. Ottenere credenziali PagoPA di produzione
- [ ] 2.4. Configurare URL PagoPA di produzione nei profili Spring
- [ ] 2.5. Testare connettivita' al nuovo RDS da EC2 PRO

### Fase 3 — Repository auxdromos-distro (3-5 giorni)

**Responsabile**: DevOps / Backend Developer
**Prerequisiti**: Fase 1 completata

- [ ] 3.1. Creare directory `aws/pro/docker/` con docker-compose.yml e override
- [ ] 3.2. Creare directory `aws/pro/script/` con deploy_module.sh
- [ ] 3.3. Modificare `.github/workflows/main.yml` (aggiungere branch `pro`)
- [ ] 3.4. Modificare `.github/workflows/reusable-ci-template.yml`:
  - [ ] 3.4.1. Regione AWS dinamica
  - [ ] 3.4.2. Condizioni branch per tutti i job
  - [ ] 3.4.3. IAM Role dinamico
  - [ ] 3.4.4. Nuovo job `deploy_pro` con environment gate
  - [ ] 3.4.5. SSM paths dinamici per Slack
  - [ ] 3.4.6. Upload S3 per branch `pro`
- [ ] 3.5. Rimuovere credenziali AWS dai file `.env` nel repository
- [ ] 3.6. Aggiungere `*.env` al `.gitignore`

### Fase 4 — Test e Validazione (3-5 giorni)

**Responsabile**: DevOps + QA
**Prerequisiti**: Fasi 1-3 completate

- [ ] 4.1. Creare branch `pro` da `main`
- [ ] 4.2. Configurare branch protection rules su GitHub
- [ ] 4.3. Eseguire un merge di test `main -> pro`
- [ ] 4.4. Verificare che la pipeline esegua: build, test, push ECR, upload S3
- [ ] 4.5. Approvare il deploy PRO tramite GitHub Environment
- [ ] 4.6. Verificare deploy di tutti i moduli (in ordine: config, rdbms, idp, backend, gateway, print-service, admin-dashboard)
- [ ] 4.7. Verificare health check di ogni servizio (`/actuator/health`)
- [ ] 4.8. Verificare connettivita' DB (query test)
- [ ] 4.9. Verificare connettivita' S3 (upload/download test)
- [ ] 4.10. Verificare connettivita' PagoPA (se endpoint di produzione disponibili)
- [ ] 4.11. Verificare notifiche Slack
- [ ] 4.12. Smoke test funzionale end-to-end (login, CRUD, pagamento test)

### Fase 5 — Frontend (2-3 giorni)

**Responsabile**: Frontend Developer
**Prerequisiti**: Backend PRO funzionante (Fase 4)

- [ ] 5.1. Configurare `.env.production` per Auxdromos frontend
- [ ] 5.2. Configurare `.env.production` per PagoDesk frontend
- [ ] 5.3. Configurare hosting (Vercel o S3+CloudFront)
- [ ] 5.4. Configurare dominio DNS di produzione
- [ ] 5.5. Deploy frontend PRO
- [ ] 5.6. Test end-to-end da browser

### Fase 6 — Go-Live e Monitoring (1-2 giorni)

- [ ] 6.1. Verificare tutti i CloudWatch Alarms attivi
- [ ] 6.2. Documentare runbook per incident response
- [ ] 6.3. Verificare backup RDS funzionante (restore test)
- [ ] 6.4. Comunicare Go-Live al team
- [ ] 6.5. Monitorare prime 48 ore post-deploy

---

## 11. Raccomandazioni Architetturali

### 11.1. Promozione immagini Docker (non rebuild)

La best practice e' **non rebuildarle** per PRO. L'immagine Docker e' la stessa di SIT — la differenza e' solo il profilo Spring. Opzioni:

- **ECR Cross-Region Replication**: Replicare automaticamente da us-east-1 a eu-central-1
- **Push diretto in eu-central-1**: Modificare il workflow per pushare in eu-central-1 quando il branch e' `pro`
- **Docker tag promotion**: Taggare l'immagine SIT validata come `pro-{version}` e pusharla in eu-central-1

### 11.2. Rollback

Implementare un meccanismo di rollback rapido:

```bash
# Rollback rapido: deploy della versione precedente
deploy_module.sh pro backend 1.129  # versione specifica
```

Mantenere almeno le ultime 3 versioni in ECR e S3.

### 11.3. Database Migrations

Le migration Liquibase in PRO richiedono attenzione speciale:

- Eseguire **sempre** un backup RDS snapshot prima della migration
- Testare la migration in SIT con dati simili a PRO
- Avere un rollback script Liquibase pronto
- Il modulo `rdbms` ha un timeout esteso (450s) — in PRO potrebbe servire di piu'

### 11.4. Zero-Downtime Deploy (futuro)

Per il futuro, considerare:

- **Blue/Green deploy** con due target groups sull'ALB
- **Rolling update** con Docker Swarm o migrazione a ECS/EKS
- **Database-first deploy**: eseguire migration prima del deploy applicativo

### 11.5. Infrastructure as Code

Tutta l'infrastruttura PRO dovrebbe essere gestita con **Terraform** o **AWS CDK** per:

- Riprodurre l'ambiente in caso di disaster recovery
- Versionare le modifiche infrastrutturali
- Facilitare la creazione di ambienti aggiuntivi (es. UAT, staging)

---

## 12. Stima dei Costi AWS (indicativa)

| Risorsa | Tipo | Costo mensile stimato (EUR) |
|---|---|---|
| EC2 | t3.large (on-demand) | ~75 |
| EC2 | t3.large (reserved 1y) | ~45 |
| RDS | db.r6g.large Multi-AZ | ~300 |
| RDS | db.t3.medium Multi-AZ (alternativa) | ~120 |
| ALB | Application Load Balancer | ~25 |
| S3 | 50 GB stimati | ~2 |
| ECR | 10 GB immagini | ~1 |
| CloudWatch | Logs + Alarms | ~15 |
| NAT Gateway | Per subnet private | ~35 |
| WAF | Regole base | ~10 |
| Data Transfer | Stimato | ~10 |
| **Totale (on-demand)** | | **~475-575** |
| **Totale (reserved)** | | **~300-400** |

> I costi sono indicativi e basati sui prezzi eu-central-1 a marzo 2026. Variabili significative: traffico, storage, dimensionamento RDS.

---

## 13. Rischi e Mitigazioni

| Rischio | Probabilita' | Impatto | Mitigazione |
|---|---|---|---|
| Credenziali PagoPA di produzione non disponibili | Media | Alto | Richiedere in anticipo; prevedere ambiente di staging PagoPA |
| Servizi AWS non disponibili in eu-central-1 | Bassa | Alto | Verificare disponibilita' di tutti i servizi nella region |
| Migration Liquibase fallisce in PRO | Bassa | Alto | Backup pre-migration, test su dataset simile, rollback script |
| Sizing EC2 insufficiente | Media | Medio | Monitorare CPU/RAM nelle prime settimane, scalare se necessario |
| Downtime durante deploy | Alta | Medio | Accettabile per v1; pianificare blue/green per v2 |
| Leak di dati personali nei log | Bassa | Alto | Verificare livelli di log PRO, audit dei log pattern |

---

## Appendice A — Diagramma di Deploy PRO

```
                    GitHub
                      |
                      | push to 'pro' branch
                      v
              GitHub Actions
              (reusable-ci-template.yml)
                      |
         +------------+------------+
         |            |            |
      Build        Test     Package Configs
         |            |            |
         +------------+------------+
                      |
         +------------+------------+
         |                         |
   Build & Push            Upload to S3
   Docker Image            (eu-central-1)
   (ECR eu-central-1)              |
         |                         |
         +------------+------------+
                      |
              [Manual Approval]
              (GitHub Environment)
                      |
                      v
              Deploy to PRO EC2
              (eu-central-1, Francoforte)
                      |
         +------------+------------+
         |            |            |
   deploy_module.sh   |    SSM Parameters
   (aws/pro/script/)  |    (/auxdromos/pro/)
         |            |            |
         +------------+------------+
                      |
              docker-compose up
              (aws/pro/docker/)
                      |
    +--------+--------+--------+--------+--------+
    |        |        |        |        |        |
  config   rdbms     idp   backend  gateway  print
  :8888    (exit)   :8081   :8083    :8080   :8585
                      |        |        |
                      +--------+--------+
                               |
                          ALB (HTTPS)
                               |
                      api.auxdromos.it
```

---

## Appendice B — Comandi Utili

### Creare il branch `pro`

```bash
git checkout main
git pull origin main
git checkout -b pro
git push -u origin pro
```

### Merge da main a pro (dopo validazione SIT)

```bash
git checkout pro
git pull origin pro
git merge main
# Risolvere eventuali conflitti
git push origin pro
```

### Verifica stato servizi su EC2 PRO

```bash
ssh user@ec2-pro-host
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### Rollback di un modulo

```bash
ssh user@ec2-pro-host
/app/distro/artifacts/aws/pro/script/deploy_module.sh backend 1.129
```

### Verifica health check

```bash
curl -s https://api.auxdromos.it/actuator/health | jq .
```
