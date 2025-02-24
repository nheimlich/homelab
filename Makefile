.PHONY: all check clean setup generate bootstrap install help
.DEFAULT_GOAL := help


all: check clean setup generate bootstrap install clean

help:
	# check: Validate all tools are installed
	# clean: Clean up all generated files
	# setup: Setup the environment
	# generate: Generate config patches
	# bootstrap: Bootstrap the system
	# install: Post install steps
	# reset: Reset all nodes
	# all: Run all steps in the correct order
	# help: Show this help message

check:
	@./scripts/common.sh check

clean:
	@./scripts/common.sh clean

setup:
	@./scripts/setup.sh

generate:
	@./scripts/generate.sh

bootstrap:
	@./scripts/bootstrap.sh

install:
	@./scripts/install.sh

reset:
	@./scripts/reset.sh
