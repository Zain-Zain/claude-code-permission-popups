.PHONY: build test app install uninstall clean

PREFIX ?= /Applications
APP_NAME := Permission Popups

build:
	swift build

test:
	swift test
	scripts/integration-test.sh

app:
	scripts/build-app.sh

install: app
	osascript -e 'quit app "$(APP_NAME)"' || true
	sleep 1
	rm -rf "$(PREFIX)/$(APP_NAME).app"
	ditto "dist/$(APP_NAME).app" "$(PREFIX)/$(APP_NAME).app"
	open "$(PREFIX)/$(APP_NAME).app"

uninstall:
	@echo "Reminder: uninstall the hook from the menu bar app first (Permission Popups menu)."
	osascript -e 'quit app "$(APP_NAME)"' || true
	sleep 1
	rm -rf "$(PREFIX)/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf dist
