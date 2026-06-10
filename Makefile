.PHONY: setup run lint format format-check test check love ios

LOVE_FILE := build/botworld.love

# First-run setup: fetch the lib/love-ui submodule (the UI kit). Needed after a
# plain `git clone`, or any pull that moves the submodule pointer -- without it
# lib/love-ui is empty and the game fails to load (module 'lib.love-ui' not found).
setup:
	git submodule update --init --recursive

run:
	love .

# Package the game as a .love (only what the game actually loads). lib includes
# the lib/love-ui submodule; keep its git metadata out of the archive.
love:
	mkdir -p build
	rm -f $(LOVE_FILE)
	zip -9 -r -q $(LOVE_FILE) main.lua conf.lua lib assets -x '*.DS_Store' -x 'lib/love-ui/.git/*'

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
