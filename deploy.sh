#!/bin/bash
#
# TODO:
# 	- gh option

usage() {
	echo -e "Usage: $0 [OPTIONS]\n
OIDC Bootstrapper - Deploy AWS infrastructure for Terraform with GitHub Actions OIDC\n
Options:\n
-e string \t Set the environment name. By default its the current branch.
          \t This also set the branch that is allowed to assume the OIDC role.
-n string \t Set the prefix name. By default its the current repository name.
-r string \t Set the region to deploy. By default us-west-2.
-o string \t Set the GitHub Actions Organization owner.
-g        \t Automatically set the Github Actions variable. Requires gh to be properly working.
-t string \t Set the terraform directory. If specified, tfvars file will be created together with main.tf.
-b string \t Set the terraform backend directory. If specified, backend files will be copied there.
-p string \t Set the repository name.
-i        \t Dont include the automatic detection and creation of the Github Provider.
-u        \t Generate CloudFormation console URLs instead of deploying (no AWS CLI required).
--template-base-url string \t Base URL for GitHub templates (default: auto-detected from git repo).
--template-version string \t Git tag/branch for template version (default: main).
--dry-run \t Show what would be deployed without making changes.
-y, --yes \t Skip confirmation prompt (useful when piping from curl).
-w, --workflow \t Download sample GitHub Actions workflow to .github/workflows/terraform.yml.
-h, --help\t Show this help message.\n
Examples:\n
  # Deploy with AWS CLI (requires AWS access)
  $0 -e production -r us-east-1 -g

  # Generate CloudFormation console URLs (no AWS CLI required)
  $0 -u -e production -r us-east-1

  # Use specific template version
  $0 -u --template-version v1.0.0 -e staging

  # Use custom template repository
  $0 -u --template-base-url https://raw.githubusercontent.com/myorg/my-oidc-templates/main

  # Dry run to see what would be deployed
  $0 --dry-run -e production
" 1>&2
	exit $1
}
# Defaults
REGION=""
CURRENT_REPO=$(git remote get-url origin | sed -n 's/.*\/\(.*\).git/\1/p')
CURRENT_ORG=$(git remote get-url origin | sed -n 's/.*:\(.*\)\/.*.git/\1/p')
CURRENT_BRANCH="$(git branch --show-current)"

ORG=$CURRENT_ORG
INFRA_NAME=${CURRENT_REPO/./-}
ENVIRONMENT=$CURRENT_BRANCH
REPO=$CURRENT_REPO
I="true"
CONSOLE_URL="false"
TEMPLATE_S3_HTTP_URL="https://oidc-bootstrapper.s3.us-east-1.amazonaws.com"
TEMPLATE_S3_URL="s3://oidc-bootstrapper"
GITHUB_URL="https://raw.githubusercontent.com/MarioMoura/oidc-bootstrapper/refs/heads/main"
TEMPLATE_VERSION="main"
DRY_RUN="false"
SKIP_CONFIRM="false"
WORKFLOW="false"

# Parse arguments
while [[ $# -gt 0 ]]; do
	case $1 in
		-h | --help)
			usage 0
			;;
		-t)
			TERRAFORM_DIR="$2"
			shift 2
			;;
		-b)
			BACKEND_DIR="$2"
			shift 2
			;;
		-r)
			REGION="$2"
			shift 2
			;;
		-g)
			G="true"
			shift
			;;
		-e)
			ENVIRONMENT="$2"
			shift 2
			;;
		-n)
			INFRA_NAME="$2"
			shift 2
			;;
		-o)
			ORG="$2"
			shift 2
			;;
		-p)
			REPO="$2"
			shift 2
			;;
		-i)
			I="false"
			shift
			;;
		-u)
			CONSOLE_URL="true"
			shift
			;;
		--template-base-url)
			TEMPLATE_BASE_URL="$2"
			shift 2
			;;
		--template-version)
			TEMPLATE_VERSION="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN="true"
			shift
			;;
		-y | --yes)
			SKIP_CONFIRM="true"
			shift
			;;
		-w | --workflow)
			WORKFLOW="true"
			shift
			;;
		*)
			echo "Unknown option $1"
			usage 1
			;;
	esac
done

# URL encoding function
url_encode() {
	local string="${1}"
	local strlen=${#string}
	local encoded=""
	local pos c o

	for ((pos = 0; pos < strlen; pos++)); do
		c=${string:$pos:1}
		case "$c" in
			[-_.~a-zA-Z0-9]) o="${c}" ;;
			*) printf -v o '%%%02x' "'$c" ;;
		esac
		encoded+="${o}"
	done
	echo "${encoded}"
}

# Generate CloudFormation console URL
generate_console_url() {
	local template_name="$1"
	local stack_name="$2"
	local region="$3"
	shift 3

	local template_url="${TEMPLATE_S3_HTTP_URL}/${template_name}"
	local encoded_template_url=$(url_encode "$template_url")
	local encoded_stack_name=$(url_encode "$stack_name")

	local base_url="https://${region}.console.aws.amazon.com/cloudformation/home?region=${region}#/stacks/create/review"
	local url="${base_url}?templateURL=${encoded_template_url}&stackName=${encoded_stack_name}"

	# Add parameters
	while [[ $# -gt 0 ]]; do
		local param_name="$1"
		local param_value="$2"
		local encoded_param_value=$(url_encode "$param_value")
		url="${url}&param_${param_name}=${encoded_param_value}"
		shift 2
	done

	echo "$url"
}

# Skip AWS CLI checks if generating console URLs
if [ "$CONSOLE_URL" = "false" ]; then
	# Use AWS CLI to get current region if not specified
	if [ -z "$REGION" ]; then
		REGION=$(aws configure get region 2>/dev/null || echo "us-west-2")
	fi
	CURRENT_ACCOUNT="$(aws sts get-caller-identity | jq -r '.Account')"
	if [ -z "$CURRENT_ACCOUNT" ]; then
		echo "No account found"
		exit 1
	fi
else
	# When generating console URLs, region must be explicitly specified
	if [ -z "$REGION" ] && [ -z "$(echo "$*" | grep -E "\-r|\-\-region")" ]; then
		echo "Error: When using -u (console URLs), you must specify a region with -r"
		echo "Example: $0 -u -r us-east-1 -e production"
		exit 1
	fi
	# When generating console URLs, assume we don't have AWS CLI access
	CURRENT_ACCOUNT="<NEED TO BE SET MANUALLY>"
fi

# by default set as the given environment
ALLOWEDBRANCH=$ENVIRONMENT
REPONAME="$ORG/$REPO"

# OICD Audience
AUDIENCE="sts.amazonaws.com"

# Git Actions Host
if [ "$CONSOLE_URL" = "false" ]; then
	HOST=$(curl -s https://vstoken.actions.githubusercontent.com/.well-known/openid-configuration |
		jq -r '.jwks_uri | split("/")[2]')
else
	# Use the known GitHub Actions host for console URLs
	HOST="token.actions.githubusercontent.com"
fi

# Use the same account variable for consistency

# Apply/Target Role
TARGETROLE="${INFRA_NAME,,}-${ENVIRONMENT}-terraform-target-role"

BUCKETNAME="${INFRA_NAME,,}-${ENVIRONMENT}-tf-state"
TABLENAME="${INFRA_NAME,,}-${ENVIRONMENT}-terraform-dblock"

# Target Stack
TARGET_TEMPLATE_HTTP="${TEMPLATE_S3_HTTP_URL}/TargetAccount.yaml"
STACK_NAME="${INFRA_NAME}-${ENVIRONMENT}-terraform-OIDC-target-stack"

# Skip AWS provider check when generating console URLs
if [ "$CONSOLE_URL" = "false" ] && [ "$I" == "true" ]; then
	echo -n "Checking if provider exists...  "
	if aws iam list-open-id-connect-providers | jq -r '.OpenIDConnectProviderList[].Arn' | grep -q 'token.actions.githubusercontent.com'; then
		echo "Provider exists !"
	else
		echo "Provider missing !"
		echo "Downloading and running provider.sh from GitHub..."
		PROVIDER_SCRIPT_URL="${GITHUB_URL}/provider.sh"
		curl -s "$PROVIDER_SCRIPT_URL" | bash
	fi
fi

echo "Review:"
echo "Environment = ${ENVIRONMENT}"
echo "Branch = ${ALLOWEDBRANCH}"
echo "Prefix = ${INFRA_NAME}"
echo "Repository = ${REPONAME}"
echo "Region = ${REGION}"
echo "Account = ${CURRENT_ACCOUNT}"
echo "Stack Name = ${STACK_NAME}"
echo "Target Role = ${TARGETROLE}"

if [ "$CONSOLE_URL" = "true" ]; then
	# Generate console URLs instead of deploying
	echo
	echo "=== CloudFormation Console URLs ==="
	echo

	# Generate OIDC Provider URL (if needed)
	if [ "$I" = "true" ]; then
		echo "1. OIDC Provider Stack (deploy this first in us-east-1):"
		PROVIDER_URL=$(generate_console_url "GlobalProvider.yaml" "github-OIDC-provider" "us-east-1" \
			"OIDCDOMAIN" "$HOST" \
			"Audience" "$AUDIENCE" \
			"Thumbprint" "6938fd4d98bab03faadb97b34396831e3780aea1")
		echo "   $PROVIDER_URL"
		echo
	fi

	# Generate Target Account URL
	echo "2. Target Account Stack (deploy this in $REGION):"
	TARGET_URL=$(generate_console_url "TargetAccount.yaml" "$STACK_NAME" "$REGION" \
		"AllowedBranch" "$ALLOWEDBRANCH" \
		"RepositoryName" "$REPONAME" \
		"OIDCDOMAIN" "$HOST" \
		"Audience" "$AUDIENCE" \
		"TFStateLockTableName" "$TABLENAME" \
		"TFStateBucketName" "$BUCKETNAME" \
		"TargetRoleName" "$TARGETROLE")
	echo "   $TARGET_URL"
	echo

	echo "=== Configuration Details ==="
	echo "Template Base URL: ${TEMPLATE_BASE_URL:-Auto-detected from git repository}"
	echo "Template Version: $TEMPLATE_VERSION"
	echo "Environment: $ENVIRONMENT"
	echo "Repository: $REPONAME"
	echo "Region: $REGION"
	echo "Bucket Name: $BUCKETNAME"
	echo "DynamoDB Table: $TABLENAME"
	echo "IAM Role: $TARGETROLE"
	echo
	echo "After deployment, your role ARN will be:"
	echo "arn:aws:iam::<your-account-id>:role/$TARGETROLE"
	echo
	echo "Backend configuration file content:"
	echo "bucket = \"$BUCKETNAME\""
	echo "dynamodb_table = \"$TABLENAME\""
	echo "key = \"terraform.tfstate\""
	echo "region = \"$REGION\""

else
	# Regular AWS deployment mode
	if [ "$DRY_RUN" = "true" ]; then
		echo "=== DRY RUN MODE ==="
		echo "The following would be deployed:"
		echo
	fi

	if [ "$SKIP_CONFIRM" = "false" ]; then
		read -r -p "Are you sure? [y/N] " response
		case "$response" in
			[yY][eE][sS] | [yY]) ;;
			*)
				exit 1
				;;
		esac
	else
		echo "Skipping confirmation (--yes flag provided)"
	fi

	if [ "$DRY_RUN" = "true" ]; then
		echo "DRY RUN: Would execute CloudFormation deployment with the above parameters"
		exit 0
	fi

	# Download template temporarily
	echo "Downloading CloudFormation template..."
	TEMP_TEMPLATE="/tmp/TargetAccount-${RANDOM}.yaml"
	curl -s "$TARGET_TEMPLATE_HTTP" -o "$TEMP_TEMPLATE"

	aws \
	cloudformation deploy \
	--stack-name "$STACK_NAME" \
	--capabilities CAPABILITY_NAMED_IAM \
	--template-file "$TEMP_TEMPLATE" \
	--region "$REGION" \
	--parameter-overrides \
	AllowedBranch=$ALLOWEDBRANCH \
	RepositoryName=$REPONAME \
	OIDCDOMAIN="$HOST" \
	Audience=$AUDIENCE \
	TFStateLockTableName=$TABLENAME \
	TFStateBucketName=$BUCKETNAME \
	TargetRoleName=$TARGETROLE

	# Clean up temporary file
	rm -f "$TEMP_TEMPLATE"

	echo "$RES_TARGET_ROLE"
	echo
fi

# Generate backend configuration files for both modes
RES_TARGET_ROLE="arn:aws:iam::${CURRENT_ACCOUNT}:role/$TARGETROLE"
RES_BUCKET=$BUCKETNAME
RES_TABLENAME=$TABLENAME

echo "Generating backend configuration file: $ENVIRONMENT.s3.tfbackend"
echo "bucket = \"$RES_BUCKET\"
dynamodb_table = \"$RES_TABLENAME\"
key            = \"terraform.tfstate\"
region         = \"$REGION\"" >$ENVIRONMENT.s3.tfbackend

if [ "$BACKEND_DIR" ]; then
	echo "bucket = \"$RES_BUCKET\"
dynamodb_table = \"$RES_TABLENAME\"
key            = \"terraform.tfstate\"
region         = \"$REGION\"" >$BACKEND_DIR/$ENVIRONMENT.s3.tfbackend
fi

if [ "$TERRAFORM_DIR" ]; then
	curl -s "${GITHUB_URL}/sample_main.tf" -o "$TERRAFORM_DIR/main.tf"
	curl -s "${GITHUB_URL}/sample_variables.tf" -o "$TERRAFORM_DIR/variables.tf"
	>$TERRAFORM_DIR/$ENVIRONMENT.tfvars
fi

if [ "$WORKFLOW" = "true" ]; then
	echo "Downloading sample GitHub Actions workflow..."
	mkdir -p .github/workflows
	curl -s "${GITHUB_URL}/sample_workflow.yml" -o ".github/workflows/terraform.yml"
	echo "GitHub Actions workflow installed at: .github/workflows/terraform.yml"
fi
# Replacing dashes for underscores in gh actions
ENVIRONMENT=${ENVIRONMENT//-/_}

if [ "$G" ]; then
	if gh variable list | grep OIDC_CONF; then
		CURRENT=$(gh variable get OIDC_CONF)
	else
		CURRENT='{}'
	fi
	OIDC_CONF=$(echo "$CURRENT" | jq -r \
		--arg ROLE "$RES_TARGET_ROLE" \
		--arg REGION "$REGION" \
		--arg ENVIRONMENT "$ENVIRONMENT" \
		'. += {($ENVIRONMENT): {"role":$ROLE,"region":$REGION}}')
	echo "$OIDC_CONF"
	gh variable set OIDC_CONF --body "$OIDC_CONF"
else
	echo
	echo "Merge the following entry to OIDC_CONF on github, using the -g options is recommended"
	echo "{}" | jq -r \
		--arg ROLE "$RES_TARGET_ROLE" \
		--arg REGION "$REGION" \
		--arg ENVIRONMENT "$ENVIRONMENT" \
		'. += {($ENVIRONMENT): {"role":$ROLE,"region":$REGION}}'
fi
