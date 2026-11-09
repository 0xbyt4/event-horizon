.PHONY: build test app run install clean

build:
	swift build

test:
	swift test

app:
	./scripts/bundle.sh

run: app
	open "build/Event Horizon.app"

install: app
	rm -rf "/Applications/Event Horizon.app"
	cp -R "build/Event Horizon.app" "/Applications/Event Horizon.app"

clean:
	rm -rf .build build
