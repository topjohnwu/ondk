#!/usr/bin/env bash

# Copyright 2022-2023 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# This script is for generating universal binaries
# The arm64 output should be archived to "ondk-macos-arm64.tar.gz"
# The x86_64 output should be placed in the folder "out"

set -e

mv out out.x86
tar zxf ondk-macos-arm64.tar.gz
mv out out.arm

cp -af out.x86 out
cp -an out.arm/. out/. || true

# Merge all Mach-O files as universal binary and adhoc codesign
find out -type f -exec sh -c "file {} | grep -q Mach-O" \; -print0 | \
while IFS= read -r -d '' o; do
  a="${o/out/out.x86}"
  b="${o/out/out.arm}"
  if [ -f "$a" -a -f "$b" ]; then
      lipo -create -output "$o" "$a" "$b"
  fi
  codesign -s - "$o"
done

DIST_ONLY=1 ./build.sh
