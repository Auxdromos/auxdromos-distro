#!/bin/bash
# Master script for migrating from .env files to AWS Systems Manager Parameter Store
# This script orchestrates the entire migration process from start to finish

# Exit if any command fails
set -e

# Base directory
BASE_DIR="$(dirname "$(readlink -f "$0")")"

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default settings
AWS_REGION=""
OVERWRITE=false
SKIP_TESTS=false
KEEP_ENV=false

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
    elif [[ "$msg_type" == "info" ]]; then
        echo -e "${BLUE}ℹ️ $message${NC}"
    elif [[ "$msg_type" == "header" ]]; then
        echo ""
        echo "===================================================="
        echo -e "${BLUE}$message${NC}"
        echo "===================================================="
    else
        echo -e "$message"
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --region REGION   Specify AWS region (default: from AWS config or us-east-1)"
    echo "  --overwrite       Force overwrite of existing parameters"
    echo "  --skip-tests      Skip initial AWS configuration tests"
    echo "  --keep-env        Do not remove .env files after migration"
    echo "  --help            Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --region us-east-1 --overwrite"
}

# Process command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --region)
            AWS_REGION="$2"
            shift
            ;;
        --overwrite)
            OVERWRITE=true
            ;;
        --skip-tests)
            SKIP_TESTS=true
            ;;
        --keep-env)
            KEEP_ENV=true
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            print_message "error" "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
    shift
done

# Build command-line args for child scripts
REGION_ARG=""
if [[ -n "$AWS_REGION" ]]; then
    REGION_ARG="--region $AWS_REGION"
    # Also set the environment variable for scripts that use it directly
    export AWS_DEFAULT_REGION="$AWS_REGION"
fi

OVERWRITE_ARG=""
if [[ "$OVERWRITE" == true ]]; then
    OVERWRITE_ARG="--overwrite"
fi

# Main migration process
print_message "header" "Starting Migration to AWS Systems Manager Parameter Store"
print_message "info" "This process will migrate all environment configuration from .env files to AWS SSM."

# Step 1: Make all scripts executable
print_message "header" "Step 1: Making All Scripts Executable"
if [ -f "${BASE_DIR}/make-scripts-executable.sh" ]; then
    print_message "info" "Running make-scripts-executable.sh..."
    chmod +x "${BASE_DIR}/make-scripts-executable.sh"
    if ! "${BASE_DIR}/make-scripts-executable.sh"; then
        print_message "error" "Failed to make scripts executable. Please check permissions."
        exit 1
    fi
else
    print_message "warning" "make-scripts-executable.sh not found. Making essential scripts executable manually..."
    chmod +x "${BASE_DIR}/test-parameter-access.sh" "${BASE_DIR}/setup-all-parameters.sh" "${BASE_DIR}/verify-and-cleanup.sh" 2>/dev/null || true
fi

# Step 2: Test AWS configuration and parameter access
if [[ "$SKIP_TESTS" != true ]]; then
    print_message "header" "Step 2: Testing AWS Configuration and Parameter Access"
    print_message "info" "Running test-parameter-access.sh..."
    
    if [ ! -x "${BASE_DIR}/test-parameter-access.sh" ]; then
        chmod +x "${BASE_DIR}/test-parameter-access.sh"
    fi
    
    if ! "${BASE_DIR}/test-parameter-access.sh" $REGION_ARG; then
        print_message "error" "AWS configuration or parameter access test failed."
        print_message "info" "Please fix the issues above before continuing with the migration."
        print_message "info" "If parameters do not exist yet, you can run this script with --skip-tests."
        exit 1
    fi
else
    print_message "warning" "Skipping AWS configuration and parameter access tests as requested."
fi

# Step 3: Set up parameters in AWS SSM
print_message "header" "Step 3: Setting Up Parameters in AWS SSM"
print_message "info" "Running setup-all-parameters.sh..."

if [ ! -x "${BASE_DIR}/setup-all-parameters.sh" ]; then
    chmod +x "${BASE_DIR}/setup-all-parameters.sh"
fi

SETUP_CMD="${BASE_DIR}/setup-all-parameters.sh"
if [[ -n "$REGION_ARG" ]]; then
    SETUP_CMD="$SETUP_CMD $REGION_ARG"
fi
if [[ -n "$OVERWRITE_ARG" ]]; then
    SETUP_CMD="$SETUP_CMD $OVERWRITE_ARG"
fi

if ! eval "$SETUP_CMD"; then
    print_message "error" "Parameter setup failed."
    print_message "info" "Please check the error messages above and fix the issues before continuing."
    exit 1
fi

# Step 4: Verify parameters and clean up .env files
print_message "header" "Step 4: Verifying Parameters and Cleaning Up"

if [ ! -x "${BASE_DIR}/verify-and-cleanup.sh" ]; then
    chmod +x "${BASE_DIR}/verify-and-cleanup.sh"
fi

VERIFY_CMD="${BASE_DIR}/verify-and-cleanup.sh"
if [[ -n "$REGION_ARG" ]]; then
    VERIFY_CMD="$VERIFY_CMD $REGION_ARG"
fi

if [[ "$KEEP_ENV" == true ]]; then
    print_message "info" "Verification only mode - .env files will not be removed."
    print_message "info" "Running verification..."
    # In this case, we'll just verify without cleanup by creating a temporary copy
    # that doesn't have permission to delete files
    TEMP_VERIFY_SCRIPT="${BASE_DIR}/.verify-only-temp.sh"
    cp "${BASE_DIR}/verify-and-cleanup.sh" "$TEMP_VERIFY_SCRIPT"
    chmod +x "$TEMP_VERIFY_SCRIPT"
    # Modify the script to disable the actual removal
    sed -i.bak 's/rm "$env_file"/echo "Would remove $env_file (skipped as requested)"/g' "$TEMP_VERIFY_SCRIPT" 2>/dev/null || \
    sed -i '' 's/rm "$env_file"/echo "Would remove $env_file (skipped as requested)"/g' "$TEMP_VERIFY_SCRIPT"
    
    if ! eval "$TEMP_VERIFY_SCRIPT $REGION_ARG"; then
        print_message "error" "Parameter verification failed."
        print_message "info" "Please check the error messages above and fix the issues before continuing."
        rm -f "$TEMP_VERIFY_SCRIPT" "$TEMP_VERIFY_SCRIPT.bak" 2>/dev/null || true
        exit 1
    fi
    rm -f "$TEMP_VERIFY_SCRIPT" "$TEMP_VERIFY_SCRIPT.bak" 2>/dev/null || true
else
    print_message "info" "Running verification and cleanup..."
    if ! eval "$VERIFY_CMD"; then
        print_message "error" "Parameter verification or cleanup failed."
        print_message "info" "Please check the error messages above and fix the issues before continuing."
        exit 1
    fi
fi

# Step 5: Final summary
print_message "header" "Migration Complete!"
print_message "success" "All environment variables have been successfully migrated to AWS SSM Parameter Store."
print_message "info" "To deploy using the new parameters:"
echo "- Deploy all modules: ./aws/sit/script/deploy_module.sh all"
echo "- Deploy a specific module: ./aws/sit/script/deploy_module.sh [module_name]"
echo ""
print_message "info" "For more information about the migration, see README-SSM-MIGRATION.md"

if [[ "$KEEP_ENV" == true ]]; then
    print_message "warning" "The .env files have been kept as requested. You can remove them manually later."
fi

print_message "success" "Migration process completed successfully!"

