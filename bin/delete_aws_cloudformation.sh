#!/bin/sh
#
# See common-aws.sh for inputs
#

set -e

BASE_DIR="`dirname \"$0\"`"

# Don't complain about missing stack config file
IGNORE_MISSING_CONFIG='true'

# Run common AWS Cloudformation parts
. "$BASE_DIR/common-aws.sh"

empty_bucket(){
	bucket_name="$1"

	[ -n "$1" ] || FATAL 'No bucket name provided'

	if "$AWS" --output text --query "Buckets[?Name == '$bucket_name'].Name" s3api list-buckets | grep -Eq "^$bucket_name$"; then
		INFO "Emptying bucket: $bucket_name"
		"$AWS" s3 rm --recursive "s3://$bucket_name"
	fi
}

load_outputs "$STACK_OUTPUTS_DIR"

[ -n "$aws_region" ] && export AWS_DEFAULT_REGION="$aws_region"

if [ -n "$BOSH_SSH_CONFIG" -a -f "$BOSH_SSH_CONFIG" ]; then
	SSH_KEY_EXISTS=1

	INFO "Loading: $BOSH_SSH_CONFIG"
	. "$STACK_PREAMBLE_OUTPUTS"
fi

if [ -f "$STACK_PREAMBLE_OUTPUTS" ]; then
	INFO "Loading: $STACK_PREAMBLE_OUTPUTS"
	. "$STACK_PREAMBLE_OUTPUTS"

	empty_bucket "$templates_bucket_name"
fi

if [ -n "$s3_buckets" ]; then
	OLDIFS="$IFS"
	IFS=","
	for bucket in $s3_buckets; do
		IFS="$OLDIFS"
		empty_bucket "$bucket"
		IFS=","
	done
	IFS="$OLDIFS"
fi

# Provide the ability to optionally delete existing AWS SSH key
if [ -z "$KEEP_SSH_KEY" -o x"$KEEP_SSH_KEY" = x"false" ] && [ -n "$SSH_KEY_EXISTS" -a -n "$bosh_ssh_key_name" ] && \
	"$AWS" ec2 describe-key-pairs --key-names "$bosh_ssh_key_name" >/dev/null 2>&1; then

	INFO "Deleting SSH key: '$bosh_ssh_key_name'"
	"$AWS" ec2 delete-key-pair --key-name "$bosh_ssh_key_name"
fi

# This is slight stupid when there are sub-Cloudformation stacks, as these get deleted as well. We could filter them out, but
# unless our filtering is very strict & complicated it could incorrectly filter out stacks we want to delete. So, rather than
# do that, we just delete everything we come across
for _stack in `"$AWS" --output text --query "StackSummaries[?starts_with(StackName,'$DEPLOYMENT_NAME-') && StackStatus != 'DELETE_COMPLETE'].StackName" cloudformation list-stacks | sed -re 's/\t/\n/g' | sort -nr | awk -v prefix="$DEPLOYMENT_NAME" 'BEGIN{ re=sprintf("%s-([0-9]+.*|preamble)$",prefix) }{ if($0 ~ re){ if(/-preamble$/){ f=$0 }else{ print $0 } } }END{ print f }'`; do
	check_cloudformation_stack "$_stack" || continue

	INFO "Deleting stack: $_stack"
	"$AWS" cloudformation delete-stack --stack-name "$_stack"

	INFO 'Waiting for Cloudformation stack to be deleted'
	"$AWS" cloudformation wait stack-delete-complete --stack-name "$_stack"
done
