#!/usr/bin/env bash

set -euo pipefail

site_root="${1:-site}"
homepage="${site_root}/index.html"
extra_css="${site_root}/stylesheets/extra.css"

if [[ ! -f "${homepage}" ]]; then
  echo "homepage not found: ${homepage}" >&2
  exit 1
fi

if [[ ! -f "${extra_css}" ]]; then
  echo "extra stylesheet not found: ${extra_css}" >&2
  exit 1
fi

if ! rg -n 'acwj-compat-warning' "${homepage}" >/dev/null; then
  echo "compatibility notice marker missing from homepage" >&2
  exit 1
fi

if ! rg -n 'CSS\.supports\("color", "color-mix\(in srgb, black 50%, white\)"\)|CSS\.supports\("backdrop-filter", "blur\(1px\)"\)' "${homepage}" >/dev/null; then
  echo "browser feature detection marker missing from homepage" >&2
  exit 1
fi

if ! rg -n '@supports not \(color: color-mix\(in srgb, black 50%, white\)\)|@supports \(color: color-mix\(in srgb, black 50%, white\)\)|@supports not \(backdrop-filter: blur\(1px\)\)' "${extra_css}" >/dev/null; then
  echo "compatibility fallback markers missing from extra stylesheet" >&2
  exit 1
fi

echo "browser compatibility fallback markers look good"
