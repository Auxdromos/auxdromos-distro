#!/bin/bash
# Script to check permissions and ownership of migration-related files
# Run this before starting the migration to ensure all permissions are correctly set

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Base directory
BASE_DIR="$(dirname "$(readlink -f "$0")")"
ENV_DIR="${BASE_DIR}/aws/sit/env"
BACKUP_DIR="${BASE_DIR}/backup/aws/sit/env"

# Arrays for tracking issues
PERM_ISSUES=()
SUGGESTIONS=()

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

# Function to check script permissions
check_script_permissions() {
    print_message "header" "Checking Script Permissions"
    
    # List of scripts to check
    declare -a SCRIPTS=(
        "migrate-to-ssm.sh"
        "make-scripts-executable.sh"
        "setup-all-parameters.sh"
        "setup-global-parameters.sh"
        "setup-script-parameters.sh"
        "setup-config-parameters.sh"
        "setup-backend-parameters.sh"
        "setup-gateway-parameters.sh"
        "setup-idp-parameters.sh"
        "setup-keycloak-parameters.sh"
        "setup-rdbms-parameters.sh"
        "verify-and-cleanup.sh"
        "test-parameter-access.sh"
    )
    
    local all_executable=true
    for script in "${SCRIPTS[@]}"; do
        local script_path="${BASE_DIR}/${script}"
        
        if [ ! -f "$script_path" ]; then
            print_message "warning" "Script $script not found"
            continue
        fi
        
        # Check if script is executable
        if [ ! -x "$script_path" ]; then
            print_message "error" "Script $script is not executable"
            PERM_ISSUES+=("$script is not executable")
            SUGGESTIONS+=("chmod +x ${BASE_DIR}/${script}")
            all_executable=false
        else
            print_message "success" "Script $script is executable"
        fi
        
        # Check ownership
        local owner=$(stat -c "%U" "$script_path" 2>/dev/null || stat -f "%Su" "$script_path")
        local current_user=$(whoami)
        
        if [ "$owner" != "$current_user" ]; then
            print_message "warning" "Script $script is owned by $owner, current user is $current_user"
            PERM_ISSUES+=("$script is owned by $owner, not by current user $current_user")
            SUGGESTIONS+=("chown $current_user ${BASE_DIR}/${script}")
        fi
        
        # Check group permissions (only warn if group can't execute)
        local group_perms=$(stat -c "%A" "$script_path" 2>/dev/null || stat -f "%Sp" "$script_path")
        if [[ "$group_perms" != *"x"* ]]; then
            print_message "warning" "Script $script doesn't have group execute permissions"
            PERM_ISSUES+=("$script doesn't have group execute permissions")
            SUGGESTIONS+=("chmod g+x ${BASE_DIR}/${script}")
        fi
    done
    
    if [ "$all_executable" = true ]; then
        print_message "success" "All scripts have executable permissions"
    fi
}

# Function to check backup directory permissions
check_backup_permissions() {
    print_message "header" "Checking Backup Directory Permissions"
    
    # Check if backup directory exists
    if [ -d "$BACKUP_DIR" ]; then
        print_message "info" "Backup directory exists: $BACKUP_DIR"
        
        # Check write permissions
        if [ -w "$BACKUP_DIR" ]; then
            print_message "success" "Backup directory is writable"
        else
            print_message "error" "Backup directory is not writable"
            PERM_ISSUES+=("Backup directory $BACKUP_DIR is not writable")
            SUGGESTIONS+=("chmod u+w $BACKUP_DIR")
        fi
    else
        print_message "info" "Backup directory does not exist: $BACKUP_DIR"
        
        # Check if parent directories exist and are writable
        local parent_dir=$(dirname "$BACKUP_DIR")
        while [ ! -d "$parent_dir" ] && [ "$parent_dir" != "/" ]; do
            parent_dir=$(dirname "$parent_dir")
        done
        
        if [ -w "$parent_dir" ]; then
            print_message "success" "Parent directory $parent_dir is writable, backup directory can be created"
        else
            print_message "error" "Cannot create backup directory, parent directory $parent_dir is not writable"
            PERM_ISSUES+=("Parent directory $parent_dir is not writable, cannot create backup directory")
            SUGGESTIONS+=("mkdir -p $BACKUP_DIR && chmod u+w $BACKUP_DIR")
        fi
    fi
}

# Function to check env file permissions
check_env_file_permissions() {
    print_message "header" "Checking Environment File Permissions"
    
    # Check if env directory exists
    if [ ! -d "$ENV_DIR" ]; then
        print_message "warning" "Environment directory not found: $ENV_DIR"
        return
    fi
    
    # Find all .env files
    local env_files=($(find "$ENV_DIR" -name "*.env" 2>/dev/null))
    local env_count=${#env_files[@]}
    
    if [ $env_count -eq 0 ]; then
        print_message "warning" "No .env files found in $ENV_DIR"
        return
    fi
    
    print_message "info" "Found $env_count .env files to check"
    
    local all_readable=true
    for env_file in "${env_files[@]}"; do
        # Check if file is readable
        if [ -r "$env_file" ]; then
            print_message "success" "File $(basename "$env_file") is readable"
        else
            print_message "error" "File $(basename "$env_file") is not readable"
            PERM_ISSUES+=("Environment file $env_file is not readable")
            SUGGESTIONS+=("chmod u+r $env_file")
            all_readable=false
        fi
    done
    
    if [ "$all_readable" = true ]; then
        print_message "success" "All environment files are readable"
    fi
}

# Function to check deploy script permissions
check_deploy_script_permissions() {
    print_message "header" "Checking Deploy Script Permissions"
    
    local deploy_script="${BASE_DIR}/aws/sit/script/deploy_module.sh"
    
    if [ ! -f "$deploy_script" ]; then
        print_message "warning" "Deploy script not found: $deploy_script"
        return
    fi
    
    # Check if script is executable
    if [ ! -x "$deploy_script" ]; then
        print_message "error" "Deploy script is not executable"
        PERM_ISSUES+=("Deploy script $deploy_script is not executable")
        SUGGESTIONS+=("chmod +x $deploy_script")
    else
        print_message "success" "Deploy script is executable"
    fi
    
    # Check ownership
    local owner=$(stat -c "%U" "$deploy_script" 2>/dev/null || stat -f "%Su" "$deploy_script")
    local current_user=$(whoami)
    
    if [ "$owner" != "$current_user" ]; then
        print_message "warning" "Deploy script is owned by $owner, current user is $current_user"
        PERM_ISSUES+=("Deploy script is owned by $owner, not by current user $current_user")
        SUGGESTIONS+=("chown $current_user $deploy_script")
    fi
}

# Function to check Docker permissions if needed for deployment
check_docker_permissions() {
    print_message "header" "Checking Docker Permissions"
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        print_message "warning" "Docker is not installed. Skipping Docker permission checks."
        return
    fi
    
    # Check if current user can run Docker commands
    if docker info &> /dev/null; then
        print_message "success" "Current user can run Docker commands"
    else
        print_message "error" "Current user cannot run Docker commands"
        PERM_ISSUES+=("Current user cannot run Docker commands")
        SUGGESTIONS+=("Add user to the docker group: sudo usermod -aG docker $(whoami)")
    fi
}

# Run all checks
check_script_permissions
check_backup_permissions
check_env_file_permissions
check_deploy_script_permissions
check_docker_permissions

# Print summary
print_message "header" "Permission Check Summary"

if [ ${#PERM_ISSUES[@]} -eq 0 ]; then
    print_message "success" "No permission issues found! You can proceed with the migration."
    print_message "info" "Run ./migrate-to-ssm.sh to start the migration process."
else
    print_message "warning" "Found ${#PERM_ISSUES[@]} permission issues that should be addressed:"
    
    for i in "${!PERM_ISSUES[@]}"; do
        echo -e "${RED}${i+1}. ${PERM_ISSUES[$i]}${NC}"
        echo -e "${GREEN}   Fix: ${SUGGESTIONS[$i]}${NC}"
        echo ""
    done
    
    print_message "info" "You can fix all issues with the following commands:"
    echo ""
    for suggestion in "${SUGGESTIONS[@]}"; do
        echo "$suggestion"
    done
    echo ""
    print_message "info" "After fixing these issues, run this script again to verify."
fi

