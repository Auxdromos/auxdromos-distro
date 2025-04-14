#!/bin/bash
# Script to set up global parameters in AWS Systems Manager Parameter Store
# These parameters will be used across all AuxDromos modules

# Exit on any error
set -e

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed. Please install it first."
    exit 1
fi

# Base path for global parameters
PARAM_PATH="/auxdromos/sit/global"
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

echo "Setting up global parameters in AWS Systems Manager Parameter Store"
echo "Path: $PARAM_PATH"
echo "Region: $AWS_REGION"
echo "Overwrite existing parameters: $OVERWRITE"
echo "----------------------------------------------------"

# Create String parameters
create_parameter "AWS_DEFAULT_REGION" "us-east-1" "String" "$OVERWRITE"
create_parameter "S3_BUCKET_NAME" "auxdromos-artifacts-unique" "String" "$OVERWRITE"
create_parameter "AWS_ACCOUNT_ID" "463470955561" "String" "$OVERWRITE"
create_parameter "SPRING_PROFILES_ACTIVE" "sit" "String" "$OVERWRITE"
create_parameter "PROFILE" "sit" "String" "$OVERWRITE"

# Create SecureString parameters
create_parameter "AWS_ACCESS_KEY_ID" "AKIAWX2IFRQUU4JWGC7P" "SecureString" "$OVERWRITE"
create_parameter "AWS_SECRET_ACCESS_KEY" "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" "SecureString" "$OVERWRITE"

echo "----------------------------------------------------"
echo "Parameter setup complete."
echo "To overwrite existing parameters, run with --overwrite"
echo "To use a different region, run with --region REGION_NAME"

