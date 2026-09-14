#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors
set -euo pipefail

git diff --check

bad=0
while IFS= read -r -d '' file; do
  case "$file" in
    *.bit|*.dcp|*.vvp|*.jou|*.log|*.lic|license.dat|uiFDMA.v)
      echo "Forbidden generated, licensed, or external file is tracked: $file"
      bad=1
      ;;
  esac
  size=$(wc -c < "$file")
  if (( size > 52428800 )); then
    echo "Tracked file exceeds 50 MiB policy: $file ($size bytes)"
    bad=1
  fi
done < <(git ls-files -z)

if (( bad != 0 )); then
  exit 1
fi

echo "Repository policy checks passed."