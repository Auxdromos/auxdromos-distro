# Runbook: Deploy Ambiente PRO — AuxDromos

**Data**: 2026-03-21
**Stato**: In corso
**Region target**: eu-central-1 (Francoforte)
**Branch**: `pro`

---

## Indice

1. [Riepilogo lavoro completato](#1-riepilogo-lavoro-completato)
2. [Attivita' rimanenti — con comandi](#2-attivita-rimanenti)
   - 2.1 [GitHub: Branch e Environment](#21-github-branch-e-environment)
   - 2.2 [AWS IAM: OIDC Role per PRO](#22-aws-iam-oidc-role-per-pro)
   - 2.3 [AWS ECR: Repository Docker in eu-central-1](#23-aws-ecr-repository-docker-in-eu-central-1)
   - 2.4 [AWS S3: Bucket artifacts PRO](#24-aws-s3-bucket-artifacts-pro)
   - 2.5 [AWS S3: Bucket applicativi PRO](#25-aws-s3-bucket-applicativi-pro)
   - 2.6 [AWS SSM: Parameter Store PRO](#26-aws-ssm-parameter-store-pro)
   - 2.7 [AWS EC2: Istanza PRO](#27-aws-ec2-istanza-pro)
   - 2.8 [AWS RDS: Database PRO](#28-aws-rds-database-pro)
   - 2.9 [Spring Config: Profili PRO](#29-spring-config-profili-pro)
   - 2.10 [Commit e push delle modifiche](#210-commit-e-push-delle-modifiche)
   - 2.11 [Primo deploy e validazione](#211-primo-deploy-e-validazione)

---

## 1. Riepilogo lavoro completato

### File creati

| File | Cosa fa |
|---|---|
| `aws/pro/docker/docker-compose.yml` | Definizione servizi Docker per PRO. Spring profile `pro`, memory limits incrementati (backend/print: 2G, gateway/idp/admin: 1G), log rotation 5 file |
| `aws/pro/docker/docker-compose.override.yml` | Override JVM per PRO: `ActiveProcessorCount=2` (vs 1 in SIT), heap raddoppiato per backend e print-service (1536m) |
| `aws/pro/script/deploy_module.sh` | Script di deploy identico a SIT ma con SSM paths `/auxdromos/pro/*` e default region `eu-central-1` |
| `docs/PRO-ENVIRONMENT-IMPLEMENTATION.md` | Documento di analisi architetturale completo |

### File modificati

| File | Cosa e' cambiato |
|---|---|
| `.github/workflows/main.yml` | Aggiunto branch `pro` nei trigger push/PR. Profilo Maven dinamico: `-Ppro` su branch pro, `-Psit` su tutti gli altri |
| `.github/workflows/reusable-ci-template.yml` | Refactoring completo (vedi sotto) |

### Dettaglio refactoring `reusable-ci-template.yml`

Il template riutilizzabile e' stato ristrutturato per supportare multi-ambiente senza duplicazione:

**Nuovo job `setup_environment`** — Centralizza tutta la configurazione per ambiente in un unico punto:

```
Branch main -> SIT: us-east-1, IAM role SIT, SSM /auxdromos/sit/*, deploy script sit
Branch pro  -> PRO: eu-central-1, IAM role PRO, SSM /auxdromos/pro/*, deploy script pro
Altri       -> Dev: solo build e test, nessun deploy
```

Outputs esposti a tutti i job downstream:
- `aws_region`, `iam_role`, `environment_name`
- `is_deployable_branch` (true solo per main e pro)
- `ssm_s3_bucket_param`, `ssm_ec2_user_param`, `ssm_ec2_host_param`, `ssm_ec2_key_param`
- `ssm_slack_webhook_param`, `deploy_script_path`

**Nuovo job `deploy_pro`** — Speculare a `deploy_sit` ma:
- Si attiva solo su `github.ref_name == 'pro'`
- Ha `environment: production` (richiede approvazione manuale su GitHub)
- Usa SSM paths `/github/pro/*` per EC2 host/user/key
- Usa il deploy script `/app/distro/artifacts/aws/pro/script/deploy_module.sh`

**Job esistenti aggiornati:**
- `check_version`: condizione cambiata da `ref_name == 'main'` a `is_deployable_branch == 'true'`
- `package_configs`: idem
- `build_docker`: idem, usa IAM role e region dinamici
- `upload_to_s3`: idem, usa S3 bucket param dinamico
- `tag_latest`: idem, aggiunto campo `environment` al latest.json
- `slack_notification`: aggiunto `deploy_pro` nelle dipendenze, messaggio distingue SIT/PRO
- Tutti i job con AWS credentials usano `needs.setup_environment.outputs.iam_role` e `.aws_region`

### Differenze chiave SIT vs PRO nel docker-compose

| Parametro | SIT | PRO |
|---|---|---|
| `SPRING_PROFILES_ACTIVE` | `sit` | `pro` |
| `PROFILE` | `sit` | `pro` |
| Backend memory limit | 1G | 2G |
| Backend JVM heap | 768m | 1536m |
| Print-service memory | 1G | 2G |
| Print-service heap | 768m | 1536m |
| Gateway memory | 768M | 1G |
| ActiveProcessorCount | 1 | 2 |
| Config heap | 256m | 512m |
| Log max-file | 3 | 5 |

---

## 2. Attivita' rimanenti

### 2.1 GitHub: Branch e Environment

#### Creare il branch `pro`

```bash
# Da locale
git checkout main
git pull origin main
git checkout -b pro
git push -u origin pro
```

#### Configurare branch protection rules

Su GitHub: `Settings > Branches > Add branch ruleset` per `pro`:

1. Andare su https://github.com/Auxdromos/auxdromos-distro/settings/branches
2. Click "Add branch ruleset"
3. Nome: `pro-protection`
4. Target: branch `pro`
5. Regole:
   - [x] Require a pull request before merging (1 approval)
   - [x] Require status checks to pass before merging
     - Status check: `Build Project`
     - Status check: `Test Project`
   - [x] Require branches to be up to date before merging
   - [x] Block force pushes
   - [x] Block deletions

#### Creare GitHub Environment "production"

Su GitHub: `Settings > Environments > New environment`:

1. Andare su https://github.com/Auxdromos/auxdromos-distro/settings/environments
2. Click "New environment"
3. Nome: `production`
4. Configurare:
   - [x] Required reviewers: aggiungere gli utenti autorizzati al deploy PRO
   - [x] Deployment branches: selezionare "Selected branches" e aggiungere `pro`

Questo abilita l'approval gate nel job `deploy_pro` del workflow (campo `environment: production`).

---

### 2.2 AWS IAM: OIDC Role per PRO

Il workflow PRO necessita di un IAM Role dedicato con trust policy scoped al branch `pro`.

#### Creare il role

```bash
# 1. Creare il file trust policy
cat > /tmp/trust-policy-pro.json << 'EOF'
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
EOF

# 2. Creare il role
aws iam create-role \
  --role-name GitHubActions-AuxDromos-DeployRole-PRO \
  --assume-role-policy-document file:///tmp/trust-policy-pro.json \
  --description "GitHub Actions OIDC role for AuxDromos PRO deployments (eu-central-1)" \
  --region eu-central-1
```

#### Attaccare le policy necessarie

```bash
# 3. Creare la policy con i permessi necessari
cat > /tmp/pro-deploy-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAccess",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeRepositories",
        "ecr:CreateRepository",
        "ecr:DescribeImages"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3ArtifactsAccess",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::auxdromos-artifacts-pro",
        "arn:aws:s3:::auxdromos-artifacts-pro/*"
      ]
    },
    {
      "Sid": "SSMReadAccess",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": [
        "arn:aws:ssm:eu-central-1:463470955561:parameter/auxdromos/pro/*",
        "arn:aws:ssm:eu-central-1:463470955561:parameter/github/pro/*",
        "arn:aws:ssm:eu-central-1:463470955561:parameter/github/common/*"
      ]
    },
    {
      "Sid": "STSAccess",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name GitHubActions-AuxDromos-DeployRole-PRO \
  --policy-name AuxDromos-PRO-DeployPolicy \
  --policy-document file:///tmp/pro-deploy-policy.json
```

---

### 2.3 AWS ECR: Repository Docker in eu-central-1

Creare un repository ECR per ogni modulo che ha un Dockerfile.

```bash
# Lista dei moduli che necessitano un repository ECR
MODULES=(
  "auxdromos-config"
  "auxdromos-rdbms"
  "auxdromos-idp"
  "auxdromos-backend"
  "auxdromos-gateway"
  "auxdromos-print-service"
  "auxdromos-admin-dashboard"
)

# Creare i repository in eu-central-1
for MODULE in "${MODULES[@]}"; do
  echo "Creazione repository ECR: $MODULE"
  aws ecr create-repository \
    --repository-name "$MODULE" \
    --region eu-central-1 \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256
done

# Verificare la creazione
aws ecr describe-repositories \
  --region eu-central-1 \
  --query 'repositories[].repositoryName' \
  --output table
```

#### (Opzionale) Lifecycle policy per pulizia immagini vecchie

```bash
# Applicare a tutti i repository
LIFECYCLE_POLICY='{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Mantieni solo le ultime 10 immagini tagged",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["1"],
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": {
        "type": "expire"
      }
    },
    {
      "rulePriority": 2,
      "description": "Rimuovi immagini untagged dopo 7 giorni",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": 7
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}'

for MODULE in "${MODULES[@]}"; do
  aws ecr put-lifecycle-policy \
    --repository-name "$MODULE" \
    --lifecycle-policy-text "$LIFECYCLE_POLICY" \
    --region eu-central-1
done
```

---

### 2.4 AWS S3: Bucket artifacts PRO

```bash
# Creare il bucket per gli artifacts CI/CD
aws s3api create-bucket \
  --bucket auxdromos-artifacts-pro \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

# Abilitare versioning
aws s3api put-bucket-versioning \
  --bucket auxdromos-artifacts-pro \
  --versioning-configuration Status=Enabled

# Abilitare encryption default (SSE-S3)
aws s3api put-bucket-encryption \
  --bucket auxdromos-artifacts-pro \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms"
        },
        "BucketKeyEnabled": true
      }
    ]
  }'

# Bloccare accesso pubblico
aws s3api put-public-access-block \
  --bucket auxdromos-artifacts-pro \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Lifecycle policy: rimuovere artifacts vecchi dopo 90 giorni
aws s3api put-bucket-lifecycle-configuration \
  --bucket auxdromos-artifacts-pro \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "cleanup-old-artifacts",
        "Status": "Enabled",
        "Filter": {},
        "Expiration": {
          "Days": 90
        },
        "NoncurrentVersionExpiration": {
          "NoncurrentDays": 30
        }
      }
    ]
  }'
```

---

### 2.5 AWS S3: Bucket applicativi PRO

```bash
# Bucket per output PDF del print-service
aws s3api create-bucket \
  --bucket auxdromos-print-pro \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

# Bucket per avvisi di pagamento PagoPA
aws s3api create-bucket \
  --bucket pagopa-notices-pdf-pro \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

# Bucket per upload massivi PagoPA
aws s3api create-bucket \
  --bucket auxdromos-pagopa-bulk-uploads-pro \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

# Bucket per print jobs > 1MB
aws s3api create-bucket \
  --bucket auxdromos-print-jobs-pro \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

# Applicare encryption + block public access a tutti
for BUCKET in auxdromos-print-pro pagopa-notices-pdf-pro auxdromos-pagopa-bulk-uploads-pro auxdromos-print-jobs-pro; do
  echo "Configurazione bucket: $BUCKET"

  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
      "Rules": [{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]
    }'

  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
done
```

---

### 2.6 AWS SSM: Parameter Store PRO

Tutti i parametri devono essere creati in **eu-central-1**.

#### Parametri globali `/auxdromos/pro/global`

```bash
REGION="eu-central-1"

# --- Parametri non sensibili (String) ---
aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/AWS_ACCOUNT_ID" \
  --type String \
  --value "463470955561"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/AWS_DEFAULT_REGION" \
  --type String \
  --value "eu-central-1"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/ENV_NAME" \
  --type String \
  --value "pro"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/SPRING_PROFILES_ACTIVE" \
  --type String \
  --value "pro"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/PROFILE" \
  --type String \
  --value "pro"

# --- Parametri sensibili (SecureString) ---
# SOSTITUIRE i valori placeholder con quelli reali!

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/DB_URL" \
  --type SecureString \
  --value "jdbc:postgresql://HOSTNAME_RDS_PRO:5432/auxdromos_pro"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/DB_USERNAME" \
  --type SecureString \
  --value "INSERIRE_USERNAME_DB_PRO"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/DB_PASSWORD" \
  --type SecureString \
  --value "INSERIRE_PASSWORD_DB_PRO"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/SLACK_WEBHOOK_URL" \
  --type SecureString \
  --value "INSERIRE_WEBHOOK_SLACK_PRO"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/COGNITO_CLIENT_SECRET" \
  --type SecureString \
  --value "INSERIRE_COGNITO_SECRET_PRO"

# --- Config Server ---
aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/SPRING_CLOUD_CONFIG_SERVER_GIT_URI" \
  --type String \
  --value "https://github.com/Auxdromos/auxdromos-configuration.git"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/SPRING_CLOUD_CONFIG_SERVER_GIT_USERNAME" \
  --type SecureString \
  --value "INSERIRE_GIT_USERNAME"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/SPRING_CLOUD_CONFIG_SERVER_GIT_PASSWORD" \
  --type SecureString \
  --value "INSERIRE_GIT_TOKEN"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL" \
  --type String \
  --value "pro"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/SPRING_CLOUD_CONFIG_SERVER_GIT_SEARCH_PATHS" \
  --type String \
  --value "/"

# --- PagoPA (SOSTITUIRE con credenziali di produzione!) ---
aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/PAGOPA_RECEIPTS_SUBSCRIPTION_KEY" \
  --type SecureString \
  --value "INSERIRE_KEY_PRODUZIONE"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/PAGOPA_GDP_SUBSCRIPTION_KEY" \
  --type SecureString \
  --value "INSERIRE_KEY_PRODUZIONE"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/PAGOPA_PRINT_SUBSCRIPTION_KEY" \
  --type SecureString \
  --value "INSERIRE_KEY_PRODUZIONE"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/PAGOPA_FDR_SUBSCRIPTION_KEY" \
  --type SecureString \
  --value "INSERIRE_KEY_PRODUZIONE"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/PAGOPA_HMAC_SECRET" \
  --type SecureString \
  --value "INSERIRE_HMAC_PRODUZIONE"

aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/global/PAGOPA_RECEIPT_HMAC_SECRET_KEY" \
  --type SecureString \
  --value "INSERIRE_HMAC_KEY_PRODUZIONE"
```

#### Parametri script `/auxdromos/pro/script`

```bash
aws ssm put-parameter --region $REGION \
  --name "/auxdromos/pro/script/MODULE_ORDER" \
  --type String \
  --value "config rdbms idp backend gateway print-service admin-dashboard"
```

#### Parametri GitHub CI/CD `/github/pro`

```bash
# EC2 host e user (da compilare quando l'EC2 sara' pronta)
aws ssm put-parameter --region $REGION \
  --name "/github/pro/ec2_user" \
  --type String \
  --value "INSERIRE_EC2_USER"

aws ssm put-parameter --region $REGION \
  --name "/github/pro/ec2_host" \
  --type String \
  --value "INSERIRE_EC2_HOST_O_IP"

aws ssm put-parameter --region $REGION \
  --name "/github/pro/ec2_private_key" \
  --type SecureString \
  --value "INSERIRE_CHIAVE_PRIVATA_SSH"

# S3 bucket name per il workflow
aws ssm put-parameter --region $REGION \
  --name "/github/common/s3_bucket_name_pro" \
  --type String \
  --value "auxdromos-artifacts-pro"
```

#### Verificare tutti i parametri creati

```bash
# Verifica parametri globali
aws ssm get-parameters-by-path \
  --path "/auxdromos/pro" \
  --recursive \
  --region eu-central-1 \
  --query 'Parameters[].Name' \
  --output table

# Verifica parametri GitHub
aws ssm get-parameters-by-path \
  --path "/github/pro" \
  --recursive \
  --region eu-central-1 \
  --query 'Parameters[].Name' \
  --output table

# Verifica S3 bucket param
aws ssm get-parameter \
  --name "/github/common/s3_bucket_name_pro" \
  --region eu-central-1 \
  --query 'Parameter.Value' \
  --output text
```

---

### 2.7 AWS EC2: Istanza PRO

#### Creare l'istanza

> Nota: i comandi seguenti assumono che VPC, Subnet e Security Group siano gia' stati creati.
> Sostituire i placeholder con gli ID reali.

```bash
# Trovare l'AMI Amazon Linux 2023 piu' recente
AMI_ID=$(aws ec2 describe-images \
  --region eu-central-1 \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)
echo "AMI: $AMI_ID"

# Creare key pair
aws ec2 create-key-pair \
  --key-name auxdromos-pro-key \
  --region eu-central-1 \
  --query 'KeyMaterial' \
  --output text > auxdromos-pro-key.pem
chmod 600 auxdromos-pro-key.pem
echo "IMPORTANTE: Salvare auxdromos-pro-key.pem in un luogo sicuro!"

# Lanciare l'istanza
aws ec2 run-instances \
  --region eu-central-1 \
  --image-id "$AMI_ID" \
  --instance-type t3.large \
  --key-name auxdromos-pro-key \
  --subnet-id "INSERIRE_SUBNET_ID" \
  --security-group-ids "INSERIRE_SG_ID" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":50,"VolumeType":"gp3","Encrypted":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=auxdromos-pro},{Key=Environment,Value=production}]' \
  --iam-instance-profile Name=AuxDromos-EC2-PRO-Profile \
  --query 'Instances[0].InstanceId' \
  --output text
```

#### Preparare l'istanza EC2 (dopo che e' running)

```bash
# Connettersi all'istanza
ssh -i auxdromos-pro-key.pem ec2-user@IP_ISTANZA

# Installare Docker
sudo dnf update -y
sudo dnf install -y docker
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker ec2-user

# Installare Docker Compose v2
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version

# Installare utilita'
sudo dnf install -y jq unzip

# Verificare AWS CLI (preinstallato su Amazon Linux 2023)
aws --version

# Creare directory applicativa
sudo mkdir -p /app/distro/artifacts
sudo chown -R ec2-user:ec2-user /app

# Creare la rete Docker
docker network create auxdromos-network

# Uscire e riconnettersi per il gruppo docker
exit
```

#### Aggiornare SSM con i dati dell'istanza

```bash
# Recuperare l'IP pubblico (o privato se dietro ALB)
INSTANCE_IP=$(aws ec2 describe-instances \
  --region eu-central-1 \
  --filters "Name=tag:Name,Values=auxdromos-pro" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

# Aggiornare i parametri SSM
aws ssm put-parameter --region eu-central-1 \
  --name "/github/pro/ec2_host" \
  --type String \
  --value "$INSTANCE_IP" \
  --overwrite

aws ssm put-parameter --region eu-central-1 \
  --name "/github/pro/ec2_user" \
  --type String \
  --value "ec2-user" \
  --overwrite

# Caricare la chiave privata SSH in SSM
aws ssm put-parameter --region eu-central-1 \
  --name "/github/pro/ec2_private_key" \
  --type SecureString \
  --value "$(cat auxdromos-pro-key.pem)" \
  --overwrite
```

---

### 2.8 AWS RDS: Database PRO

```bash
# Creare subnet group per RDS (richiede 2+ AZ)
aws rds create-db-subnet-group \
  --region eu-central-1 \
  --db-subnet-group-name auxdromos-pro-db-subnet \
  --db-subnet-group-description "Subnet group per RDS AuxDromos PRO" \
  --subnet-ids "INSERIRE_SUBNET_PRIVATA_AZ1" "INSERIRE_SUBNET_PRIVATA_AZ2"

# Creare l'istanza RDS
aws rds create-db-instance \
  --region eu-central-1 \
  --db-instance-identifier auxdromos-pro-db \
  --db-instance-class db.t3.medium \
  --engine postgres \
  --engine-version "17.2" \
  --master-username auxdromos_admin \
  --master-user-password "INSERIRE_PASSWORD_SICURA" \
  --allocated-storage 50 \
  --storage-type gp3 \
  --storage-encrypted \
  --multi-az \
  --db-name auxdromos_pro \
  --vpc-security-group-ids "INSERIRE_SG_RDS_ID" \
  --db-subnet-group-name auxdromos-pro-db-subnet \
  --backup-retention-period 30 \
  --preferred-backup-window "02:00-03:00" \
  --preferred-maintenance-window "Sun:03:00-Sun:04:00" \
  --auto-minor-version-upgrade \
  --copy-tags-to-snapshot \
  --deletion-protection \
  --tags Key=Environment,Value=production Key=Name,Value=auxdromos-pro-db

# Attendere che sia disponibile (puo' richiedere 10-15 minuti)
aws rds wait db-instance-available \
  --db-instance-identifier auxdromos-pro-db \
  --region eu-central-1

# Recuperare l'endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --region eu-central-1 \
  --db-instance-identifier auxdromos-pro-db \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)
echo "RDS Endpoint: $RDS_ENDPOINT"

# Aggiornare SSM con la JDBC URL
aws ssm put-parameter --region eu-central-1 \
  --name "/auxdromos/pro/global/DB_URL" \
  --type SecureString \
  --value "jdbc:postgresql://${RDS_ENDPOINT}:5432/auxdromos_pro" \
  --overwrite

aws ssm put-parameter --region eu-central-1 \
  --name "/auxdromos/pro/global/DB_USERNAME" \
  --type SecureString \
  --value "auxdromos_admin" \
  --overwrite

aws ssm put-parameter --region eu-central-1 \
  --name "/auxdromos/pro/global/DB_PASSWORD" \
  --type SecureString \
  --value "INSERIRE_PASSWORD_SICURA" \
  --overwrite
```

---

### 2.9 Spring Config: Profili PRO

Nel repository `auxdromos-configuration`, creare i file di profilo `pro` per ogni servizio.

```bash
# Clonare il repo di configurazione (se non gia' presente)
cd /Users/massimilianobranca/Work/AuxDromos/Github
git clone git@github.com:Auxdromos/auxdromos-configuration.git
cd auxdromos-configuration

# Verificare i file SIT esistenti da usare come base
ls -la *-sit.yml *sit* 2>/dev/null || ls -la *.yml
```

Per ogni file `*-sit.yml` esistente, creare il corrispondente `*-pro.yml` con queste modifiche:

| Proprieta' | Valore SIT | Valore PRO |
|---|---|---|
| `logging.level.root` | INFO | WARN |
| `logging.level.com.auxdromos` | DEBUG | INFO |
| `spring.datasource.hikari.maximum-pool-size` | 5-10 | 20-30 |
| `spring.datasource.hikari.minimum-idle` | 2 | 5 |
| URL endpoint PagoPA | `api.uat.platform.pagopa.it` | `api.platform.pagopa.it` |
| S3 bucket names | `*-sit` | `*-pro` |
| `spring.security.enabled` | puo' essere false | **sempre true** |

Esempio `application-pro.yml`:

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
        include: health,info,metrics
  endpoint:
    health:
      show-details: when-authorized
```

---

### 2.10 Commit e push delle modifiche

Le modifiche fatte in questo repository (`auxdromos-distro`) devono essere committate e pushate su `main`. Quando il branch `pro` sara' creato, ricevera' queste modifiche tramite merge.

```bash
cd /Users/massimilianobranca/Work/AuxDromos/Github/auxdromos-distro

# Verificare cosa sara' committato
git status
git diff --stat

# Aggiungere i file
git add .github/workflows/main.yml
git add .github/workflows/reusable-ci-template.yml
git add aws/pro/docker/docker-compose.yml
git add aws/pro/docker/docker-compose.override.yml
git add aws/pro/script/deploy_module.sh
git add docs/PRO-ENVIRONMENT-IMPLEMENTATION.md
git add docs/PRO-DEPLOYMENT-RUNBOOK.md

# Committare
git commit -m "feat(deploy): add PRO environment support (eu-central-1)

- Add aws/pro/ directory with docker-compose, override, and deploy script
- Update reusable-ci-template.yml with setup_environment job for multi-env
- Add deploy_pro job with GitHub Environment approval gate
- Add pro branch to CI/CD triggers with dynamic Maven profile (-Ppro)
- All env-specific config (region, IAM role, SSM paths) centralized in setup_environment

Refs #AUX-XXX"

# Push su main (triggera il deploy SIT, che non e' impattato)
git push origin main
```

Poi creare il branch `pro`:

```bash
git checkout -b pro
git push -u origin pro
```

---

### 2.11 Primo deploy e validazione

Dopo aver completato tutti i passi precedenti (infrastruttura AWS, SSM parameters, profili Spring):

#### 1. Trigger del primo deploy

```bash
# Da main, fare un merge su pro per triggerare la pipeline
git checkout pro
git merge main
git push origin pro
```

#### 2. Approvare il deploy su GitHub

1. Andare su https://github.com/Auxdromos/auxdromos-distro/actions
2. Trovare il workflow run del branch `pro`
3. Il job `Deploy to PRO Environment` sara' in stato "Waiting"
4. Click "Review deployments" > selezionare "production" > "Approve and deploy"

#### 3. Verificare il deploy sull'EC2 PRO

```bash
# Connettersi all'EC2 PRO
ssh -i auxdromos-pro-key.pem ec2-user@IP_EC2_PRO

# Verificare i container in esecuzione
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Verificare i log di ogni servizio
docker logs auxdromos-config --tail 20
docker logs auxdromos-backend --tail 20
docker logs auxdromos-gateway --tail 20

# Health check
curl -s http://localhost:8888/actuator/health | jq .   # Config
curl -s http://localhost:8083/actuator/health | jq .   # Backend
curl -s http://localhost:8080/actuator/health | jq .   # Gateway
curl -s http://localhost:8085/actuator/health | jq .   # Print Service
curl -s http://localhost:8081/actuator/health | jq .   # IDP
curl -s http://localhost:8086/actuator/health | jq .   # Admin Dashboard
```

#### 4. Checklist post-deploy

```
[ ] Tutti i container sono in stato "Up"
[ ] Health check OK per ogni servizio
[ ] Config server risponde con profilo "pro"
[ ] Backend si connette al database RDS PRO
[ ] Gateway ruota correttamente al backend
[ ] Print service puo' scrivere su S3 (auxdromos-print-pro)
[ ] Notifica Slack ricevuta sul canale PRO
[ ] Log level e' WARN (non DEBUG)
[ ] Nessun dato PII nei log
```

---

## Appendice: Riepilogo visuale

```
STATO ATTUALE                           TARGET
=============                           ======

Repository (auxdromos-distro)
  aws/
    local/       [esistente]
    sit/         [esistente]
    pro/         [CREATO]  <-- docker-compose + deploy script

  .github/workflows/
    main.yml                [MODIFICATO] <-- branch pro + profilo Maven
    reusable-ci-template.yml [MODIFICATO] <-- setup_environment + deploy_pro

GitHub
  Branch main    [esistente]
  Branch pro     [DA CREARE]  <-- punto 2.1
  Env production [DA CREARE]  <-- punto 2.1

AWS eu-central-1
  IAM Role PRO   [DA CREARE]  <-- punto 2.2
  ECR repos (x7) [DA CREARE]  <-- punto 2.3
  S3 artifacts   [DA CREARE]  <-- punto 2.4
  S3 applicativi [DA CREARE]  <-- punto 2.5
  SSM parameters [DA CREARE]  <-- punto 2.6
  EC2 istanza    [DA CREARE]  <-- punto 2.7
  RDS PostgreSQL [DA CREARE]  <-- punto 2.8

auxdromos-configuration
  *-pro.yml      [DA CREARE]  <-- punto 2.9
```
