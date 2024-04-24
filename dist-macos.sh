#!/usr/bin/env bash

# Copyright 2022-2024 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# This script is for generating universal binaries

set -e

xz -d < tmp/out.x64.tar.xz | tar x
mv out out.x64
xz -d < tmp/out.arm64.tar.xz | tar x
mv out out.arm64

cp -af out.x64 out
cp -an out.arm64/. out/. || true

# Merge all Mach-O files as universal binary and adhoc codesign
find out -type f -exec sh -c "file {} | grep -q Mach-O" \; -print0 | \
while IFS= read -r -d '' o; do
  a="${o/out/out.x64}"
  b="${o/out/out.arm64}"
  if [ -f "$a" -a -f "$b" ]; then
      lipo -create -output "$o" "$a" "$b"
  fi
  codesign -s - "$o"
done

./build.sh ndk dist
