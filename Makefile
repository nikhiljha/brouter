.PHONY: build release bundle dmg install uninstall set-default run validate browsers route clean

# Debug build of the binary.
build:
	swift build

# Optimized build.
release:
	swift build -c release

# Assemble build/brouter.app (release).
bundle:
	./scripts/bundle.sh release

# Build a release DMG:  make dmg VERSION=2026.09.22-1
dmg:
	./scripts/dmg.sh "$(VERSION)"

# Build, install to /Applications (or ~/Applications), and start the agent.
install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

# Set the installed brouter.app as the default http/https handler.
set-default:
	@APP=$$( [ -d /Applications/brouter.app ] && echo /Applications/brouter.app || echo $$HOME/Applications/brouter.app ); \
	"$$APP/Contents/MacOS/brouter" set-default

# Run the agent in the foreground (for debugging; Ctrl-C to stop).
run: build
	.build/debug/brouter

# Validate the config.
validate: build
	.build/debug/brouter validate

# List configured browsers.
browsers: build
	.build/debug/brouter browsers

# Dry-run a URL:  make route URL=https://github.com/x/y
route: build
	.build/debug/brouter route "$(URL)"

clean:
	rm -rf .build build dist
