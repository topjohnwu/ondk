#!/usr/bin/env bash

# Copyright 2022-2023 Google LLC.
# SPDX-License-Identifier: Apache-2.0

set -e

rm -rf rust llvm-project llvm_android toolchain-utils\
  out out.arm out.x86 ndk tmp mingw64 \
  android-ndk-*.zip ondk-* dist mingw.7z
