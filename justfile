# Notely developer tasks. Mirrors the Makefile; thin wrappers over scripts/.
# Run `just` to list recipes.

default:
    @just --list

# Install/verify toolchains and fetch dependencies
bootstrap:
    ./scripts/bootstrap.sh

# Run engine + desktop app together
dev:
    ./scripts/dev.sh

# Run the Rust engine
engine:
    ./scripts/start-engine.sh

# Run the Flutter desktop app
desktop:
    ./scripts/start-desktop.sh

# Format + lint (Rust and Flutter)
check:
    ./scripts/check.sh

# Run all tests
test:
    ./scripts/test.sh

# Release build of engine + desktop app
build:
    ./scripts/build.sh

# Fetch models described in models/manifests/
download-models:
    ./scripts/download-models.sh

# Verify required models are available
verify-models:
    ./scripts/verify-models.sh

# Delete local Notely data
reset-data:
    ./scripts/reset-data.sh
