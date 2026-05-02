#!/usr/bin/env bash

set -euo pipefail

site_root="${1:-site}"
homepage="${site_root}/index.html"

if [[ ! -f "${homepage}" ]]; then
  echo "homepage not found: ${homepage}" >&2
  exit 1
fi

if rg -n 'href="[^"]+\.md"' "${homepage}" >/dev/null; then
  echo "homepage contains internal .md links" >&2
  rg -n 'href="[^"]+\.md"' "${homepage}" >&2
  exit 1
fi

echo "homepage links look good"
