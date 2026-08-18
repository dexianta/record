SHELL := /bin/zsh

VERSION := $(word 2,$(MAKECMDGOALS))
BUILD ?= $(shell git rev-list --count HEAD)
REPOSITORY := dexianta/record

.PHONY: publish $(VERSION)
publish:
	@set -euo pipefail; \
	version="$(VERSION)"; \
	command -v gh >/dev/null || { echo "Install GitHub CLI first: brew install gh"; exit 1; }; \
	gh auth status >/dev/null; \
	if [[ -z "$$version" ]]; then \
		latest="$$(gh release view --repo "$(REPOSITORY)" --json tagName --jq .tagName 2>/dev/null || true)"; \
		[[ -n "$$latest" ]] && latest="$${latest#v}" || latest="none"; \
		echo "Latest published version: $$latest"; \
		exit 0; \
	fi; \
	if [[ ! "$$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$$' ]]; then \
		echo "Usage: make publish 0.2.0"; \
		exit 2; \
	fi; \
	if [[ -n "$$(git status --porcelain)" ]]; then \
		echo "Commit your changes before publishing."; \
		exit 1; \
	fi; \
	git push origin HEAD; \
	./scripts/prepare-update.sh "$$version" "$(BUILD)"; \
	gh release create "v$$version" \
		"dist/record.dmg" \
		"dist/record-$$version.zip" \
		--repo "$(REPOSITORY)" \
		--target "$$(git rev-parse HEAD)" \
		--title "Record $$version" \
		--generate-notes; \
	git add appcast.xml; \
	git commit -m "Publish Record $$version"; \
	git push origin HEAD; \
	echo "Published: https://github.com/$(REPOSITORY)/releases/tag/v$$version"

ifneq ($(VERSION),)
$(VERSION):
	@:
endif
