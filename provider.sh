#!/bin/bash
#
# TODO:
# 	- getopts
# 	- gh option

###############################
####### Configuration #########
###############################

# OICD Audience
AUDIENCE="sts.amazonaws.com"
REGION="us-east-1"

# Git Actions Host
HOST=$(curl -s https://vstoken.actions.githubusercontent.com/.well-known/openid-configuration \
| jq -r '.jwks_uri | split("/")[2]')

# Git Actions Thumbprint
THUMBPRINT=$(echo | openssl s_client -servername "$HOST" -showcerts -connect "$HOST":443 2> /dev/null \
| sed -n -e '/BEGIN/h' -e '/BEGIN/,/END/H' -e '$x' -e '$p' | tail +2 \
| openssl x509 -fingerprint -noout \
| sed -e "s/.*=//" -e "s/://g" \
| tr "ABCDEF" "abcdef")

# Target Stack
TARGET_TEMPLATE_URL="https://raw.githubusercontent.com/MarioMoura/oidc-bootstrapper/refs/heads/main/GlobalProvider.yaml"
NAME="github-OIDC-provider"

# Download template temporarily
echo "Downloading CloudFormation template..."
TEMP_TEMPLATE="/tmp/GlobalProvider-${RANDOM}.yaml"
curl -s "$TARGET_TEMPLATE_URL" -o "$TEMP_TEMPLATE"

aws \
	cloudformation deploy \
	--stack-name "$NAME" \
	--capabilities CAPABILITY_NAMED_IAM \
	--template-file "$TEMP_TEMPLATE" \
	--region "$REGION" \
	--parameter-overrides \
	OIDCDOMAIN="$HOST" \
	Audience=$AUDIENCE \
	Thumbprint="$THUMBPRINT"

# Clean up temporary file
rm -f "$TEMP_TEMPLATE"

