#!/bin/sh
#
# Run Bosh errands that are prefxed with 'backup-'
#

set -e

BASE_DIR="`dirname \"$0\"`"

DEPLOYMENT_NAME="${1:-$DEPLOYMENT_NAME}"

. "$BASE_DIR/common.sh"
. "$BASE_DIR/common-bosh-login.sh"

for _e in `"$BOSH" errands | grep -E '^backup-'`; do
	"$BOSH" run-errand "$_e"
done
