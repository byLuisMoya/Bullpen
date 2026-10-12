SHELL := /bin/bash
ENV := source Scripts/env.sh &&

.PHONY: build test app run clean

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
