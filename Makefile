.PHONY: all check clean setup generate bootstrap shutdown help
.DEFAULT_GOAL := help


all: check clean setup generate bootstrap clean

help:
	# check: Validate all tools are installed
	# clean: Clean up all generated files
	# setup: Setup the environment
	# generate: Generate config patches
	# bootstrap: Bootstrap the system
	# reset: Reset all nodes
	# shutdown: Shutdown all nodes
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

shutdown:
	@talosctl shutdown -n 10.0.0.111,10.0.0.112,10.0.0.113 -e 10.0.0.115 --context k8s.nhlabs.local --wait=false

upgrade:
	@./scripts/upgrade.sh
