# Pickglass — common developer commands.
#
# Every target is a thin wrapper over gleam and the scripts, so what CI runs
# and what you run locally are the same commands. Packages live under
# packages/; tools/lint is Loom's house lint, vendored.

PACKAGES := core agent pickglass
# The vendored lint is formatted and tested as a package of its own, but it
# is not part of `check`'s lint run: it is the linter, not its subject.
TOOLS := lint

.DEFAULT_GOAL := help

# ---------------------------------------------------------------- checking

.PHONY: check
check: ## Full gate: format, warning-free build, tests, lint, doc-check, agent checks
	@$(MAKE) --no-print-directory fmt-check build test lint doc-check agent-imports agent-e2e
	@echo "check clean"

.PHONY: build
build: ## Warning-free build of every package
	@set -e; for p in $(PACKAGES); do \
		echo "==> $$p"; (cd packages/$$p && gleam build --warnings-as-errors); \
	done

.PHONY: test
test: ## Run tests only (skips format check)
	@set -e; for p in $(PACKAGES); do \
		echo "==> $$p"; (cd packages/$$p && gleam test); \
	done

# --------------------------------------------------------------- formatting

.PHONY: fmt
fmt: ## Format all Gleam sources in place
	@set -e; for p in $(PACKAGES); do (cd packages/$$p && gleam format src test); done
	@set -e; for t in $(TOOLS); do (cd tools/$$t && gleam format src test); done
	@echo "formatted"

.PHONY: fmt-check
fmt-check: ## Verify formatting without writing (what CI enforces)
	@set -e; for p in $(PACKAGES); do (cd packages/$$p && gleam format --check src test); done
	@set -e; for t in $(TOOLS); do (cd tools/$$t && gleam format --check src test); done
	@echo "formatting clean"

# -------------------------------------------------------------------- lint

.PHONY: lint
lint: ## Run the house lint (R0, R2, R4, R6, R10, R13-R16 gate; the rest warn)
	@scripts/lint.sh

# ------------------------------------------------------------------- agent

# The agent is pushed into someone else's VM, so two checks that no unit test
# can make run over its compiled beams. The import check proves no call
# leaves the agent and the OTP modules every node has. The end-to-end script
# pushes the beams into a peer node and proves the teardown guarantees.
AGENT_EBIN := packages/agent/build/dev/erlang/pickglass_agent/ebin

.PHONY: agent-imports
agent-imports: ## Fail if a compiled agent beam calls outside its allowed modules
	@(cd packages/agent && gleam build --warnings-as-errors)
	@escript scripts/agent_imports.escript $(AGENT_EBIN)

.PHONY: agent-e2e
agent-e2e: ## Push the agent into a peer node; check teardown on link death and kill -9
	@(cd packages/agent && gleam build --warnings-as-errors)
	@escript scripts/agent_e2e.escript $(AGENT_EBIN)

# -------------------------------------------------------------------- docs

.PHONY: doc-check
doc-check: ## Check the doc graph (AGENTS.md mirror, coverage, citations)
	@scripts/doc_check.sh

.PHONY: docs
docs: ## Render the /// doc comments to HTML under each package's build/dev/docs
	@set -e; for p in $(PACKAGES); do (cd packages/$$p && gleam docs build); done

# ----------------------------------------------------------------- release

# The release is a self-contained OTP release with the runtime system copied
# in, so it runs on a machine with no Erlang. It is per-platform, because the
# copied ERTS is this machine's. scripts/release.sh says how and why.
.PHONY: release
release: ## Build the self-contained release into build/release/pickglass (needs rebar3)
	@scripts/release.sh

.PHONY: release-smoke
release-smoke: ## Boot build/release/pickglass with no erl on PATH and check its output
	@scripts/release.sh --smoke

.PHONY: dist
dist: release release-smoke ## Package the release as a tarball under dist/
	@scripts/dist.sh

# -------------------------------------------------------------------- misc

.PHONY: deps
deps: ## Download dependencies for every package and tool
	@set -e; for p in $(PACKAGES); do (cd packages/$$p && gleam deps download); done
	@set -e; for t in $(TOOLS); do (cd tools/$$t && gleam deps download); done

.PHONY: clean
clean: ## Remove build artifacts
	@rm -rf build dist
	@set -e; for p in $(PACKAGES); do rm -rf packages/$$p/build; done
	@set -e; for t in $(TOOLS); do rm -rf tools/$$t/build; done
	@echo "cleaned"

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_%-]+:.*## ' $(MAKEFILE_LIST) | \
		awk -F':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
