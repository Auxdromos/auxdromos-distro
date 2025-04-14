#!/bin/bash
# Script to verify AWS SSM Parameter Store setup and remove old .env files
# This script ensures all required parameters are available before removing .env files

# Exit if any command fails
set -e

# Base directory
BASE_DIR="$(dirname "$(readlink -f "$0")")"
ENV_DIR="${BASE_DIR}/aws/sit/env"
BACKUP_DIR="${BASE_DIR}/backup/aws/sit/env"

# Default region
AWS_REGION="us-east-1"

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parameter paths to check
declare -a PARAM_PATHS=(
    "/auxdromos/sit/global"
    "/auxdromos/sit/script"
    "/auxdromos/sit/config"
    "/auxdromos/sit/backend"
    "/auxdromos/sit/gateway"
    "/auxdromos/sit/idp"
    "/auxdromos/sit/keycloak"
    "/auxdromos/sit/rdbms"
)

# Required parameters by path (add more as needed)
declare -A REQUIRED_PARAMS
REQUIRED_PARAMS["/auxdromos/sit/global"]="AWS_DEFAULT_REGION S3_BUCKET_NAME AWS_ACCOUNT_ID SPRING_PROFILES_ACTIVE"
REQUIRED_PARAMS["/auxdromos/sit/script"]="MODULE_ORDER"
REQUIRED_PARAMS["/auxdromos/sit/config"]="EXTERNAL_PORT INTERNAL_PORT"
REQUIRED_PARAMS["/auxdromos/sit/backend"]="EXTERNAL_PORT INTERNAL_PORT"
REQUIRED_PARAMS["/auxdromos/sit/gateway"]="EXTERNAL_PORT INTERNAL_PORT"
REQUIRED_PARAMS["/auxdromos/sit/idp"]="EXTERNAL_PORT INTERNAL_PORT"
REQUIRED_PARAMS["/auxdromos/sit/keycloak"]="EXTERNAL_PORT INTERNAL_PORT KC_DB"
REQUIRED_PARAMS["/auxdromos/sit/rdbms"]="EXTERNAL_PORT INTERNAL_PORT"

# Function to print messages
print_message() {
    local msg_type=$1
    local message=$2
    
    if [[ "$msg_type" == "success" ]]; then
        echo -e "${GREEN}✅ $message${NC}"
    elif [[ "$msg_type" == "error" ]]; then
        echo -e "${RED}❌ $message${NC}"
    elif [[ "$msg_type" == "warning" ]]; then
        echo -e "${YELLOW}⚠️ $message${NC}"
    else
        echo -e "$message"
    fi
}

# Function to check if parameters exist in a path
check_path_exists() {
    local path=$1
    local region=$2
    
    echo "Checking parameters in path: $path"
    
    # Check if the path has any parameters
    local params_json=$(aws ssm get-parameters-by-path \
                        --path "$path" \
                        --with-decryption \
                        --region "$region" \
                        --query 'Parameters[].Name' \
                        --output json 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        print_message "error" "Failed to access path: $path"
        return 1
    fi
    
    # Check if the result is empty
    local param_count=$(echo "$params_json" | jq 'length')
    
    if [ "$param_count" -eq 0 ]; then
        print_message "error" "No parameters found in path: $path"
        return 1
    fi
    
    print_message "success" "Found $param_count parameters in $path"
    return 0
}

# Function to check if specific parameters exist in a path
check_required_params() {
    local path=$1
    local required_params="${REQUIRED_PARAMS[$path]}"
    local region=$2
    
    if [ -z "$required_params" ]; then
        print_message "warning" "No required parameters specified for $path"
        return 0
    fi
    
    echo "Checking required parameters in $path: $required_params"
    
    # Get the list of parameter names (just the last part of the path)
    local params_json=$(aws ssm get-parameters-by-path \
                        --path "$path" \
                        --with-decryption \
                        --region "$region" \
                        --query 'Parameters[].Name' \
                        --output json 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        print_message "error" "Failed to access path: $path"
        return 1
    fi
    
    # Extract just the parameter names from the full paths
    local param_names=$(echo "$params_json" | jq -r '.[]' | awk -F'/' '{print $NF}')
    
    # Check each required parameter
    local missing_params=()
    for param in $required_params; do
        if ! echo "$param_names" | grep -q "^${param}$"; then
            missing_params+=("$param")
        fi
    done
    
    if [ ${#missing_params[@]} -gt 0 ]; then
        print_message "error" "Missing required parameters in $path: ${missing_params[*]}"
        return 1
    fi
    
    print_message "success" "All required parameters exist in $path"
    return 0
}

# Function to backup and remove .env files
backup_and_remove_env_files() {
    echo "Backing up and removing .env files..."
    
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"
    
    # Check if env directory exists
    if [ ! -d "$ENV_DIR" ]; then
        print_message "warning" "Environment directory $ENV_DIR does not exist!"
        return 1
    fi
    
    # Find all .env files
    local env_files=($(find "$ENV_DIR" -name "*.env" 2>/dev/null))
    local env_count=${#env_files[@]}
    
    if [ $env_count -eq 0 ]; then
        print_message "warning" "No .env files found in $ENV_DIR"
        return 0
    fi
    
    print_message "info" "Found $env_count .env files to process"
    
    # Backup and remove each .env file
    for env_file in "${env_files[@]}"; do
        local file_name=$(basename "$env_file")
        
        # Copy to backup
        if cp "$env_file" "$BACKUP_DIR/$file_name"; then
            print_message "success" "Backed up $file_name to $BACKUP_DIR"
            
            # Remove original
            if rm "$env_file"; then
                print_message "success" "Removed $env_file"
            else
                print_message "error" "Failed to remove $env_file"
            fi
        else
            print_message "error" "Failed to backup $file_name"
        fi
    done
    
    print_message "success" "Environment files backup and removal complete"
    return 0
}

# Process command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --region) AWS_REGION="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Main execution
echo "===================================================="
echo "AWS SSM Parameter Store Verification and .env Cleanup"
echo "===================================================="
echo "AWS Region: $AWS_REGION"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_message "error" "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    print_message "error" "jq is not installed. Please install it first."
    exit 1
fi

# Verify all parameter paths exist
all_paths_exist=true
for path in "${PARAM_PATHS[@]}"; do
    if ! check_path_exists "$path" "$AWS_REGION"; then
        all_paths_exist=false
    fi
done

# Verify required parameters exist
all_required_params_exist=true
if [ "$all_paths_exist" = true ]; then
    echo -e "\nVerifying required parameters..."
    for path in "${PARAM_PATHS[@]}"; do
        if ! check_required_params "$path" "$AWS_REGION"; then
            all_required_params_exist=false
        fi
    done
else
    print_message "warning" "Skipping required parameter check due to missing paths"
    all_required_params_exist=false
fi

# Perform cleanup if all checks pass
echo -e "\n===================================================="
if [ "$all_paths_exist" = true ] && [ "$all_required_params_exist" = true ]; then
    print_message "success" "All parameter paths and required parameters verified successfully!"
    echo -e "\nProceeding with .env file backup and removal..."
    if backup_and_remove_env_files; then
        print_message "success" "Cleanup completed successfully. You can now deploy using AWS SSM parameters."
    else
        print_message "error" "Cleanup encountered issues. Some .env files may still exist."
    fi
else
    print_message "error" "Verification failed! Keeping .env files intact."
    echo -e "\nPlease fix the identified issues before removing .env files."
    echo "You can use the setup parameter scripts to ensure all parameters are properly configured."
fi
echo "===================================================="

