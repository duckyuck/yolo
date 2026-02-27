SHELL   := /bin/bash
VERSION := $(shell grep '^YOLO_VERSION=' yolo | head -1 | sed 's/YOLO_VERSION="//' | sed 's/"//')
DIST    := dist
BUNDLE  := $(DIST)/yolo-$(VERSION)
TARBALL := $(DIST)/yolo-$(VERSION).tar.gz
REPO    := duckyuck/yolo
FILES   := yolo docker-compose.yml Dockerfile entrypoint.sh tmux.conf
HOOKS   := $(wildcard hooks/*.sh)
TESTS   := $(wildcard test/test-*.sh)

.PHONY: release clean test changelog

test:
	@for t in $(TESTS); do echo "── $$t"; bash "$$t" || exit 1; echo; done

release: test
	@# --- Version bump guard ---
	@LAST_TAG=$$(git tag --sort=-v:refname | head -1 | sed 's/^v//'); \
	if [ "$(VERSION)" = "$$LAST_TAG" ]; then \
		echo "Error: YOLO_VERSION ($(VERSION)) matches latest tag (v$$LAST_TAG)."; \
		echo "Bump YOLO_VERSION in yolo before releasing."; \
		exit 1; \
	fi
	@# --- Generate changelog ---
	@$(MAKE) --no-print-directory changelog
	@# --- Commit, tag, build, push, publish ---
	git add CHANGELOG.md
	git commit -m "release: v$(VERSION)"
	git tag "v$(VERSION)"
	@$(MAKE) --no-print-directory $(TARBALL)
	git push
	git push --tags
	@V=$$(echo "$(VERSION)" | sed 's/\./\\./g'); \
	BODY=$$(awk "/^## $$V/{found=1; next} /^## [0-9]/{found=0} found" CHANGELOG.md); \
	gh release create "v$(VERSION)" $(TARBALL) --repo $(REPO) --notes "$$BODY"
	@echo ""
	@echo "Released v$(VERSION): https://github.com/$(REPO)/releases/tag/v$(VERSION)"

changelog:
	@LAST_TAG=$$(git tag --sort=-v:refname | head -1); \
	if [ -n "$$LAST_TAG" ]; then \
		RANGE="$$LAST_TAG..HEAD"; \
	else \
		RANGE=""; \
	fi; \
	TODAY=$$(date +%Y-%m-%d); \
	FEATS=""; FIXES=""; OTHER=""; \
	while IFS= read -r line; do \
		HASH=$$(echo "$$line" | awk '{print $$1}'); \
		MSG=$$(echo "$$line" | cut -d' ' -f2-); \
		case "$$MSG" in \
			feat:*|feat\(*) \
				DESC=$$(echo "$$MSG" | sed 's/^feat[^:]*: *//'); \
				FEATS="$$FEATS- $$DESC ($$HASH)\n";; \
			fix:*|fix\(*) \
				DESC=$$(echo "$$MSG" | sed 's/^fix[^:]*: *//'); \
				FIXES="$$FIXES- $$DESC ($$HASH)\n";; \
			release:*) ;; \
			*) \
				DESC=$$(echo "$$MSG" | sed 's/^[a-z]*[^:]*: *//'); \
				OTHER="$$OTHER- $$DESC ($$HASH)\n";; \
		esac; \
	done < <(git log --oneline $$RANGE); \
	ENTRY="## $(VERSION) — $$TODAY\n"; \
	if [ -n "$$FEATS" ]; then ENTRY="$$ENTRY\n### Features\n$$FEATS"; fi; \
	if [ -n "$$FIXES" ]; then ENTRY="$$ENTRY\n### Fixes\n$$FIXES"; fi; \
	if [ -n "$$OTHER" ]; then ENTRY="$$ENTRY\n### Other\n$$OTHER"; fi; \
	if [ -f CHANGELOG.md ]; then \
		EXISTING=$$(tail -n +2 CHANGELOG.md); \
		printf "# Changelog\n\n$$ENTRY\n$$EXISTING\n" > CHANGELOG.md; \
	else \
		printf "# Changelog\n\n$$ENTRY" > CHANGELOG.md; \
	fi; \
	echo "Updated CHANGELOG.md for v$(VERSION)"

$(TARBALL): $(FILES) $(HOOKS)
	@echo "Packaging yolo v$(VERSION)..."
	rm -rf $(BUNDLE) $(TARBALL)
	mkdir -p $(BUNDLE)/hooks
	cp $(FILES) $(BUNDLE)/
	cp $(HOOKS) $(BUNDLE)/hooks/
	chmod +x $(BUNDLE)/yolo $(BUNDLE)/entrypoint.sh $(BUNDLE)/hooks/*.sh
	tar czf $(TARBALL) -C $(DIST) yolo-$(VERSION)
	rm -rf $(BUNDLE)
	@echo "Created $(TARBALL)"

clean:
	rm -rf $(DIST)
