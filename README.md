# OIDC Bootstrapper

A comprehensive tool to bootstrap AWS infrastructure for secure, credential-free Terraform deployments using GitHub Actions OIDC authentication.

## Overview

This tool automates the setup of:
- **OIDC Provider** for secure GitHub Actions authentication
- **IAM Role** with environment and repository-specific permissions
- **S3 Bucket** for Terraform state storage with versioning and encryption
- **DynamoDB Table** for Terraform state locking
- **Backend Configuration Files** for immediate Terraform use
- **GitHub Actions Variables** for automated workflows

## Features

✅ **Zero AWS Credentials in GitHub** - Uses OIDC for secure, temporary access
✅ **Environment Isolation** - Separate roles per environment/branch
✅ **Remote Templates** - No local files required, works as standalone script
✅ **Console URLs** - Generate deployment links without AWS CLI access
✅ **Automated Setup** - One command creates everything needed for Terraform

## Installation & Usage

### Option 1: Standalone Execution (Recommended)

Execute directly from GitHub without downloading:

```bash
# Generate CloudFormation console URLs (no AWS CLI required)
curl -s https://raw.githubusercontent.com/MarioMoura/oidc-bootstrapper/main/deploy.sh | \
  bash -s -- -u -r us-east-1 -e production

# Deploy directly with AWS CLI
curl -s https://raw.githubusercontent.com/MarioMoura/oidc-bootstrapper/main/deploy.sh | \
  bash -s -- -y -r us-east-1 -e production -g
```

### Option 2: Download and Execute

```bash
curl -O https://raw.githubusercontent.com/MarioMoura/oidc-bootstrapper/main/deploy.sh
chmod +x deploy.sh
./deploy.sh -h  # See all options
```

## Command Reference

### Basic Syntax
```bash
./deploy.sh [OPTIONS]
```

### Core Options

| Option | Description | Required | Example |
|--------|-------------|----------|---------|
| `-e <env>` | Environment name (also sets allowed branch) | ✅ | `-e production` |
| `-r <region>` | AWS region for deployment | ✅ | `-r us-east-1` |
| `-o <org>` | GitHub organization | Auto-detected | `-o mycompany` |
| `-p <repo>` | Repository name | Auto-detected | `-p my-app` |

### Deployment Modes

| Mode | Option | Description | AWS CLI Required |
|------|--------|-------------|-----------------|
| **Console URLs** | `-u` | Generate CloudFormation console links | ❌ No |
| **Direct Deploy** | *(default)* | Deploy via AWS CLI | ✅ Yes |
| **Dry Run** | `--dry-run` | Show what would be deployed | ✅ Yes |

### Additional Options

| Option | Description | Example |
|--------|-------------|---------|
| `-g` | Auto-set GitHub Actions variables (Highly recommended) | `-g` |
| `-t <dir>` | Download Terraform samples to directory | `-t ./terraform` |
| `-b <dir>` | Copy backend files to directory | `-b ./terraform/backend` |
| `-v <dir>` | Create tfvars files in directory | `-v ./terraform/vars` |
| `-y` | Skip confirmation (useful for piping) | `-y` |
| `-i` | Skip OIDC provider creation | `-i` |
| `--template-version <tag>` | Use specific template version | `--template-version v1.0.0` |

## Usage Examples

### Quick Start - Console URLs
Perfect for first-time users or sharing with team:

```bash
# Generate console URLs for production environment
curl -s https://raw.githubusercontent.com/MarioMoura/oidc-bootstrapper/main/deploy.sh | \
  bash -s -- -u -r us-east-1 -e production -o myorg -p myrepo
```
**Note**: the bootstrapper will try and get your org and repo from the remote `origin`, so most of the time you don't need to specify it.

### Production Deployment
Deploy infrastructure directly with GitHub integration:

```bash
# Deploy with automatic GitHub variable setup
curl -s https://raw.githubusercontent.com/MarioMoura/oidc-bootstrapper/main/deploy.sh | \
  bash -s -- -y -r us-east-1 -e production -g -t ./terraform -b ./terraform/backend -v ./terraform/vars
```

### Development Environment
Quick setup for development branch:

```bash
./deploy.sh -r us-west-2 -e development -g
```

### Multi-Region Setup
Deploy to different regions:

```bash
# Production in us-east-1
./deploy.sh -r us-east-1 -e production -g

# Staging in us-west-2
./deploy.sh -r us-west-2 -e staging -g
```

## What Gets Created

### AWS Resources

1. **OIDC Provider** (once per account, in us-east-1)
   - Enables GitHub Actions to assume AWS roles
   - Automatically created if not exists

2. **IAM Role** (per environment)
   - Name: `{prefix}-{environment}-terraform-target-role`
   - Policy: `AdministratorAccess`
   - Trust: Limited to specific repo and branch

3. **S3 Bucket** (per environment)
   - Name: `{prefix}-{environment}-tf-state`
   - Features: Versioning enabled, AES256 encryption

4. **DynamoDB Table** (per environment)
   - Name: `{prefix}-{environment}-terraform-dblock`
   - Purpose: Terraform state locking

### Local Files Generated

- **Backend Configuration**: `{environment}.s3.tfbackend`
- **Terraform Samples**: `main.tf`, `variables.tf`, `{environment}.tfvars` (if `-t` used)
- **Variables Files**: `{environment}.tfvars` (if `-v` used)

### GitHub Variables (if `-g` used)

- **OIDC_CONF**: JSON object with role ARNs and regions per environment

## Architecture

```
GitHub Actions Workflow
           ↓ (OIDC Token)
    AWS OIDC Provider
           ↓ (Assume Role)
  Environment-Specific IAM Role
           ↓ (Deploy Infrastructure)
    Your AWS Resources
```

## Security Model

- **No Long-term Credentials**: Uses OIDC tokens for temporary access
- **Least Privilege**: Roles limited to specific repositories and branches
- **Environment Isolation**: Separate roles per environment prevent cross-environment access
- **Temporary Access**: Tokens expire automatically

## Requirements

### For Direct Deployment
- AWS CLI configured with appropriate permissions
- `jq` for JSON processing
- `curl` for downloading templates

### For Console URL Generation
- No requirements! Works in any environment with `curl`

## Troubleshooting

### Common Issues

**"Invalid template path"**
```bash
# Solution: Ensure you have internet access to download templates
curl -s https://oidc-bootstrapper.s3.us-east-1.amazonaws.com/TargetAccount.yaml
```

**"No account found"**
```bash
# Solution: Configure AWS CLI or use console URL mode
aws configure
# OR
./deploy.sh -u -r us-east-1 -e production  # Use console URLs instead
```

**"Error: When using -u, you must specify a region"**
```bash
# Solution: Always specify region with console URL mode
./deploy.sh -u -r us-east-1 -e production
```

### Getting Help

```bash
# Show all options
./deploy.sh -h

# Dry run to see what would be created
./deploy.sh --dry-run -r us-east-1 -e production
```

## Advanced Usage

### Custom Templates
```bash
# Use your own template repository
./deploy.sh -u --template-base-url https://raw.githubusercontent.com/myorg/custom-templates/main
```

### Version Pinning
```bash
# Use specific stable version
./deploy.sh -u --template-version v1.2.0 -r us-east-1 -e production
```

### Integration with Existing Workflows
The tool integrates seamlessly with existing GitHub Actions:

```yaml
# .github/workflows/terraform.yml
- uses: MarioMoura/oidc-bootstrapper@main
  with:
    oidc-conf: ${{ vars.OIDC_CONF }}
```

## Next Steps

After running the bootstrapper:

1. **Verify Deployment**: Check AWS Console for created resources
2. **Test GitHub Actions**: Create a simple Terraform workflow
3. **Add Terraform Code**: Use generated backend configuration
4. **Scale Up**: Deploy additional environments as needed


