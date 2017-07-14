#!/bin/sh
#
# default vcap password c1oudc0w
#
# https://bosh.io/docs/addons-common.html#misc-users
#
# Set specific stemcell & release versions and match manifest & upload_releases_stemcells.sh

set -e

BASE_DIR="`dirname \"$0\"`"

. "$BASE_DIR/common-bosh.sh"

[ x"$DELETE_BOSH_STATE" != x"true" ] && rm -f "$BOSH_LITE_STATE_FILE"

# Behaviour modifications
if [ -z "$SKIP_STATE_CHECK" -o x"$SKIP_STATE_CHECK" = x"false" ] && [ -f "$BOSH_LITE_STATE_FILE" ]; then
	WARN "Existing Bootstrap Bosh state file exists: $BOSH_LITE_STATE_FILE"
fi

if [ ! -f "$PASSWORD_CONFIG_FILE" -o x"$REGENERATE_PASSWORDS" = x"true" ]; then
	# Environmental variables are insecure
	INFO 'Generating password config'
	echo '# Cloudfoundry passwords' >"$PASSWORD_CONFIG_FILE"
	for i in `sed -nre 's/.*\(\(([^).]*(password|secret)[^).]*)\)\).*/\1/gp' "$BOSH_FULL_MANIFEST_FILE" "$BOSH_LITE_MANIFEST_FILE" | sort -u`; do
		cat <<EOF
$i='`generate_password`'
EOF
	done >>"$PASSWORD_CONFIG_FILE"
fi

# Sanity check
[ -f "$PASSWORD_CONFIG_FILE" ] || FATAL "Password configuration file does not exist: '$PASSWORD_CONFIG_FILE'"

INFO 'Loading password configuration'
eval export `prefix_vars "$PASSWORD_CONFIG_FILE" "$ENV_PREFIX"`
# We set BOSH_CLIENT_SECRET to this later on
eval DIRECTOR_PASSWORD="\$${ENV_PREFIX}director_password"

if [ ! -d "$SSL_FOLDER" -o ! -f "$SSL_YML" -o x"$REGENERATE_SSL" = x"true" -o x"$DELETE_SSL_CA" = x"true" ]; then
	[ -d "$SSL_FOLDER" ] && rm -rf "$SSL_FOLDER"

	INFO 'Generating SSL CAs and keypairs'
	mkdir -p "$SSL_FOLDER"
	cd "$SSL_FOLDER"

	# $SSL_YML may contain spaces
	OUTPUT_YML="$SSL_YML" "$BASE_DIR/generate-ssl.sh" "$domain_name" "$INTERNAL_DOMAIN"

	cd -
fi

# Just in case
if [ ! -f "$EXTERNAL_SSL_FOLDER/client/director.$domain_name.key" -o ! -f "$EXTERNAL_SSL_FOLDER/client/director.$domain_name.crt" ]; then
	FATAL 'No director SSL keypair available'
fi

if [ ! -f "$BOSH_CONFIG_FILE" -o x"$REGENERATE_BOSH_CONFIG" = x"true" ]; then
	INFO 'Generating Bosh configurations'
	cat <<EOF >"$BOSH_CONFIG_FILE"
# Bosh deployment config
BOSH_ENVIRONMENT='$director_dns'
BOSH_DEPLOYMENT='$DEPLOYMENT_NAME'
BOSH_CLIENT_SECRET='$DIRECTOR_PASSWORD'
BOSH_CLIENT='director'
BOSH_CA_CERT='$EXTERNAL_SSL_FOLDER_RELATIVE/ca/$domain_name.crt'
EOF
fi

INFO 'Loading Bosh config'
[ -f "$BOSH_CONFIG_FILE" ] || FATAL "Bosh configuration file does not exist: '$BOSH_CONFIG_FILE'"
eval export `prefix_vars "$BOSH_CONFIG_FILE"`
eval export `prefix_vars "$BOSH_SSH_CONFIG_FILE" "$ENV_PREFIX"`

# Convert from relative to an absolute path
findpath BOSH_CA_CERT "$BOSH_CA_CERT"
export BOSH_CA_CERT

# The file is recorded relative to the base directory, but Bosh changes its directory internally, whilst running, to the location of the manifest,
# so we need to make sure the SSH file is an absolute location
eval bosh_ssh_key_file="\$${ENV_PREFIX}bosh_ssh_key_file"
findpath "${ENV_PREFIX}bosh_ssh_key_file" "$bosh_ssh_key_file"

if [ -n "$DELETE_BOSH_ENV" -a x"$DELETE_BOSH_ENV" = x"true" ]; then
	[ -n "$NON_AWS_DEPLOYMENT" ] || check_aws_keys

	INFO 'Removing existing Bosh bootstrap environment'
	bosh_env delete-env

	rm -f "$BOSH_LITE_STATE_FILE"
fi

if [ ! -f "$BOSH_LITE_STATE_FILE" -o x"$REGENERATE_BOSH_ENV" = x"true" ]; then
	# XXX This will need some future changes when vSphere/other support is completed
	if [ -z "$NON_AWS_DEPLOYMENT" ]; then
		if [ -z "$AWS_ACCESS_KEY_ID" -o -z "$AWS_SECRET_ACCESS_KEY" ]; then
			INFO 'Loading AWS credentials'
			eval export `parse_aws_credentials | prefix_vars -`
		else
			INFO 'Setting AWS credentials'
			aws_access_key_id="$AWS_ACCESS_KEY_ID"
			aws_secret_access_key="$AWS_SECRET_ACCESS_KEY"
		fi

		check_aws_keys
	fi

	INFO 'Creating Bosh bootstrap environment'
	bosh_env create-env

	# Do not keep any state file if things fail
	if [ 0$? -ne 0 ]; then
		rm -f "$BOSH_LITE_STATE_FILE"

		FATAL 'Bosh lite deployment failed'
	fi

	NEW_BOSH_ENV='true'
fi

INFO 'Pointing Bosh at newly deployed Bosh'
"$BOSH" alias-env $BOSH_TTY_OPT -e "$director_dns" "$BOSH_ENVIRONMENT"

INFO 'Attempting to login'
"$BOSH" log-in $BOSH_TTY_OPT

# Upload Stemcells & releases
[ x"$REUPLOAD_COMPONENTS" = x"true" -o x"$NEW_BOSH_ENV" = x"true" ] && "$BASE_DIR/upload_components.sh"

INFO 'Setting CloudConfig'
"$BOSH" update-cloud-config "$BOSH_FULL_CLOUD_CONFIG_FILE" \
	$BOSH_INTERACTIVE_OPT \
	$BOSH_TTY_OPT \
	--var bosh_name="$DEPLOYMENT_NAME" \
	--var bosh_deployment="$BOSH_DEPLOYMENT" \
	--var bosh_lite_ip="$director_dns" \
	--vars-file="$SSL_YML" \
	--vars-env="$ENV_PREFIX_NAME" \
	--vars-store="$BOSH_FULL_VARS_FILE"

INFO 'Checking Bosh deployment dry-run'
"$BOSH" deploy "$BOSH_FULL_MANIFEST_FILE" \
	--dry-run \
	$BOSH_INTERACTIVE_OPT \
	$BOSH_TTY_OPT \
	--var bosh_name="$DEPLOYMENT_NAME" \
	--var bosh_deployment="$BOSH_DEPLOYMENT" \
	--var bosh_lite_ip="$director_dns" \
	--vars-file="$SSL_YML" \
	--vars-env="$ENV_PREFIX_NAME" \
	--vars-store="$BOSH_FULL_VARS_FILE"

INFO 'Deploying Bosh'
"$BOSH" deploy "$BOSH_FULL_MANIFEST_FILE" \
	$BOSH_INTERACTIVE_OPT \
	$BOSH_TTY_OPT \
	--var bosh_name="$DEPLOYMENT_NAME" \
	--var bosh_deployment="$BOSH_DEPLOYMENT" \
	--var bosh_lite_ip="$director_dns" \
	--vars-file="$SSL_YML" \
	--vars-env="$ENV_PREFIX_NAME" \
	--vars-store="$BOSH_FULL_VARS_FILE"

INFO 'Cloudfoundry VMs'
"$BOSH" vms
