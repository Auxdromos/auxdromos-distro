#!/bin/bash
# Script to set up Keycloak-specific parameters in AWS Systems Manager Parameter Store
# These parameters will be used by the Keycloak module

# Exit on any error
set -e

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed. Please install it first."
    exit 1
fi

# Base path for Keycloak parameters
PARAM_PATH="/auxdromos/sit/keycloak"
AWS_REGION="us-east-1"

# Function to create/update a parameter
create_parameter() {
    local name=$1
    local value=$2
    local type=$3  # String or SecureString
    local overwrite=$4  # true or false
    
    # Full parameter name with path
    local full_name="${PARAM_PATH}/${name}"
    
    # Check if parameter exists
    if aws ssm get-parameter --name "$full_name" --region "$AWS_REGION" &>/dev/null; then
        if [[ "$overwrite" != "true" ]]; then
            echo "Parameter $full_name already exists. Skipping. Use --overwrite to update it."
            return 0
        fi
        echo "Updating existing parameter: $full_name"
        local overwrite_flag="--overwrite"
    else
        echo "Creating new parameter: $full_name"
        local overwrite_flag=""
    fi
    
    # Create or update the parameter
    if [[ "$type" == "SecureString" ]]; then
        if ! aws ssm put-parameter --name "$full_name" --value "$value" --type "$type" $overwrite_flag --region "$AWS_REGION"; then
            echo "Error: Failed to create/update secure parameter $full_name"
            return 1
        fi
        echo "Successfully created/updated secure parameter: $full_name"
    else
        if ! aws ssm put-parameter --name "$full_name" --value "$value" --type "$type" $overwrite_flag --region "$AWS_REGION"; then
            echo "Error: Failed to create/update parameter $full_name"
            return 1
        fi
        echo "Successfully created/updated parameter: $full_name"
    fi
}

# Process command-line arguments
OVERWRITE="false"
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --overwrite) OVERWRITE="true" ;;
        --region) AWS_REGION="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

echo "Setting up Keycloak module parameters in AWS Systems Manager Parameter Store"
echo "Path: $PARAM_PATH"
echo "Region: $AWS_REGION"
echo "Overwrite existing parameters: $OVERWRITE"
echo "----------------------------------------------------"

# Create standard String parameters
create_parameter "EXTERNAL_PORT" "8082" "String" "$OVERWRITE"
create_parameter "INTERNAL_PORT" "8080" "String" "$OVERWRITE"
create_parameter "KC_DB" "postgres" "String" "$OVERWRITE"
create_parameter "DB_USERNAME" "auxdromos" "String" "$OVERWRITE"
create_parameter "KC_HOSTNAME" "localhost" "String" "$OVERWRITE"
create_parameter "KC_HEALTH_ENABLED" "true" "String" "$OVERWRITE"
create_parameter "KC_FEATURES" "preview,authorization,impersonation" "String" "$OVERWRITE"
create_parameter "KEYCLOAK_ADMIN" "admin" "String" "$OVERWRITE"

# Create SecureString parameters
create_parameter "KC_DB_URL" "jdbc:postgresql://auxdromos:DujDKqZHf60iiXPCtmHk@sit-auxdromos.cjgmm0kewpv2.us-east-1.rds.amazonaws.com:5432/sit-auxdromos?currentSchema=keycloak" "SecureString" "$OVERWRITE"
create_parameter "DB_PASSWORD" "DujDKqZHf60iiXPCtmHk" "SecureString" "$OVERWRITE"
create_parameter "KEYCLOAK_ADMIN_PASSWORD" "adminpassword" "SecureString" "$OVERWRITE"

echo "----------------------------------------------------"
echo "Keycloak module parameter setup complete."
echo "To overwrite existing parameters, run with --overwrite"
echo "To use a different region, run with --region REGION_NAME"

