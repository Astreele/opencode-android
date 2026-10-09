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
#   make vendors [VENDORS=all|libopentui|pty] [FORCE=0|1]
#   make package UPSTREAM_TAG=v2.0.24 [WORKSPACE=...] [WORK=...] [OUT=...]
#   make apt-repo [REPO_DIR=apt-repo] [OUT=out] [SIGN=1] [KEEP=4]
#   make clean

TEST ?=
UPSTREAM_TAG ?=
VENDORS ?= all
FORCE ?= 0
WORKSPACE ?= $(CURDIR)
WORK ?= $(CURDIR)/work
OUT ?= $(CURDIR)/out
APT_REPO_DIR ?= $(CURDIR)/apt-repo
SIGN ?= 1
KEEP ?= 4

.PHONY: help test lint check-vendor vendors package apt-repo clean

help:
	@echo "Targets:"
	@echo "  test          run the bats suite (TEST=<suite> for one suite)"
	@echo "  lint          shellcheck scripts + actionlint workflows (if installed)"
	@echo "  check-vendor  golden checksum + ELF gates for vendor/ natives"
	@echo "  vendors       verify/stage vendor cache (VENDORS=..., FORCE=1 rebuilds)"
	@echo "  package       build zip/deb/pacman from a prebuilt CLI (needs UPSTREAM_TAG)"
	@echo "  apt-repo      build signed APT repo from OUT/*.deb (SIGN=0 skips gpg)"
	@echo "  clean         remove work/, out/, upstream/, dist/ (generated dirs)"

test:
	bash tests/run.sh $(TEST)

lint:
	shellcheck -S warning -x install.sh scripts/*.sh tests/*.sh
	if command -v actionlint >/dev/null 2>&1; then actionlint; else echo "actionlint not installed, skipping workflow lint"; fi

check-vendor:
	bash tests/run.sh vendor

vendors:
	VENDORS="$(VENDORS)" FORCE="$(FORCE)" WORKSPACE="$(WORKSPACE)" WORK="$(WORK)" OUT="$(OUT)" bash scripts/build-vendors.sh

package:
	@if [ -z "$(UPSTREAM_TAG)" ]; then echo "usage: make package UPSTREAM_TAG=v2.0.24" >&2; exit 1; fi
	UPSTREAM_TAG="$(UPSTREAM_TAG)" WORKSPACE="$(WORKSPACE)" WORK="$(WORK)" OUT="$(OUT)" bash scripts/package.sh

apt-repo:
	bash scripts/apt-repo.sh --repo "$(APT_REPO_DIR)" --keep "$(KEEP)" \
		$(if $(filter 0,$(SIGN)),--no-sign) --key-file apt/opencode-android.gpg \
		$(OUT)/*.deb

clean:
	rm -rf work out upstream dist apt-repo
