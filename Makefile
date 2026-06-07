.PHONY: run lint format format-check check

run:
	love .

lint:
	luacheck . --no-color --quiet

format:
	stylua .

format-check:
	stylua --check .

check: lint format-check
