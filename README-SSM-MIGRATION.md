# Migration from .env Files to AWS Systems Manager Parameter Store

## Overview

This project migrates environment configuration from local `.env` files to AWS Systems Manager (SSM) Parameter Store. This migration provides several benefits:

- **Centralized Configuration Management**: All parameters are stored in a central location accessible by all environments
- **Enhanced Security**: Sensitive parameters are stored as SecureString type with encryption
- **Version Control**: Parameter history is maintained automatically
- **Simplified Deployment**: No need to manage and distribute `.env` files
- **Access Control**: IAM-based permission management for parameters
- **Standardization**: Consistent parameter naming and organization

## Parameter Hierarchy

Parameters are organized in a hierarchical structure in SSM Parameter Store:

```
/auxdromos/sit/
├── global/                  # Shared parameters across all modules
│   ├── AWS_DEFAULT_REGION
│   ├── S3_BUCKET_NAME
│   ├── AWS_ACCOUNT_ID
│   ├── SPRING_PROFILES_ACTIVE
│   ├── PROFILE
│   ├── AWS_ACCESS_KEY_ID [SecureString]
│   └── AWS_SECRET_ACCESS_KEY [SecureString]
│
├── script/                  # Deployment script parameters
│   ├── EC2_APP_DIR
│   ├── BASE_PATH
│   ├── MODULES
│   └── MODULE_ORDER
│
├── config/                  # Config server parameters
│   ├── EXTERNAL_PORT
│   ├── INTERNAL_PORT
│   ├── SPRING_CLOUD_CONFIG_SERVER_GIT_URI
│   ├── SPRING_CLOUD_CONFIG_SERVER_GIT_USERNAME
│   ├── SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL
│   ├── SPRING_CLOUD_CONFIG_SERVER_GIT_SEARCH_PATHS
│   └── SPRING_CLOUD_CONFIG_SERVER_GIT_PASSWORD [SecureString]
│
├── backend/                 # Backend module parameters
│   ├── EXTERNAL_PORT
│   └── INTERNAL_PORT
│
├── gateway/                 # Gateway module parameters
│   ├── EXTERNAL_PORT
│   └── INTERNAL_PORT
│
├── idp/                     # Identity Provider parameters
│   ├── EXTERNAL_PORT
│   ├── INTERNAL_PORT
│   ├── KEYCLOAK_ADMIN
│   ├── KC_DB_URL [SecureString]
│   └── KEYCLOAK_ADMIN_PASSWORD [SecureString]
│
├── keycloak/                # Keycloak parameters
│   ├── EXTERNAL_PORT
│   ├── INTERNAL_PORT
│   ├── KC_DB
│   ├── DB_USERNAME
│   ├── KC_HOSTNAME
│   ├── KC_HEALTH_ENABLED
│   ├── KC_FEATURES
│   ├── KEYCLOAK_ADMIN
│   ├── KC_DB_URL [SecureString]
│   ├── DB_PASSWORD [SecureString]
│   └── KEYCLOAK_ADMIN_PASSWORD [SecureString]
│
└── rdbms/                   # Database parameters
    ├── EXTERNAL_PORT
    └── INTERNAL_PORT
```

## Requirements and Prerequisites

Before starting the migration:

- AWS CLI v2 installed and configured
- jq installed (for JSON parsing)
- AWS IAM permissions to:
  - Create and manage SSM parameters
  - Access secrets
- Access to the AuxDromos SIT environment

## Scripts and Their Functions

This migration package includes the following scripts:

| Script | Purpose |
|--------|---------|
| `setup-global-parameters.sh` | Creates global parameters shared across all modules |
| `setup-script-parameters.sh` | Creates script-specific parameters for deployment |
| `setup-config-parameters.sh` | Creates config server module parameters |
| `setup-backend-parameters.sh` | Creates backend module parameters |
| `setup-gateway-parameters.sh` | Creates gateway module parameters |
| `setup-idp-parameters.sh` | Creates identity provider module parameters |
| `setup-keycloak-parameters.sh` | Creates Keycloak module parameters |
| `setup-rdbms-parameters.sh` | Creates database module parameters |
| `setup-all-parameters.sh` | Master script that runs all parameter setup scripts |
| `verify-and-cleanup.sh` | Verifies parameter migration and removes old .env files |

The `deploy_module.sh` script has been updated to use parameters from SSM instead of .env files.

## Migration Steps

Follow these steps to migrate from .env files to AWS SSM Parameter Store:

### 1. Backup Current Environment

```bash
# Create backup of all .env files
mkdir -p backup/aws/sit/env
cp aws/sit/env/*.env backup/aws/sit/env/
```

### 2. Setup AWS SSM Parameters

You can set up parameters with the master script:

```bash
# Make the script executable
chmod +x setup-all-parameters.sh

# Run setup for all parameters (without overwriting existing ones)
./setup-all-parameters.sh

# Or run with overwrite option to update existing parameters
./setup-all-parameters.sh --overwrite

# Specify a different region if needed
./setup-all-parameters.sh --region eu-west-1 --overwrite
```

Alternatively, you can run individual setup scripts if you need more control:

```bash
# Example: Setup only global parameters
chmod +x setup-global-parameters.sh
./setup-global-parameters.sh --overwrite
```

### 3. Verify Parameters

Before removing .env files, verify that all parameters are set up correctly:

```bash
chmod +x verify-and-cleanup.sh
./verify-and-cleanup.sh
```

This will check all required parameters and report any issues.

### 4. Deploy Using New Parameters

Test the deployment with updated scripts that use AWS SSM Parameter Store:

```bash
# Deploy a single module
./aws/sit/script/deploy_module.sh config

# Deploy all modules
./aws/sit/script/deploy_module.sh all
```

### 5. Remove .env Files (After Verification)

Once you've verified everything works correctly, you can remove the old .env files:

```bash
# The verify-and-cleanup.sh script will remove .env files if verification passes
./verify-and-cleanup.sh
```

## Troubleshooting

### Common Issues

1. **Missing Parameters**:
   - Check the specific path in Parameter Store
   - Ensure you ran the setup scripts with correct permissions
   - Run the appropriate setup script with `--overwrite` flag

2. **Access Denied Errors**:
   - Verify your AWS credentials
   - Ensure proper IAM permissions for SSM Parameter Store

3. **Deployment Failures**:
   - Check that all required parameters exist
   - Ensure parameters have correct values
   - Verify the deploy_module.sh script is using fetch_and_export_params correctly

4. **Rollback to .env Files if Needed**:
   - Restore from the backup directory: `cp backup/aws/sit/env/*.env aws/sit/env/`

### Logs and Debugging

- Each script includes detailed logging
- AWS SSM Parameter Store provides history and version tracking
- Check CloudTrail logs for API activity related to SSM operations

## Security Considerations

1. **Sensitive Data**:
   - All passwords, secrets, and credentials are stored as SecureString type
   - Use IAM roles instead of storing AWS credentials where possible

2. **Access Control**:
   - Implement least-privilege IAM policies for parameter access
   - Consider using parameter policies for automatic expiration of sensitive data

3. **Audit and Compliance**:
   - Regularly review who has access to parameters
   - Monitor parameter access through CloudTrail

## Best Practices

1. **Parameter Organization**:
   - Maintain the hierarchical structure
   - Use consistent naming conventions
   - Document the purpose of each parameter

2. **Credential Management**:
   - Rotate credentials regularly
   - Use SecureString for all sensitive data
   - Consider integrating with AWS Secrets Manager for more advanced secret handling

3. **Deployment Strategy**:
   - Always verify parameters exist before deployment
   - Test changes in lower environments first
   - Implement a parameter change approval process

## Maintenance

1. **Adding New Parameters**:
   - Add to the appropriate setup script
   - Add to the REQUIRED_PARAMS array in verify-and-cleanup.sh
   - Document the new parameter

2. **Updating Values**:
   - Use the setup scripts with --overwrite flag
   - Or update directly in the AWS Management Console

3. **Adding New Modules**:
   - Create a new setup script following the existing pattern
   - Add the module path to the PARAM_PATHS array in verify-and-cleanup.sh
   - Update setup-all-parameters.sh to include the new script

