#!/bin/bash
# Rollback script to restore .env files and optionally remove parameters from AWS SSM
# This provides a safety net during the migration process

# Base directory
BASE_DIR="$(dirname "$(readlink -f "$0")")"
ENV_DIR="${BASE_DIR}/aws/sit/env"
BACKUP_DIR="${BASE_DIR}/backup/aws/sit/env"
DEPLOY_SCRIPT="${BASE_DIR}/aws/sit/script/deploy_module.sh"
DEPLOY_SCRIPT_BACKUP="${BASE_DIR}/backup/aws/sit/script/deploy_module.sh"

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default settings
AWS_REGION=""
KEEP_SSM=false
CUSTOM_BACKUP=""
DRY_RUN=false
CONFIRMED=false
exit_code=0

# Parameter paths to remove
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
    elif [[ "$msg_type" == "dry-run" ]]; then
        echo -e "${YELLOW}[DRY RUN] $message${NC}"
    else
        echo -e "$message"
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --keep-ssm             Keep parameters in AWS SSM Parameter Store"
    echo "  --region REGION        Specify AWS region (default: from AWS config or us-east-1)"
    echo "  --restore-backup-from DIR  Restore from a specific backup directory"
    echo "  --dry-run              Show what would be done without making changes"
    echo "  --confirm              Skip confirmation prompt"
    echo "  --help                 Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --region us-east-1 --keep-ssm"
    echo "  $0 --restore-backup-from backup/aws/sit/env-20250414 --dry-run"
}

# Process command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --keep-ssm)
            KEEP_SSM=true
            ;;
        --region)
            AWS_REGION="$2"
            shift
            ;;
        --restore-backup-from)
            CUSTOM_BACKUP="$2"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --confirm)
            CONFIRMED=true
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

# Build command-line args for AWS CLI
REGION_ARG=""
if [[ -n "$AWS_REGION" ]]; then
    REGION_ARG="--region $AWS_REGION"
    # Also set the environment variable for scripts that use it directly
    export AWS_DEFAULT_REGION="$AWS_REGION"
else
    # Try to get AWS region from environment or config
    if [[ -n "${AWS_DEFAULT_REGION}" ]]; then
        REGION_ARG="--region ${AWS_DEFAULT_REGION}"
    elif [[ -n "${AWS_REGION}" ]]; then
        REGION_ARG="--region ${AWS_REGION}"
        export AWS_DEFAULT_REGION="${AWS_REGION}"
    else
        # Try to get region from config
        local configured_region=$(aws configure get region 2>/dev/null)
        if [[ -n "${configured_region}" ]]; then
            REGION_ARG="--region ${configured_region}"
            export AWS_DEFAULT_REGION="${configured_region}"
        else
            print_message "warning" "AWS region not specified. Using us-east-1 as default."
            REGION_ARG="--region us-east-1"
            export AWS_DEFAULT_REGION="us-east-1"
        fi
    fi
fi

# Determine the backup directory to use
if [[ -n "$CUSTOM_BACKUP" ]]; then
    if [[ -d "$CUSTOM_BACKUP" ]]; then
        BACKUP_DIR="$CUSTOM_BACKUP"
        print_message "info" "Using custom backup directory: $BACKUP_DIR"
    else
        print_message "error" "Custom backup directory not found: $CUSTOM_BACKUP"
        exit 1
    fi
else
    if [[ ! -d "$BACKUP_DIR" ]]; then
        print_message "error" "Default backup directory not found: $BACKUP_DIR"
        print_message "info" "You can specify a custom backup directory with --restore-backup-from"
        exit 1
    fi
    print_message "info" "Using default backup directory: $BACKUP_DIR"
fi

# Display rollback details
print_message "header" "AWS SSM Migration Rollback"
print_message "info" "This script will roll back the migration to AWS SSM Parameter Store:"
echo ""
echo "  - Restore .env files from: $BACKUP_DIR"
if [[ "$KEEP_SSM" == true ]]; then
    echo "  - Keep parameters in AWS SSM Parameter Store"
else
    echo "  - Remove parameters from AWS SSM Parameter Store"
fi
if [[ -f "$DEPLOY_SCRIPT_BACKUP" ]]; then
    echo "  - Restore deploy_module.sh from backup"
fi
if [[ "$DRY_RUN" == true ]]; then
    echo "  - DRY RUN MODE: No changes will be made"
fi
echo ""

# Confirm rollback
if [[ "$CONFIRMED" != true && "$DRY_RUN" != true ]]; then
    read -p "Are you sure you want to proceed with the rollback? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_message "info" "Rollback cancelled."
        exit 0
    fi
fi

# Check AWS configuration if removing parameters
if [[ "$KEEP_SSM" != true ]]; then
    print_message "header" "Checking AWS Configuration"
    
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        print_message "error" "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_message "error" "AWS credentials are not configured or are invalid."
        print_message "info" "Run 'aws configure' to set up credentials or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."
        exit 1
    fi
    
    # Get caller identity for display
    local caller_identity=$(aws sts get-caller-identity --query 'Arn' --output text)
    print_message "success" "AWS credentials are valid: $caller_identity"
fi

# Rollback function for .env files
restore_env_files() {
    print_message "header" "Restoring Environment Files"
    
    # Check if backup directory exists and contains .env files
    local env_files=($(find "$BACKUP_DIR" -name "*.env" 2>/dev/null))
    local env_count=${#env_files[@]}
    
    if [ $env_count -eq 0 ]; then
        print_message "error" "No .env files found in backup directory: $BACKUP_DIR"
        return 1
    fi
    
    print_message "info" "Found $env_count .env files to restore"
    
    # Create target directory if it doesn't exist
    if [[ ! -d "$ENV_DIR" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            print_message "dry-run" "Would create directory: $ENV_DIR"
        else
            if ! mkdir -p "$ENV_DIR"; then
                print_message "error" "Failed to create directory: $ENV_DIR"
                return 1
            fi
            print_message "success" "Created directory: $ENV_DIR"
        fi
    fi
    
    # Restore each .env file
    for env_file in "${env_files[@]}"; do
        local file_name=$(basename "$env_file")
        local target_file="${ENV_DIR}/${file_name}"
        
        if [[ "$DRY_RUN" == true ]]; then
            print_message "dry-run" "Would restore file: $file_name to $target_file"
        else
            # Backup existing file if it exists
            if [[ -f "$target_file" ]]; then
                local timestamp=$(date +"%Y%m%d%H%M%S")
                if ! cp "$target_file" "${target_file}.${timestamp}.bak"; then
                    print_message "warning" "Failed to backup existing file: $target_file"
                fi
            fi
            
            # Copy file from backup
            if cp "$env_file" "$target_file"; then
                print_message "success" "Restored file: $file_name"
            else
                print_message "error" "Failed to restore file: $file_name"
            fi
        fi
    done
    
    if [[ "$DRY_RUN" != true ]]; then
        print_message "success" "Environment files restored successfully"
    fi
}

# Function to remove parameters from SSM
remove_ssm_parameters() {
    print_message "header" "Removing Parameters from AWS SSM Parameter Store"
    
    # Skip if keeping SSM parameters
    if [[ "$KEEP_SSM" == true ]]; then
        print_message "info" "Skipping parameter removal as requested"
        return 0
    fi
    
    # Check for each parameter path
    for path in "${PARAM_PATHS[@]}"; do
        print_message "info" "Processing parameters in path: $path"
        
        # Get all parameters in this path
        local params_json=$(aws ssm get-parameters-by-path --path "$path" --recursive --query 'Parameters[].Name' --output json $REGION_ARG 2>/dev/null)
        
        # Check if we got any parameters
        if [[ $? -ne 0 || -z "$params_json" || "$params_json" == "[]" ]]; then
            print_message "warning" "No parameters found in path: $path"
            continue
        fi
        
        # Count parameters
        local param_count=$(echo "$params_json" | jq 'length')
        print_message "info" "Found $param_count parameters in path: $path"
        
        # Process each parameter
        echo "$params_json" | jq -r '.[]' | while read -r param_name; do
            if [[ "$DRY_RUN" == true ]]; then
                print_message "dry-run" "Would delete parameter: $param_name"
            else
                if aws ssm delete-parameter --name "$param_name" $REGION_ARG &>/dev/null; then
                    print_message "success" "Deleted parameter: $param_name"
                else
                    print_message "error" "Failed to delete parameter: $param_name"
                fi
            fi
        done
    done
    
    if [[ "$DRY_RUN" != true ]]; then
        print_message "success" "Parameters removed from AWS SSM Parameter Store"
    fi
}

# Function to restore deploy_module.sh
restore_deploy_script() {
    print_message "header" "Restoring Deploy Script"
    
    # Check if backup exists
    if [[ ! -f "$DEPLOY_SCRIPT_BACKUP" ]]; then
        print_message "warning" "Deploy script backup not found: $DEPLOY_SCRIPT_BACKUP"
        print_message "info" "Skipping deploy script restoration"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        print_message "dry-run" "Would restore deploy script from: $DEPLOY_SCRIPT_BACKUP"
    else
        # Create directory if it doesn't exist
        local deploy_dir=$(dirname "$DEPLOY_SCRIPT")
        if [[ ! -d "$deploy_dir" ]]; then
            if ! mkdir -p "$deploy_dir"; then
                print_message "error" "Failed to create directory: $deploy_dir"
                return 1
            fi
        fi
        
        # Backup existing script if it exists
        if [[ -f "$DEPLOY_SCRIPT" ]]; then
            local timestamp=$(date +"%Y%m%d%H%M%S")
            if ! cp "$DEPLOY_SCRIPT" "${DEPLOY_SCRIPT}.${timestamp}.bak"; then
                print_message "warning" "Failed to backup existing deploy script"
            fi
        fi
        
        # Restore from backup
        if cp "$DEPLOY_SCRIPT_BACKUP" "$DEPLOY_SCRIPT"; then
            # Make executable
            chmod +x "$DEPLOY_SCRIPT"
            print_message "success" "Restored deploy script from backup"
        else
            print_message "error" "Failed to restore deploy script from backup"
        fi
    fi
}

# Execute rollback operations
restore_env_files
if [[ "$KEEP_SSM" != true ]]; then
    remove_ssm_parameters
fi
restore_deploy_script

# Print summary
print_message "header" "Rollback Summary"

if [[ "$DRY_RUN" == true ]]; then
    print_message "info" "This was a dry run. No changes were made."
    print_message "info" "Run without --dry-run to apply the changes."
    exit_code=0
else
    print_message "success" "Rollback completed successfully!"
    print_message "info" "Environment files have been restored from backup."
    
    if [[ "$KEEP_SSM" == true ]]; then
        print_message "info" "Parameters in AWS SSM Parameter Store have been preserved."
        print_message "info" "You can continue to use AWS SSM or revert to using .env files."
    else
        print_message "info" "Parameters in AWS SSM Parameter Store have been removed."
        print_message "info" "System is now configured to use only .env files."
    fi
    
    if [[ -f "$DEPLOY_SCRIPT_BACKUP" ]]; then
        print_message "info" "Deploy script has been restored to its pre-migration state."
    else
        print_message "warning" "Deploy script backup was not found. You may need to manually update it to use .env files."
    fi
    
    print_message "info" "Next steps:"
    echo "1. Verify the restored .env files in: $ENV_DIR"
    echo "2. Check the deploy script: $DEPLOY_SCRIPT"
    echo "3. Test deployments with the restored configuration:"
    echo "   ./aws/sit/script/deploy_module.sh config  # Test a single module"
    echo "   ./aws/sit/script/deploy_module.sh all     # Deploy all modules"
    
    # Check for any remaining issues
    local has_issues=false
    
    # Check if .env files were successfully restored
    if [[ ! -d "$ENV_DIR" ]] || [[ $(find "$ENV_DIR" -name "*.env" | wc -l) -eq 0 ]]; then
        print_message "error" "No .env files found in the environment directory after rollback."
        print_message "info" "You may need to manually restore .env files from: $BACKUP_DIR"
        has_issues=true
    fi
    
    # Check if deploy script was properly restored
    if [[ ! -f "$DEPLOY_SCRIPT" ]]; then
        print_message "error" "Deploy script not found after rollback: $DEPLOY_SCRIPT"
        has_issues=true
    elif [[ ! -x "$DEPLOY_SCRIPT" ]]; then
        print_message "warning" "Deploy script is not executable: $DEPLOY_SCRIPT"
        print_message "info" "Run: chmod +x $DEPLOY_SCRIPT"
        has_issues=true
    fi
    
    if [[ "$has_issues" == true ]]; then
        print_message "warning" "Some issues were detected after rollback. See messages above."
        exit_code=1
    else
        print_message "success" "System is ready for deployment using the restored .env files."
        exit_code=0
    fi
fi

exit $exit_code

