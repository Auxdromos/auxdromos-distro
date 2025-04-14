# EC2 Deployment Guide for AWS SSM Migration

This guide provides step-by-step instructions for deploying the updated AuxDromos application to an EC2 instance after migrating from .env files to AWS Systems Manager Parameter Store.

## Prerequisites

- EC2 instance with Docker and Git installed
- AWS CLI configured with appropriate credentials
- IAM permissions to update IAM roles/policies
- Network access to AWS services (SSM, ECR)

## Deployment Steps

### 1. Push Local Changes to Repository

First, push your committed changes to the Git repository:

```bash
git push origin main
```

### 2. On the EC2 Instance

Connect to your EC2 instance and follow these steps:

#### a. Pull the Latest Changes

```bash
# Navigate to your project directory
cd /app/distro  # or your actual project directory
git pull
```

#### b. Apply the IAM Policy for SSM Access

If your EC2 instance uses an IAM role:

```bash
# Get the instance role name if you don't know it
ROLE_NAME=$(aws ec2 describe-instances --instance-id $(curl -s http://169.254.169.254/latest/meta-data/instance-id) --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | cut -d/ -f2)

# Apply the policy to the role
aws iam put-role-policy \
  --role-name $ROLE_NAME \
  --policy-name AuxdromosSSMAccess \
  --policy-document file://iam-policy-ssm-parameters.json
```

If using an IAM user instead:

```bash
aws iam put-user-policy \
  --user-name auxdromos-deploy-user \
  --policy-name AuxdromosSSMAccess \
  --policy-document file://iam-policy-ssm-parameters.json
```

#### c. Make Scripts Executable

```bash
./make-scripts-executable.sh
```

#### d. Set Up SSM Parameters

```bash
# Set up all parameters in AWS SSM
./setup-all-parameters.sh --region us-east-1

# If you need to update existing parameters:
./setup-all-parameters.sh --region us-east-1 --overwrite
```

#### e. Verify SSM Access

```bash
# Test access to parameters
./test-parameter-access.sh
```

Make sure all tests pass before proceeding to deployment.

#### f. Deploy the Config Service First

```bash
# Deploy config service (required by other services)
./aws/sit/script/deploy_module.sh config

# Verify config service is running
curl http://localhost:8888/actuator/health
```

#### g. Deploy All Services

Once the config service is running properly:

```bash
# Deploy all modules in the correct order
./aws/sit/script/deploy_module.sh all
```

## Troubleshooting

### IAM Policy Issues

If you encounter permission errors with SSM Parameter Store:

```bash
# Verify the policy is attached
aws iam get-role-policy --role-name $ROLE_NAME --policy-name AuxdromosSSMAccess
```

### Parameter Retrieval Issues

If parameters aren't being retrieved correctly:

```bash
# Test specific parameter access
aws ssm get-parameter --name "/auxdromos/sit/global/AWS_DEFAULT_REGION" --with-decryption

# Check recent SSM API calls
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=GetParameter
```

### Deployment Issues

If a service fails to start:

```bash
# Check container logs
docker logs auxdromos-[service_name]

# Use the rollback script if needed
./rollback-from-ssm.sh
```

## Notes

- Keep your AWS credentials secure
- Consider rotating sensitive parameters regularly
- Use IAM roles rather than IAM users when possible
- Monitor parameter access through CloudTrail

