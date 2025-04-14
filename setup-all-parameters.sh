#!/bin/bash
# Master script to set up all AWS Systems Manager Parameters and remove old .env files
# This script orchestrates running all the individual parameter setup scripts

# Exit on any error
set -e

# Base directory
BASE_DIR="$(dirname "$(readlink -f "$0")")"
ENV_DIR="${BASE_DIR}/aws/sit/env"
BACKUP_DIR="${BASE_DIR}/backup/aws/sit/env"

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    local status=$1
    local message=$2
    
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN}✅ $message${NC}"
    elif [[ "$status" == "error" ]]; then
        echo -e "${RED}❌ $message${NC}"
    elif [[ "$status" == "warning" ]]; then
        echo -e "${YELLOW}⚠️ $message${NC}"
    else
        echo -e "$message"
    fi
}

# Function to run a setup script
run_script() {
    local script=$1
    local script_args=$2
    
    echo ""
    echo "=============================================="
    echo "Running $script"
    echo "=============================================="
    
    if [ ! -f "$script" ]; then
        print_status "error" "Script $script not found!"
        return 1
    fi
    
    # Make script executable
    chmod +x "$script"
    
    # Run the script with specified arguments
    if ! "$script" $script_args; then
        print_status "error" "Failed to run $script!"
        return 1
    fi
    
    print_status "success" "Successfully completed $script"
    return 0
}

# Function to backup and remove .env files
backup_and_remove_env_files() {
    echo ""
    echo "=============================================="
    echo "Backing up and removing old .env files"
    echo "=============================================="
    
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"
    
    # Check if env directory exists
    if [ ! -d "$ENV_DIR" ]; then
        print_status "warning" "Environment directory $ENV_DIR does not exist!"
        return 1
    fi
    
    # Count env files
    local env_files=($(find "$ENV_DIR" -name "*.env" 2>/dev/null))
    local env_count=${#env_files[@]}
    
    if [ $env_count -eq 0 ]; then
        print_status "warning" "No .env files found in $ENV_DIR"
        return 0
    fi
    
    print_status "info" "Found $env_count .env files to process"
    
    # Backup and remove each .env file
    for env_file in "${env_files[@]}"; do
        local file_name=$(basename "$env_file")
        
        # Copy to backup
        if cp "$env_file" "$BACKUP_DIR/$file_name"; then
            print_status "success" "Backed up $file_name to $BACKUP_DIR"
            
            # Remove original
            if rm "$env_file"; then
                print_status "success" "Removed $env_file"
            else
                print_status "error" "Failed to remove $env_file"
            fi
        else
            print_status "error" "Failed to backup $file_name"
        fi
    done
    
    print_status "success" "Environment files backup and removal complete"
    return 0
}

# Process command-line arguments
SCRIPT_ARGS=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --overwrite) SCRIPT_ARGS="$SCRIPT_ARGS --overwrite" ;;
        --region) SCRIPT_ARGS="$SCRIPT_ARGS --region $2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Define the order of scripts to run
declare -a SCRIPTS=(
    "setup-global-parameters.sh"
    "setup-script-parameters.sh"
    "setup-config-parameters.sh"
    "setup-rdbms-parameters.sh"
    "setup-keycloak-parameters.sh"
    "setup-idp-parameters.sh"
    "setup-backend-parameters.sh"
    "setup-gateway-parameters.sh"
)

# Start execution
echo ""
echo "======================================================"
echo "Starting AWS SSM Parameter Store migration"
echo "Arguments: $SCRIPT_ARGS"
echo "======================================================"

# Track success
SUCCESS=true

# Run each script in order
for script in "${SCRIPTS[@]}"; do
    if ! run_script "$BASE_DIR/$script" "$SCRIPT_ARGS"; then
        SUCCESS=false
        print_status "error" "Error running $script. Continuing with other scripts..."
    fi
done

# Backup and remove .env files if all scripts succeeded
if [ "$SUCCESS" = true ]; then
    if ! backup_and_remove_env_files; then
        print_status "warning" "Issue with backing up or removing .env files"
    fi
else
    print_status "warning" "Some scripts failed. Not removing .env files for safety."
    print_status "warning" "Please fix issues and try again, or remove .env files manually."
fi

# Final status
echo ""
echo "======================================================"
if [ "$SUCCESS" = true ]; then
    print_status "success" "AWS SSM Parameter Store migration completed successfully!"
    echo "You can now update deploy_module.sh to use parameters from AWS SSM"
else
    print_status "error" "AWS SSM Parameter Store migration completed with errors!"
    echo "Please review the logs above and fix any issues."
fi
echo "======================================================"

