SHELL := /bin/bash
ENV := source Scripts/env.sh &&

.PHONY: build test app run clean bench demo demo-stop icons release

build:
	$(ENV) swift build "$${SWIFT_EXTRA_FLAGS[@]}"

test:
	$(ENV) swift test "$${SWIFT_EXTRA_FLAGS[@]}"

app:
	Scripts/build-app.sh

run: app
	open build/Bullpen.app

clean:
	rm -rf .build build

# Terminal engine benchmark (ADR 0002). Local only; results land in docs/bench/.
bench:
	$(ENV) cd Benchmarks/TerminalBench && \
	  if [[ "$$(xcode-select -p)" != *CommandLineTools* ]]; then export TERMINALBENCH_XCODE=1; fi && \
	  swift build -c release && "$$(swift build -c release --show-bin-path)/TerminalBench" --out ../../docs/bench

# Demo projects with simulated agents (no tokens spent). Remove with `make demo-stop`.
demo: app
	Scripts/demo.sh start
	open build/Bullpen.app

demo-stop:
	Scripts/demo.sh stop

# Regenerate the app icon and the seasonal Dock icons (needs node; outputs are committed).
icons:
	node Tools/icon/art.js /tmp/bullpen-icon-art.json
	python3 Tools/icon/render.py /tmp/bullpen-icon-art.json Resources

# Distribution build (no demo) zipped for a GitHub release: build/release/Bullpen-<version>-universal.zip + SHA256SUMS.txt
release:
	DIST=1 Scripts/build-app.sh
	@version=$$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/BPCore/Bullpen.swift); \
	rm -rf build/release && mkdir -p build/release && \
	ditto -c -k --keepParent build/Bullpen.app "build/release/Bullpen-$$version-universal.zip" && \
	(cd build/release && shasum -a 256 "Bullpen-$$version-universal.zip" > SHA256SUMS.txt && cat SHA256SUMS.txt)
