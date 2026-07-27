# meshyy — everything CI runs, runnable locally.
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
#
# Xcode is not the system default toolchain on the development Mac
# (xcode-select points at CommandLineTools), and swift-testing ships only with
# the Xcode toolchain — so DEVELOPER_DIR is not optional here. Without it
# `swift test` fails with "no such module 'Testing'".

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

SWIFT := swift

.PHONY: all check build test lint licences privacy headers cleanroom clean bench

all: check

## Everything CI runs. Do this before every push.
check: lint build test

build:
	$(SWIFT) build

test:
	$(SWIFT) test

lint: licences privacy headers cleanroom

## Design doc §0.3: fail on any dependency outside the allowlist.
licences:
	@scripts/check-licenses.sh

## Design doc §9: fail on any third-party endpoint or telemetry symbol.
privacy:
	@scripts/check-privacy.py

## Design doc §0.3: every file carries an MIT header.
headers:
	@scripts/check-headers.sh

## Design doc §0.1: structural proof no mosh source entered the tree.
cleanroom:
	@scripts/check-clean-room.sh

## Design doc §1 benchmark. Needs an ssh key in authorized_keys; see docs/benchmarks.md.
bench:
	$(SWIFT) build
	scripts/bench-attach.py --key ~/.ssh/meshyy_bench_ed25519 \
		--tmux "$$(which tmux)" --trials 7 --rtts 0,40,80,150,250 \
		--json-out docs/bench/attach-$$(date +%F).json

clean:
	$(SWIFT) package clean
	rm -rf .build
