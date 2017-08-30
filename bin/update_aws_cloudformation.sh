#!/bin/sh
#
# See common-aws.sh for inputs
#

set -e

BASE_DIR="`dirname \"$0\"`"

# Run common AWS Cloudformation parts
. "$BASE_DIR/common-aws.sh"

aws_change_set(){
	local stack_name="$1"
	local stack_url="$2"
	local stack_outputs="$3"
	local stack_parameters="$4"
	local template_option="${5:---template-body}"
	local update_validate="${6:-update}"

	[ -z "$stack_name" ] && FATAL 'No stack name provided'
	[ -z "$stack_url" ] && FATAL 'No stack url provided'
	[ -z "$stack_outputs" ] && FATAL 'No stack output filename provided'

	# Urgh!
	if [ -n "$stack_parameters" -a -f "$stack_parameters" ]; then

		findpath stack_parameters "$stack_parameters"
		local aws_opts="--parameters '`cat \"$stack_parameters\"`'"
	fi

	shift 3

	local change_set_name="$stack_name-changeset-`date +%s`"

	if [ x"$update_validate" = x"validate" ]; then
		INFO "Validating Cloudformation template: $stack_url"
		"$AWS" --profile "$AWS_PROFILE" --output table cloudformation validate-template $template_option "$stack_url"

		return $?
	fi

	if check_cloudformation_stack "$stack_name"; then
		local stack_arn="`\"$AWS\" --profile \"$AWS_PROFILE\" --output text --query \"StackSummaries[?StackName == '$stack_name'].StackId\" cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE`"
	fi

	if [ -z "$stack_arn" ]; then
		[ x"$SKIP_MISSING" = x"true" ] && log_level='WARN' || log_level='FATAL'

		$log_level "Stack does not exist"

		return 0
	fi

	INFO "Creating Cloudformation stack change set: $stack_name"
	INFO 'Changeset details:'
	sh -c "'$AWS' --profile "$AWS_PROFILE" \
		--output table \
		cloudformation create-change-set \
		--stack-name '$stack_arn' \
		--change-set-name '$change_set_name' \
		--capabilities CAPABILITY_IAM \
		--capabilities CAPABILITY_NAMED_IAM \
		$template_option '$stack_url' \
		$aws_opts"

	# Changesets only have three states: CREATE_IN_PROGRESS, CREATE_COMPLETE & FAILED. 
	INFO "Waiting for Cloudformation changeset to be created: $change_set_name"
	"$AWS" --profile "$AWS_PROFILE" --output table cloudformation wait change-set-create-complete --stack-name "$stack_arn" --change-set-name "$change_set_name" >/dev/null 2>&1 || :

	INFO 'Checking changeset status'
	if "$AWS" --output text --profile "$AWS_PROFILE" --query \
		"Status == 'CREATE_COMPLETE' && ExecutionStatus == 'AVAILABLE'" \
		cloudformation describe-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name" | grep -Eq '^True$'; then

		INFO 'Stack change set details:'
		"$AWS" --profile "$AWS_PROFILE" --output table cloudformation describe-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name"

		INFO "Starting Cloudformation changeset: $change_set_name"
		"$AWS" --profile "$AWS_PROFILE" --output table cloudformation execute-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name"

		INFO 'Waiting for Cloudformation stack to finish creation'
		"$AWS" --profile "$AWS_PROFILE" --output table cloudformation wait stack-update-complete --stack-name "$stack_arn" || FATAL 'Cloudformation stack changeset failed to complete'

		local stack_changes=1
	elif "$AWS" --output text --profile "$AWS_PROFILE" --query "StatusReason == 'The submitted information didn"\\\'"t contain changes. Submit different information to create a change set.'" \
		cloudformation describe-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name" | grep -Eq '^True$'; then

		WARN "Changeset did not contain any changes: $change_set_name"

		WARN "Deleting empty changeset: $change_set_name"
		"$AWS" --profile "$AWS_PROFILE" --output table cloudformation delete-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name"
	else
		WARN "Changeset failed to create"
		"$AWS" --output table --profile "$AWS_PROFILE" cloudformation describe-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name"

		WARN "Deleting failed changeset: $change_set_name"
		"$AWS" --profile "$AWS_PROFILE" --output table cloudformation delete-change-set --stack-name "$stack_arn" --change-set-name "$change_set_name"
	fi


	if [ x"$UPDATE_OUTPUTS" = x"true" -o -n "$stack_changes" -o ! "$stack_outputs" ]; then
		parse_aws_cloudformation_outputs "$stack_arn" >"$stack_outputs"

		NEW_OUTPUTS=1
	fi

	return 0
}


if [ -f "$STACK_PREAMBLE_OUTPUTS" ] && [ -z "$SKIP_STACK_PREAMBLE_OUTPUTS_CHECK" -o x"$SKIP_STACK_PREAMBLE_OUTPUTS_CHECK" = x"false" ]; then
	[ -f "$STACK_PREAMBLE_OUTPUTS" ] || FATAL "Existing stack preamble outputs do exist: '$STACK_PREAMBLE_OUTPUTS'"
fi

# We use older options in find due to possible lack of -printf and/or -regex options
STACK_FILES="`find "$CLOUDFORMATION_DIR" -mindepth 1 -maxdepth 1 -name "$AWS_CONFIG_PREFIX-*.json" | awk -F/ '!/preamble/{print $NF}' | sort`"
STACK_TEMPLATES_FILES="`find "$CLOUDFORMATION_DIR/Templates" -mindepth 1 -maxdepth 1 -name "*.json" | awk -F/ '{printf("%s/%s\n",$(NF-1),$NF)}' | sort`"

cd "$CLOUDFORMATION_DIR" >/dev/null
validate_json_files "$STACK_PREAMBLE_FILENAME" $STACK_FILES $STACK_TEMPLATES_FILES
cd - >/dev/null

# We need to suck in the region from the existing outputs.sh
INFO 'Obtaining current stack region'
load_output_vars "$STACK_OUTPUTS_DIR" NONE aws_region
if [ -n "$aws_region" ]; then
	INFO "Checking if we need to update AWS region to $aws_region"
	aws_region "$aws_region"
else
	WARN "Unable to find region from previous stack outputs"
fi


if [ ! -f "$STACK_PREAMBLE_OUTPUTS" ] && ! stack_exists "$DEPLOYMENT_NAME-preamble"; then
	FATAL "Preamble stack does not exist, do you need to run create_aws_cloudformation.sh first?"
fi

aws_change_set "$DEPLOYMENT_NAME-preamble" "$STACK_PREAMBLE_URL" "$STACK_PREAMBLE_OUTPUTS"

INFO 'Parsing preamble outputs'
eval `prefix_vars "$STACK_PREAMBLE_OUTPUTS"`

INFO 'Copying templates to S3'
"$AWS" --profile "$AWS_PROFILE" s3 sync "$CLOUDFORMATION_DIR/" "s3://$templates_bucket_name" --exclude '*' --include "$AWS_CONFIG_PREFIX-*.json" --include 'Templates/*.json'

# Now we can set the main stack URL
STACK_MAIN_URL="$templates_bucket_http_url/$STACK_MAIN_FILENAME"

for _action in validate update; do
	for _file in $STACK_FILES; do
		STACK_NAME="`stack_file_name "$DEPLOYMENT_NAME" "$_file"`"
		STACK_PARAMETERS="$STACK_PARAMETERS_DIR/parameters-$STACK_NAME.$STACK_PARAMETERS_SUFFIX"
		STACK_URL="$templates_bucket_http_url/$_file"
		STACK_OUTPUTS="$STACK_OUTPUTS_DIR/outputs-$STACK_NAME.$STACK_OUTPUTS_SUFFIX"

		if [ x"$_action" = x"update" -a -f "$STACK_PARAMETERS" ]; then
			INFO "Updating $STACK_NAME parameters"
			update_parameters_file "$CLOUDFORMATION_DIR/$_file" "$STACK_PARAMETERS"
		fi

		aws_change_set "$STACK_NAME" "$STACK_URL" "$STACK_OUTPUTS" "$STACK_PARAMETERS" --template-url $_action || FATAL "Failed to $_action stack: $STACK_NAME, $_file"
	done
done

if [ -n "$NEW_OUTPUTS" ]; then
	INFO 'Configuring DNS settings'
	load_output_vars "$STACK_OUTPUTS_DIR" NONE vpc_cidr
	calculate_dns "$vpc_cidr" >"$STACK_OUTPUTS_DIR/outputs-dns.$STACK_OUTPUTS_SUFFIX"
fi

INFO 'AWS Deployment Update Complete'
