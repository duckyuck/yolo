VERSION := $(shell grep '^YOLO_VERSION=' yolo | head -1 | sed 's/YOLO_VERSION="//' | sed 's/"//')
DIST    := dist
BUNDLE  := $(DIST)/yolo-$(VERSION)
TARBALL := $(DIST)/yolo-$(VERSION).tar.gz
REPO    := sourcemagnet/yolo
FILES   := yolo docker-compose.yml Dockerfile entrypoint.sh tmux.conf
HOOKS   := $(wildcard hooks/*.sh)

.PHONY: release clean

release: $(TARBALL)
	gh release create "v$(VERSION)" $(TARBALL) --repo $(REPO) --generate-notes
	@echo ""
	@echo "Released v$(VERSION): https://github.com/$(REPO)/releases/tag/v$(VERSION)"

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
