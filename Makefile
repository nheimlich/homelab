.PHONY: all check clean setup generate bootstrap shutdown help generate-manifests kubescape
.DEFAULT_GOAL := help

all: check clean setup generate bootstrap clean

help:
	# check: Validate all tools are installed
	# clean: Clean up all generated files
	# setup: Setup the environment
	# generate: Generate config patches (Talos)
	# bootstrap: Bootstrap a Talos cluster
	# reset: Reset Talos nodes
	# shutdown: Shutdown Talos nodes
	# upgrade: Check available upgrades
	# generate-manifests: Generate K8s manifests for a cluster type
	# kubescape: Run a Kubescape cluster scan (framework full)

check:
	@./scripts/common.sh check

clean:
	@./scripts/common.sh clean

generate:
	@./clusters/types/talos/provision/generate.sh

setup:
	@./clusters/types/talos/provision/setup.sh

bootstrap:
	@./clusters/types/talos/provision/bootstrap.sh

reset:
	@./clusters/types/talos/provision/reset.sh

shutdown:
	@talosctl shutdown -n 10.0.0.111,10.0.0.112,10.0.0.113 -e 10.0.0.115 --context k8s.nhlabs.local --wait=false --force

upgrade:
	@./clusters/types/talos/provision/upgrade.sh

generate-manifests:
	@./scripts/generate-manifests --all-types -f

kubescape:
	@kubescape scan framework AllControls
