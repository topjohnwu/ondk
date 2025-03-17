#!/usr/bin/env bash

# Copyright 2022-2025 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# This script is for generating universal binaries

set -e

xz -d < tmp/out.x64.tar.xz | tar x
mv out/collect out/collect.x64
xz -d < tmp/out.arm64.tar.xz | tar x
mv out/collect out/collect.arm64

cp -af out/collect.x64 out/collect
cp -an out/collect.arm64/. out/collect/. || true

# Merge all Mach-O files as universal binary and adhoc codesign
find out/collect -type f -exec sh -c "file {} | grep -q Mach-O" \; -print0 | \
while IFS= read -r -d '' o; do
  a="${o/collect/collect.x64}"
  b="${o/collect/collect.arm64}"
  if [ -f "$a" -a -f "$b" ]; then
      lipo -create -output "$o" "$a" "$b"
  fi
  codesign -s - "$o"
done

./build.sh ndk dist
