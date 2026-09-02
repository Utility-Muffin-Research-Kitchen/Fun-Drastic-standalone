SHELL := /bin/bash

# The archive has no authorized public home yet, so upstream.env pins the hash
# only and the reviewed copy is supplied explicitly:
#
#   make package-mlp1 FUN_DRASTIC_ARCHIVE=/absolute/path/to/drastic.zip
FUN_DRASTIC_ARCHIVE ?=
OUTPUT_DIR ?=

# Accepted for dispatcher parity with the other standalone product repos.
# Fun DraStic is a prebuilt binary package: nothing is cross-compiled here.
TOOLCHAIN_IMAGE ?=

.PHONY: package-mlp1 verify-package-mlp1 smoke-launch-wrapper test clean

package-mlp1:
	FUN_DRASTIC_ARCHIVE="$(FUN_DRASTIC_ARCHIVE)" \
	OUTPUT_DIR="$(OUTPUT_DIR)" \
		./package-mlp1.sh

verify-package-mlp1:
	python3 scripts/validate-package.py \
		"$${OUTPUT_DIR:-output/mlp1/fun-drastic}"

smoke-launch-wrapper:
	./scripts/smoke-launch-wrapper.sh

test: smoke-launch-wrapper

clean:
	rm -rf output/mlp1
