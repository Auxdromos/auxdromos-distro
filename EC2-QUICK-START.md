# EC2 Quick Start Reference

This quick reference provides the essential commands for connecting to your EC2 instance and starting the AWS SSM parameter migration deployment.

## Connect to EC2

```bash
# Connect to your EC2 instance (replace with your actual key and hostname)
ssh -i /path/to/your-key.pem ec2-user@your-instance-public-dns
```

For Amazon Linux or RHEL-based instances, use `ec2-user`. For Ubuntu instances, use `ubuntu`.

## Verify AWS Configuration

Once connected, verify your AWS configuration:

```bash
# Check configured AWS region
aws configure get region

# Verify identity (account ID and IAM user/role)
aws sts get-caller-identity
```

## Check IAM Role

Verify the IAM role attached to the instance:

```bash
# Get the instance ID from metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Get the IAM role ARN
aws ec2 describe-instances \
  --instance-id $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text

# Extract just the role name from the ARN
ROLE_NAME=$(aws ec2 describe-instances \
  --instance-id $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text | cut -d/ -f2)

echo "IAM Role Name: $ROLE_NAME"
```

## Clone Repository (if not already present)

```bash
# Create or navigate to your app directory
mkdir -p /app && cd /app

# Clone repository
git clone https://github.com/Auxdromos/auxdromos-distro.git distro
cd distro
```

## Follow Deployment Guide

For complete deployment instructions, refer to [EC2-DEPLOYMENT-GUIDE.md](EC2-DEPLOYMENT-GUIDE.md) in the repository.

## Quick Deployment Commands

```bash
# 1. Make scripts executable
./make-scripts-executable.sh

# 2. Set up AWS SSM parameters
./setup-all-parameters.sh --region us-east-1

# 3. Verify parameter access
./test-parameter-access.sh

# 4. Deploy config service first
./aws/sit/script/deploy_module.sh config

# 5. Deploy all services
./aws/sit/script/deploy_module.sh all
```

