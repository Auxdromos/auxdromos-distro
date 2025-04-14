# Deploying with AWS Systems Manager Parameters

This document provides instructions for deploying AuxDromos modules using the deploy_module.sh script which now leverages AWS Systems Manager Parameter Store for configuration.

## Pre-Deployment Checks

Before deploying, verify that:
1. You have active AWS credentials configured with access to SSM Parameter Store in your region
2. All required parameters are set up in SSM Parameter Store

You can verify your access to parameters by running:
```bash
./test-parameter-access.sh
```

## Deployment Commands

### Deploy a Single Module

To deploy a specific module (for example, the config server):

```bash
./aws/sit/script/deploy_module.sh config
```

Replace `config` with any of the following modules:
- `config` - Configuration server
- `rdbms` - Database services
- `keycloak` - Identity and access management
- `idp` - Identity provider
- `backend` - Backend services
- `gateway` - API gateway

### Deploy All Modules

To deploy all modules in the correct order (config → rdbms → keycloak → idp → backend → gateway):

```bash
./aws/sit/script/deploy_module.sh all
```

## Troubleshooting

If you encounter issues with the deployment:

1. **Parameter access issues**: Check your AWS credentials and IAM permissions
   ```bash
   aws sts get-caller-identity
   ```

2. **Missing parameters**: Verify all parameters exist in the correct paths
   ```bash
   aws ssm get-parameters-by-path --path "/auxdromos/sit/global/" --recursive
   ```

3. **Deployment failures**: Check Docker logs
   ```bash
   docker logs auxdromos-[module_name]
   ```

## Rolling Back

If you need to roll back to using .env files instead of SSM parameters:

```bash
./rollback-from-ssm.sh
```

## Maintenance

To update parameters in AWS SSM Parameter Store:

```bash
./setup-all-parameters.sh --overwrite
```

Or for a specific module:

```bash
./setup-[module_name]-parameters.sh --overwrite
```

