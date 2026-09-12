# Notely developer tasks. Thin wrappers over scripts/ so `make` and `just` stay in sync.
.DEFAULT_GOAL := help
.PHONY: help bootstrap dev engine desktop check test build download-models verify-models reset-data

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Install/verify toolchains and fetch dependencies
	./scripts/bootstrap.sh

dev: ## Run engine + desktop app together
	./scripts/dev.sh

engine: ## Run the Rust engine
	./scripts/start-engine.sh

desktop: ## Run the Flutter desktop app
	./scripts/start-desktop.sh

check: ## Format + lint (Rust and Flutter)
	./scripts/check.sh

test: ## Run all tests
	./scripts/test.sh

build: ## Release build of engine + desktop app
	./scripts/build.sh

download-models: ## Fetch models described in models/manifests/
	./scripts/download-models.sh

verify-models: ## Verify required models are available
	./scripts/verify-models.sh

reset-data: ## Delete local Notely data
	./scripts/reset-data.sh
