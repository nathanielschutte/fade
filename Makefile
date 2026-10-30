# Everyday commands: building, running, and testing napsack on this machine.
# Nothing here deploys, connects to production, or changes anything outside
# the repository (that's scripts/deploy.sh, ssh.sh, and Terraform: the owner's).
# `make` alone lists them. Setting up a machine: docs/onboarding.md, and for
# the iOS app docs/ios-onboarding.md.

.DEFAULT_GOAL := help
.PHONY: help run test test-fast unit smoke browser lint fmt ci ios ios-quick ios-crypto ios-open ios-staging test-staging

PORT ?= 8080
ADMIN ?= nate

help: ## This list
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{ printf "  make %-13s %s\n", $$1, $$2 }'
	@echo
	@echo "  browser takes T=<file in tests/e2e> (make browser T=test_chat.py); ios takes ONLY=NapsackTests/<Suite>"

run: ## The server and web app on http://127.0.0.1:8080 (PORT=), with nate as an Admin (ADMIN=); web files reload as they change
	cd server && FADE_BIND=127.0.0.1:$(PORT) FADE_ADMINS=$(ADMIN) cargo run

test: ## Everything for the server and web app: unit, crypto, smoke, and browser tests (scripts/test.sh)
	bash scripts/test.sh

test-fast: ## The same without the browser tests
	bash scripts/test.sh --no-browser

unit: ## The server's unit tests only (cargo test)
	cd server && cargo test

smoke: ## The API smoke test against a fresh server
	bash scripts/test-one.sh smoke

browser: ## One browser test against a fresh server: make browser T=test_chat.py
	@test -n "$(T)" || { echo "which one? make browser T=test_chat.py (files in tests/e2e)"; exit 2; }
	bash scripts/test-one.sh $(T)

lint: ## What CI checks besides the tests: cargo fmt, clippy, terraform fmt
	cd server && cargo fmt --check && cargo clippy --all-targets -- -D warnings
	terraform fmt -check -recursive infra

fmt: ## Formats the Rust and Terraform code
	cd server && cargo fmt
	terraform fmt -recursive infra

ci: lint test ## lint, then test: what the server's CI runs, before you push

ios: ## The iOS app: the crypto package, then the app's tests on a Simulator, live against a fresh server (scripts/test-ios.sh)
	bash scripts/test-ios.sh

ios-quick: ## The same without a server, as the iOS CI runs it
	bash scripts/test-ios.sh --no-live

ios-staging: ## The iOS app's tests live against staging (makes test accounts there; never production)
	bash scripts/test-ios.sh --staging

ios-crypto: ## The iOS crypto package against the pinned vectors (swift test), seconds
	swift test --package-path ios/NapsackCrypto

ios-open: ## Opens the iOS app in Xcode
	open ios/Napsack.xcodeproj

test-staging: ## The smoke and browser tests against staging (makes test accounts there; never production)
	bash scripts/test-staging.sh
