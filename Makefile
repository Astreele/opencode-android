# Local build entry for opencode-android.
#
# Full native builds run in CI (.github/workflows/build-weekly.yml, Linux
# x86_64 + Zig + NDK + Rust + Bun); this Makefile reproduces every stage that
# runs locally: tests, lint, vendor checks, and packaging from a prebuilt
# CLI binary. See "Building from source" in README.md.
#
#   make help
#   make test [TEST=install]
#   make lint
#   make check-vendor
#   make package UPSTREAM_TAG=v2.0.24 [WORKSPACE=...] [WORK=...] [OUT=...]
#   make clean

TEST ?=
UPSTREAM_TAG ?=
WORKSPACE ?= $(CURDIR)
WORK ?= $(CURDIR)/work
OUT ?= $(CURDIR)/out

.PHONY: help test lint check-vendor package clean

help:
	@echo "Targets:"
	@echo "  test          run the bats suite (TEST=<suite> for one suite)"
	@echo "  lint          shellcheck scripts + actionlint workflows (if installed)"
	@echo "  check-vendor  golden checksum + ELF gates for vendor/ natives"
	@echo "  package       build zip/deb/pacman from a prebuilt CLI (needs UPSTREAM_TAG)"
	@echo "  clean         remove work/, out/, upstream/, dist/ (generated dirs)"

test:
	bash tests/run.sh $(TEST)

lint:
	shellcheck -S warning -x install.sh scripts/*.sh tests/run.sh
	if command -v actionlint >/dev/null 2>&1; then actionlint; else echo "actionlint not installed, skipping workflow lint"; fi

check-vendor:
	bash tests/run.sh vendor

package:
	@if [ -z "$(UPSTREAM_TAG)" ]; then echo "usage: make package UPSTREAM_TAG=v2.0.24" >&2; exit 1; fi
	UPSTREAM_TAG="$(UPSTREAM_TAG)" WORKSPACE="$(WORKSPACE)" WORK="$(WORK)" OUT="$(OUT)" bash scripts/package.sh

clean:
	rm -rf work out upstream dist
