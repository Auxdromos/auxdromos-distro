#!/bin/bash
# Script to make all parameter setup and verification scripts executable
# This is the first step in the migration process from .env files to AWS SSM Parameter Store

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
    else
        echo -e "$message"
    fi
}

# List of scripts to make executable
declare -a SCRIPTS=(
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
)

echo "===================================================="
echo "Making Parameter Migration Scripts Executable"
echo "===================================================="

# Counter for success/failure tracking
success_count=0
failure_count=0

# Process each script
for script in "${SCRIPTS[@]}"; do
    full_path="${BASE_DIR}/${script}"
    
    if [ -f "$full_path" ]; then
        # Make the script executable
        if chmod +x "$full_path"; then
            print_message "success" "Made executable: $script"
            ((success_count++))
        else
            print_message "error" "Failed to make executable: $script"
            ((failure_count++))
        fi
    else
        print_message "error" "Script not found: $script"
        ((failure_count++))
    fi
done

# Summary
echo "===================================================="
if [ $failure_count -eq 0 ]; then
    print_message "success" "All scripts ($success_count) are now executable!"
    echo ""
    print_message "info" "You can now proceed with the migration process:"
    echo "1. First, run ./setup-all-parameters.sh to set up all parameters"
    echo "2. Then, run ./verify-and-cleanup.sh to verify the migration"
    echo "3. Finally, update your deployment to use the new parameters"
else
    print_message "warning" "Made $success_count scripts executable, but encountered $failure_count issues."
    echo ""
    print_message "info" "Please check the error messages above and ensure all scripts exist."
fi
echo "===================================================="

