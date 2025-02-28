.PHONY: all check clean setup generate bootstrap help
.DEFAULT_GOAL := help


all: check clean setup generate bootstrap clean

help:
	# check: Validate all tools are installed
	# clean: Clean up all generated files
	# setup: Setup the environment
	# generate: Generate config patches
	# bootstrap: Bootstrap the system
	# reset: Reset all nodes
	# all: Run all steps in the correct order
	# help: Show this help message

check:
	@./scripts/common.sh check

clean:
	@./scripts/common.sh clean

generate:
	@./scripts/generate.sh

setup:
	@./scripts/setup.sh

bootstrap:
	@./scripts/bootstrap.sh

reset:
	@./scripts/reset.sh
