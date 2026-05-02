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

if rg -n 'navigation\.tabs|md-nav--lifted' "${homepage}" >/dev/null; then
  echo "mobile nav still uses lifted tabs navigation" >&2
  rg -n 'navigation\.tabs|md-nav--lifted' "${homepage}" >&2
  exit 1
fi

if rg -n -U '@media \(max-width: 76\.2344em\)\s*\{[\s\S]*?\.md-sidebar--primary\s*\{[\s\S]*?width:' "${extra_css}" >/dev/null; then
  echo "mobile nav still overrides drawer width" >&2
  rg -n -U '@media \(max-width: 76\.2344em\)\s*\{[\s\S]*?\.md-sidebar--primary\s*\{[\s\S]*?width:' "${extra_css}" >&2
  exit 1
fi

echo "mobile nav looks simplified"
