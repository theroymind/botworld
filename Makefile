.PHONY: run lint format format-check test check love ios

LOVE_FILE := build/botworld.love

run:
	love .

# Package the game as a .love (only what the game actually loads).
love:
	mkdir -p build
	rm -f $(LOVE_FILE)
	zip -9 -r -q $(LOVE_FILE) main.lua conf.lua lib assets -x '*.DS_Store'

# Build a dev-signed iOS app and push it to a connected iPhone.
# Prerequisites + overrides (TEAM_ID, DEVICE, BUNDLE_ID): see tools/ios.sh.
ios: love
	bash tools/ios.sh $(LOVE_FILE)

lint:
	luacheck . --no-color --quiet

format:
	stylua .

format-check:
	stylua --check .

# Run the spec suite. tests/run executes every tests/*_spec.lua as a plain
# Lua 5.1 / LuaJIT script (no busted) with the first interpreter it finds.
test:
	./tests/run

# Run all checks (CI-friendly): lint, formatting, and tests.
check: lint format-check test
