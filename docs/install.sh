#!/bin/sh
set -eu

base=https://github.com/krakjn/recurse/releases/latest/download
dest=${HOME}/.local/bin

command -v curl >/dev/null 2>&1 || {
  echo "curl is required" >&2
  exit 1
}

os=$(uname -s)
arch=$(uname -m)
case "$arch" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *)
    echo "no build for $os $arch" >&2
    exit 1
    ;;
esac

musl=0
if [ "$os" = Linux ]; then
  if [ -f /etc/alpine-release ]; then
    musl=1
  elif command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    musl=1
  fi
fi

case "$os-$arch" in
  Linux-x86_64)
    if [ "$musl" -eq 1 ]; then
      name=recurse-x86_64-linux-musl
    else
      name=recurse-x86_64-linux
    fi
    ;;
  Linux-aarch64)
    if [ "$musl" -eq 1 ]; then
      echo "no musl build for aarch64" >&2
      exit 1
    fi
    name=recurse-aarch64-linux
    ;;
  Darwin-aarch64) name=recurse-aarch64-macos ;;
  Darwin-x86_64) name=recurse-x86_64-macos ;;
  *)
    echo "no build for $os $arch" >&2
    exit 1
    ;;
esac

archive=${name}.tar.gz
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$base/$archive" -o "$tmp/$archive"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
sum=$(grep -F "  ${archive}" "$tmp/SHA256SUMS" || true)
if [ -z "$sum" ]; then
  echo "SHA256SUMS has no ${archive}" >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  checker='sha256sum -c -'
else
  checker='shasum -a 256 -c -'
fi
if ! printf '%s\n' "$sum" | (cd "$tmp" && $checker); then
  echo "checksum mismatch for $archive" >&2
  exit 1
fi

tar -xzf "$tmp/$archive" -C "$tmp"
mkdir -p "$dest"
install -m 755 "$tmp/$name" "$dest/recurse"

echo "installed $dest/recurse"
case ":$PATH:" in
  *":$dest:"*) ;;
  *) echo "add $dest to PATH" >&2 ;;
esac
