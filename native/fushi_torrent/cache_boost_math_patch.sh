#!/usr/bin/env bash
# Seed the pinned vcpkg distfile from an equivalent URL. The canonical
# boostorg URL has returned HTTP 503 even after vcpkg retried it.
set -euo pipefail

downloads="${VCPKG_DOWNLOADS:-${1:?expected vcpkg root}/downloads}"
name=boost_math_android.patch
sha=19b6cf82f2e10b0154227e8e31eb892f3ca8899dd3946b909088be13b322a8881ff91b8aec2e2d099140f170f1d76547034e4def56ece347b6b52dbabeb1cf51
mkdir -p "$downloads"

verify() {
  printf '%s  %s\n' "$sha" "$1" | sha512sum --check --status
}

if verify "$downloads/$name" 2>/dev/null; then
  exit 0
fi

tmp="$(mktemp "$downloads/$name.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
curl --fail --silent --show-error --location --retry 3 --max-time 30 \
  'https://github.com/boostorg/math/commit/05d9f24f080f2c02ca34967c802f46851736e830.patch?full_index=1&download=1' \
  --output "$tmp"
if ! verify "$tmp"; then
  echo "Boost Math patch does not match the SHA-512 pinned by vcpkg." >&2
  exit 1
fi
mv -f "$tmp" "$downloads/$name"
