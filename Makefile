.PHONY: build release bundle install uninstall set-default run validate browsers clean

# Debug build of the binary.
build:
	swift build

# Optimized build.
release:
	swift build -c release

# Assemble build/brouter.app (release).
bundle:
	./scripts/bundle.sh release

# Build, install to /Applications (or ~/Applications), and start the agent.
install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

# Set the installed brouter.app as the default http/https handler.
set-default:
	@APP=$$( [ -d /Applications/brouter.app ] && echo /Applications/brouter.app || echo $$HOME/Applications/brouter.app ); \
	echo "Using $$APP"; \
	"$$APP/Contents/MacOS/brouter" set-default "$$APP"

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
	rm -rf .build build
