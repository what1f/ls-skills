REPO := go run ./cmd/repo
TOOL ?=
PLATFORM ?=
ALL ?=

.PHONY: help check structure sync build smoke clean

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'
	@echo "  scaffold:  go run ./cmd/repo new <name> --lang go|zig|none [--no-skill]"

check: ## Structure, fmt, vet, tests, host build + version check [TOOL=]
	$(REPO) check $(if $(TOOL),--tool $(TOOL))

structure: ## Check repo rules and generated files
	$(REPO) structure

sync: ## Regenerate release-please config, manifest and marketplace.json
	$(REPO) sync

build: ## Cross-compile into dist/ [TOOL=] [PLATFORM=os-arch | ALL=1]
	$(REPO) build $(if $(TOOL),--tool $(TOOL)) $(if $(PLATFORM),--platform $(PLATFORM)) $(if $(ALL),--all-platforms)

smoke: ## Verify host binaries already in dist/
	$(REPO) smoke

clean: ## Remove build output
	rm -rf dist tools/*/cli/zig-out tools/*/cli/.zig-cache packages/zig/*/zig-out packages/zig/*/.zig-cache
