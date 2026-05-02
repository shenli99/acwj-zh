#!/usr/bin/env bash

set -euo pipefail

site_root="${1:-site}"
homepage="${site_root}/index.html"

if [[ ! -f "${homepage}" ]]; then
  echo "homepage not found: ${homepage}" >&2
  exit 1
fi

if rg -n -U 'href="01_Scanner/Readme/" class="md-nav__link">[\s\S]{0,200}第 01 部分|href="35_Preprocessor/Readme/" class="md-nav__link">[\s\S]{0,200}第 35 部分|href="64_6809_Target/Readme/" class="md-nav__link">[\s\S]{0,200}第 64 部分' "${homepage}" >/dev/null; then
  echo "old numeric tutorial labels still appear in sidebar navigation" >&2
  rg -n -U 'href="01_Scanner/Readme/" class="md-nav__link">[\s\S]{0,200}第 01 部分|href="35_Preprocessor/Readme/" class="md-nav__link">[\s\S]{0,200}第 35 部分|href="64_6809_Target/Readme/" class="md-nav__link">[\s\S]{0,200}第 64 部分' "${homepage}" >&2
  exit 1
fi

for pair in \
  '01_Scanner/Readme/:词法扫描' \
  '35_Preprocessor/Readme/:预处理器' \
  '64_6809_Target/Readme/:8 位自编译'
do
  path="${pair%%:*}"
  label="${pair#*:}"
  if ! rg -n -U "href=\"${path}\" class=\"md-nav__link\">[\\s\\S]{0,200}${label}" "${homepage}" >/dev/null; then
    echo "expected short tutorial label missing: ${label}" >&2
    exit 1
  fi
done

echo "short tutorial nav labels look good"
