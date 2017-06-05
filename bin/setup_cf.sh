#!/bin/sh
#
#

set -e

BASE_DIR="`dirname \"$0\"`"

. "$BASE_DIR/common.sh"
. "$BASE_DIR/bosh-env.sh"

eval export `prefix_vars "$DEPLOYMENT_FOLDER/outputs.sh"`
eval export `prefix_vars "$DEPLOYMENT_FOLDER/passwords.sh"`

EMAIL_ADDRESS="${1:-NONE}"
ORG_NAME="${2:-$organisation}"
TEST_SPACE="${3:-Test}"
DONT_SKIP_SSL_VALIDATION="$4"

# We don't want any sub-scripts to login
export NO_LOGIN=1

[ -z "$EMAIL_ADDRESS" ] && FATAL 'No email address has been supplied'
[ -n "$DONT_SKIP_SSL_VALIDATION" ] || CF_EXTRA_OPTS='--skip-ssl-validation'
[ -z "$ORG_NAME" ] && FATAL 'No organisation has been set.  Did outputs.sh set an organisation correctly?'

findpath TEST_APPS "$BASE_DIR/../test-apps"

# Ensure we have CF available
installed_bin cf

# We may not always want to update the admin user
[ x"$EMAIL_ADDRESS" != x"NONE" ] && "$BASE_DIR/setup_cf-admin.sh" "$DEPLOYMENT_NAME" cf_admin "$EMAIL_ADDRESS"

[ -f "$DEPLOYMENT_FOLDER/cf-credentials-admin.sh" ] || FATAL "Cannot find CF admin credentials: $DEPLOYMENT_FOLDER/cf-credentials-admin.sh. Has an admin user been created"

# Pull in newly generated credentials
eval export `prefix_vars "$DEPLOYMENT_FOLDER/cf-credentials-admin.sh"`

INFO "Setting API target as $api_dns"
"$CF" api "$api_dns" "$CF_EXTRA_OPTS"

INFO "Logging in as $CF_ADMIN_USERNAME"
"$CF" login -u "$CF_ADMIN_USERNAME" -p "$CF_ADMIN_PASSWORD" "$CF_EXTRA_OPTS"

"$BASE_DIR/setup_cf-orgspace.sh" "$DEPLOYMENT_NAME" "$ORG_NAME" "$TEST_SPACE"

INFO 'Available buildpacks:'
# Sometimes we get a weird error, but upon next deployment the error doesn't occur...
# Server error, status code: 400, error code: 100001, message: The app is invalid: buildpack staticfile_buildpack is not valid public url or a known buildpack name
"$CF" buildpacks

if [ -z "$SKIP_TESTS" ]; then
	INFO 'Testing application deployment'
	for i in `ls "$TEST_APPS"`; do
		cd "$TEST_APPS/$i"

		buildpack="`awk '/^ *buildpack:/{print $2}' manifest.yml`"

		if [ -n "$buildpack" ]; then
			"$CF" buildpacks | grep -q "^$buildpack" || FATAL "Buildpack '$buildpack' not available - please retry"
		fi

		"$BASE_DIR/cf_push.sh" "$DEPLOYMENT_NAME" "$i" "$ORG_NAME" "$TEST_SPACE"

		"$BASE_DIR/cf_delete.sh" "$DEPLOYMENT_NAME" "$i"

		cd -
	done
fi

INFO 'Setting up RDS broker'
IGNORE_EXISTING=1 "$BASE_DIR/setup_cf-rds-broker.sh" "$DEPLOYMENT_NAME"

INFO 'Setting up RabbitMQ broker'
IGNORE_EXISTING=1 "$BASE_DIR/setup_cf-service-broker.sh" "$DEPLOYMENT_NAME" rabbitmq 'rabbitmq-broker' "$rabbitmq_broker_password" "https://rabbitmq-broker.system.$domain_name"
