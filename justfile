set quiet

_:
    @just --list

# Build zig-out/bin/recurse
build:
    zig build

# Serve docs at http://127.0.0.1:8000
site:
    python3 -m http.server 8000 --bind 127.0.0.1 --directory docs
