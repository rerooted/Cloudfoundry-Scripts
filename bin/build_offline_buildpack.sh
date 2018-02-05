#!/bin/sh
#
# Script to build the various buildpack types
#
# Script assumes buildpack repository has been checked out to src/buildpack
#
# If we are building using the Go method, sometimes we have a vendor'd libbuildpack and other times we don't
# If we don't we assume libbuildpack is checked out to src/libbuildpack

set -e

BASE_DIR="`dirname \"$0\"`"

. "$BASE_DIR/common.sh"

# Buildpack methods:
#
# Go buildpack-packager
# Ruby buildpack-packager
# Java packager

BUILDPACK_NAME="$1"

[ -z "$BUILDPACK_NAME" ] && FATAL 'No buildpack name provided'

mkdir -p buildpack

if [ -f src/buildpack/cf.Gemfile ]; then
	# Ruby buildpack packager
	which ruby >/dev/null || FATAL 'Ruby is not installed, or is not in the $PATH'

	INFO 'Using Ruby buildpack packager'
	cd src/buildpack

	# CF uses a different Gemfile name
	INFO 'Ensuring all of the Ruby dependencies are installed'
	BUNDLE_GEMFILE=cf.Gemfile bundle

	INFO "Building $BUILDPACK_NAME"
	BUNDLE_GEMFILE=cf.Gemfile bundle exec buildpack-packager --cache


elif [ -f src/buildpack/java-buildpack.iml ]; then
	# Java buildpack packager - as always Java people like to do things differently:
	which ruby >/dev/null || FATAL 'Ruby is not installed, or is not in the $PATH'

	cd src/buildpack

	INFO 'Ensuring all of the Ruby dependencies are installed'
	bundle  install

	INFO 'Building Java buildpack'
	bundle exec rake clean package OFFLINE=true PINNED=true

else
	# We make the blind assumption we are building using the Go buildpack packager
	which go >/dev/null || FATAL 'Go is not installed, or is not in the $PATH'

	INFO 'Using Go buildpack packager'

	INFO 'Setting required Go variables'
	export GOPATH="$PWD"

	if [ -d "src/buildpack/src/$BUILDPACK_NAME/vendor/github.com/cloudfoundry/libbuildpack/packager/buildpack-packager" ]; then
		# Some Go buildpacks have a vendored buildpack-packager
		PACKAGER_DIR="src/buildpack/src/$BUILDPACK_NAME/vendor/github.com/cloudfoundry/libbuildpack/packager/buildpack-packager"
		PACKAGER_TYPE='vendored'

		INFO 'Building vendored Go buildpack packager'
		go install

	elif [ -d src/libbuildpack ]; then
		# Some Go buildpacks rely on a pre-installed buildpack-packager
		PACKAGER_DIR='src/libbuildpack'
		TYPE='external'
	else
		FATAL 'No checkout or vendored version of src/libbuildpack':
	fi

	cd "$PACKAGER_DIR"

	if [ x"$TYPE" = x'external' ]; then
		INFO 'Installing Go buildpack dependencies'
		go get ./...
	fi

	INFO 'Building Go buildpack packager'
	go install

	cp bin/buildpack-packager "$GOBIN"

	INFO 'Fixing script permissions'
	find bin scripts -mindepth 1 -maxdepth 1 -name \*.sh -exec chmod +x "{}"

	"$GOBIN/buildpack-packager" --cached
fi

INFO 'Copying built buildpack to output folder'
find . "(" -name "${BUILDPACK}_buildpack-cached"-\*.zip -or -name "$BUILDPACK-buildpack-offline"-\*.zip ")" -exec cp "{}" buildpack/