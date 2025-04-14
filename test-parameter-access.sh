#!/bin/bash
# Script to test access to AWS Systems Manager Parameter Store
# This helps verify AWS configuration and permissions before running deployments

# Exit if any command fails
set -e

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parameter paths to test
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

# Test parameters for each path
declare -A TEST_PARAMS
TEST_PARAMS["/auxdromos/sit/global"]="AWS_DEFAULT_REGION"
TEST_PARAMS["/auxdromos/sit/script"]="MODULE_ORDER"
TEST_PARAMS["/auxdromos/sit/config"]="EXTERNAL_PORT"
TEST_PARAMS["/auxdromos/sit/backend"]="EXTERNAL_PORT"
TEST_PARAMS["/auxdromos/sit/gateway"]="EXTERNAL_PORT"
TEST_PARAMS["/auxdromos/sit/idp"]="EXTERNAL_PORT"
TEST_PARAMS["/auxdromos/sit/keycloak"]="EXTERNAL_PORT"
TEST_PARAMS["/auxdromos/sit/rdbms"]="EXTERNAL_PORT"

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

# Function to test AWS config
test_aws_config() {
    print_message "info" "Testing AWS configuration..."
    
    # Test AWS CLI installation
    if ! command -v aws &> /dev/null; then
        print_message "error" "AWS CLI is not installed. Please install it first."
        echo "Visit https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html for installation instructions."
        return 1
    fi
    print_message "success" "AWS CLI is installed"
    
    # Test jq installation
    if ! command -v jq &> /dev/null; then
        print_message "error" "jq is not installed. Please install it first."
        echo "Visit https://stedolan.github.io/jq/download/ for installation instructions."
        return 1
    fi
    print_message "success" "jq is installed"
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_message "error" "AWS credentials are not configured or are invalid."
        echo "Configure AWS credentials using one of these methods:"
        echo "1. Run 'aws configure' to set up credentials"
        echo "2. Set the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables"
        echo "3. Configure an AWS CLI profile and set AWS_PROFILE environment variable"
        return 1
    fi
    
    # Get caller identity for display
    local caller_identity=$(aws sts get-caller-identity --query 'Arn' --output text)
    print_message "success" "AWS credentials are valid: $caller_identity"
    
    # Check AWS region
    if [[ -z "${AWS_DEFAULT_REGION}" ]]; then
        if [[ -z "${AWS_REGION}" ]]; then
            # Try to get region from config
            local configured_region=$(aws configure get region 2>/dev/null)
            if [[ -z "${configured_region}" ]]; then
                print_message "warning" "AWS region is not configured. Using 'us-east-1' as default."
                export AWS_DEFAULT_REGION="us-east-1"
            else
                print_message "info" "Using configured region from AWS CLI profile: ${configured_region}"
                export AWS_DEFAULT_REGION="${configured_region}"
            fi
        else
            print_message "info" "Using AWS_REGION from environment: ${AWS_REGION}"
            export AWS_DEFAULT_REGION="${AWS_REGION}"
        fi
    else
        print_message "info" "Using AWS_DEFAULT_REGION from environment: ${AWS_DEFAULT_REGION}"
    fi
    
    print_message "success" "AWS configuration valid. Using region: ${AWS_DEFAULT_REGION}"
    return 0
}

# Function to test parameter path access
test_parameter_path() {
    local path=$1
    local param_name=$2
    
    echo ""
    echo "Testing access to path: $path"
    
    # Test if path exists and we can list parameters
    local list_result=$(aws ssm get-parameters-by-path --path "$path" --query 'Parameters[].Name' --output json --region "${AWS_DEFAULT_REGION}" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        print_message "error" "Failed to access parameter path: $path"
        echo "Error details: $list_result"
        return 1
    fi
    
    # Check if parameters exist in path
    local param_count=$(echo "$list_result" | jq 'length')
    
    if [ "$param_count" -eq 0 ]; then
        print_message "error" "No parameters found in path: $path"
        echo "Parameters need to be created in this path. Run setup scripts first."
        return 1
    fi
    
    print_message "success" "Found $param_count parameters in $path"
    
    # Test specific parameter access if provided
    if [ -n "$param_name" ]; then
        local full_param_name="${path}/${param_name}"
        echo "Testing access to specific parameter: $full_param_name"
        
        local param_result=$(aws ssm get-parameter --name "$full_param_name" --query 'Parameter.Value' --output text --region "${AWS_DEFAULT_REGION}" 2>&1)
        local param_exit_code=$?
        
        if [ $param_exit_code -ne 0 ]; then
            print_message "error" "Failed to access parameter: $full_param_name"
            echo "Error details: $param_result"
            return 1
        fi
        
        if [ -z "$param_result" ] || [ "$param_result" == "None" ]; then
            print_message "warning" "Parameter $full_param_name exists but has no value"
        else
            print_message "success" "Successfully accessed parameter: $full_param_name"
        fi
    fi
    
    return 0
}

# Main execution
echo "===================================================="
echo "AWS Systems Manager Parameter Store Access Test"
echo "===================================================="

# First test AWS configuration
if ! test_aws_config; then
    print_message "error" "AWS configuration test failed. Please fix the issues before continuing."
    exit 1
fi

# Initialize counters for summary
path_success=0
path_failure=0
param_success=0
param_failure=0

# Test each parameter path
for path in "${PARAM_PATHS[@]}"; do
    test_param="${TEST_PARAMS[$path]}"
    
    if test_parameter_path "$path" "$test_param"; then
        ((path_success++))
        ((param_success++))
    else
        ((path_failure++))
        ((param_failure++))
    fi
done

# Print summary
echo ""
echo "===================================================="
echo "Test Summary"
echo "===================================================="
if [ $path_failure -eq 0 ] && [ $param_failure -eq 0 ]; then
    print_message "success" "All tests passed! You have access to all required parameters."
    echo ""
    print_message "info" "You can proceed with deployment using the following commands:"
    echo "- To deploy all modules: ./aws/sit/script/deploy_module.sh all"
    echo "- To deploy a specific module: ./aws/sit/script/deploy_module.sh [module_name]"
else
    print_message "error" "Some tests failed. See details above."
    echo ""
    print_message "info" "Troubleshooting steps:"
    echo "1. Verify your AWS credentials have appropriate permissions to access SSM Parameter Store"
    echo "2. Ensure parameters have been created using the setup scripts:"
    echo "   ./setup-all-parameters.sh --overwrite"
    echo "3. Check that you're using the correct AWS region:"
    echo "   export AWS_DEFAULT_REGION=us-east-1  # Replace with your region"
    echo "4. Verify network connectivity to AWS services"
    echo ""
    print_message "info" "For more details about the migration process, see README-SSM-MIGRATION.md"
fi

# Exit with appropriate code
if [ $path_failure -gt 0 ] || [ $param_failure -gt 0 ]; then
    exit 1
else
    exit 0
fi

