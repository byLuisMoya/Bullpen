SHELL := /bin/bash
ENV := source Scripts/env.sh &&

.PHONY: build test app run clean bench demo demo-stop

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
