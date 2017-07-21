#!/bin/sh
#
#

set -e

BASE_DIR="`dirname \"$0\"`"

DEPLOYMENT_NAME="$1"
SSH_HOST="$2"
GATEWAY_USER="${3:-vcap}"
GATEWAY_HOST="$4"

. "$BASE_DIR/common.sh"

[ -z "$SSH_HOST" ] && FATAL 'No host to ssh onto'

[ -z "$DEPLOYMENT_NAME" ] && FATAL 'Deployment name not provided'
[ -d "$DEPLOYMENT_DIR" ] || FATAL "Deployment does not exist '$DEPLOYMENT_DIR'"
[ -f "$BOSH_SSH_CONFIG" ] || FATAL "Bosh SSH config does not exist: $BOSH_SSH_CONFIG"
[ -f "$BOSH_DIRECTOR_CONFIG" ] || FATAL "Bosh config does not exist: $BOSH_DIRECTOR_CONFIG"

#load_output_vars "$STACK_OUTPUTS_DIR_RELATIVE" NONE director_dns
eval export `prefix_vars "$BOSH_SSH_CONFIG"`
eval export `prefix_vars "$BOSH_DIRECTOR_CONFIG"`

# Convert from relative to an absolute path
findpath BOSH_CA_CERT "$BOSH_CA_CERT"
# Store existing path, in case the full path contains spaces
bosh_ssh_key_file_org="$bosh_ssh_key_file"
findpath bosh_ssh_key_file "$bosh_ssh_key_file"

if stat -c "%a" "$bosh_ssh_key_file" | grep -Evq '^0?600$'; then
	WARN "Fixing permissions SSH key file: $bosh_ssh_key_file"
	chmod 0600 "$bosh_ssh_key_file"
fi

# Bosh SSH doesn't handle spaces in the key filename/path
if echo "$bosh_ssh_key_file" | grep -q " "; then
	WARN "Bosh SSH does not handle spaces in the key filename/path: '$bosh_ssh_key_file'"
	WARN "Using relative path: $bosh_ssh_key_file_org"

	bosh_ssh_key_file="$bosh_ssh_key_file_org"
fi

export BOSH_CA_CERT

[ -z "${GATEWAY_HOST:-$BOSH_ENVIRONMENT}" ] && FATAL 'No gateway host available'

INFO "Pointing Bosh at deployed Bosh: $BOSH_ENVIRONMENT"
"$BOSH" alias-env -e "$BOSH_ENVIRONMENT" "$BOSH_ENVIRONMENT"

INFO 'Attempting to login'
set -x
"$BOSH" log-in

"$BOSH" ssh --gw-private-key="$bosh_ssh_key_file" --gw-user="$GATEWAY_USER" --gw-host "${GATEWAY_HOST:-$BOSH_ENVIRONMENT}" "$SSH_HOST"
set +x
