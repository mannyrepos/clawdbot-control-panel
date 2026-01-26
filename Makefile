.PHONY: build install clean

build:
	@./build.sh

install:
	@./install.sh

clean:
	rm -rf build/

run: build
	open "build/Clawdbot Control.app"
