#!/usr/bin/env bash

# Copyright 2022 Google LLC.
# SPDX-License-Identifier: Apache-2.0

set -e

. common.sh

OS=$(uname | tr '[:upper:]' '[:lower:]')
NATIVE_ARCH=$(uname -m)
if [ $NATIVE_ARCH = "arm64" ]; then
  # Apple calls aarch64 arm64
  NATIVE_ARCH='aarch64'
fi

if [ -z $1 ]; then
  # Build the native architecture by default
  ARCH=$NATIVE_ARCH
else
  ARCH=$1
fi

if [ $OS = "darwin" ]; then
  NDK_DIRNAME='darwin-x86_64'
  TRIPLE="${ARCH}-apple-darwin"
  NATIVE_TRIPLE="${NATIVE_ARCH}-apple-darwin"
  DYN_EXT='dylib'

  if [ $ARCH = "aarch64" ]; then
    # Apple Silicon uses 16k pages
    export JEMALLOC_SYS_WITH_LG_PAGE=14
  else
    export JEMALLOC_SYS_WITH_LG_PAGE=12
  fi

  command -v ninja >/dev/null || brew install ninja
else
  NDK_DIRNAME='linux-x86_64'
  TRIPLE="${ARCH}-unknown-linux-gnu"
  NATIVE_TRIPLE="${NATIVE_ARCH}-unknown-linux-gnu"
  DYN_EXT='so'

  command -v ninja >/dev/null || sudo apt-get install ninja-build
  command -v lld >/dev/null || sudo apt-get install lld
fi

build() {
  cd rust
  python3 ./x.py --config "../config-${OS}.toml" --host $TRIPLE install
  cd ../

  cd out
  cp -af ../rust/build/$TRIPLE/llvm/bin llvm-bin
  if [ $ARCH = "x86_64" ]; then
    cp -af $(../rust/build/$TRIPLE/llvm/bin/clang -print-resource-dir)/include clang-include
  fi
  cp -af lib/rustlib/$TRIPLE/bin/rust-lld llvm-bin/lld
  ln -sf lld llvm-bin/ld
  find ../rust/build/$TRIPLE/llvm/lib -name "*.${DYN_EXT}*" -exec cp -an {} lib \;
  cd ..
}

ndk() {
  local NDK_ZIP="android-ndk-${NDK_VERSION}-${OS}.zip"

  # Download and extract
  [ -f $NDK_ZIP ] || curl -O -L "https://dl.google.com/android/repository/$NDK_ZIP"
  unzip -q $NDK_ZIP
  mv "android-ndk-${NDK_VERSION}" ndk

  # Copy the whole output folder into ndk
  cp -af out ndk/toolchains/rust

  # Replace headers
  cd ndk/toolchains
  local NDK_RES=$(llvm/prebuilt/$NDK_DIRNAME/bin/clang -print-resource-dir)
  mv llvm/prebuilt/$NDK_DIRNAME llvm.dir
  ln -s ../../llvm.dir llvm/prebuilt/$NDK_DIRNAME
  rm -rf $NDK_RES/include
  mv rust/clang-include $NDK_RES/include

  # Replace files with those from the rust toolchain
  cd llvm.dir/bin
  ln -sf ../../rust/llvm-bin/* .
  rm clang-14
  cd ../lib64
  ln -sf ../../rust/lib/*.$DYN_EXT* .
  rm -f libclang.so.13 libclang-cpp.so.14git libLLVM-14git.so libLTO.so.14git libRemarks.so.14git
  cd ../..

  # Redirect library
  mkdir -p $(dirname $(llvm.dir/bin/clang -print-resource-dir))
  mv $NDK_RES $(llvm.dir/bin/clang -print-resource-dir)
  ln -s ../../rust/lib/clang llvm.dir/lib/clang
  cd ../..
}

universal() {
  cp -af out.x86 out
  cp -an out.arm/. out/. || true

  # Merge all Mach-O files as universal binary and adhoc codesign
  find out -type f -exec sh -c "file {} | grep -q Mach-O" \; -print0 | \
  while IFS= read -r -d '' o; do
    local a="${o/out/out.x86}"
    local b="${o/out/out.arm}"
    if [ -f "$a" -a -f "$b" ]; then
      lipo -create -output "$o" "$a" "$b"
    fi
    codesign -s - "$o"
  done
}

clone

if [ -n "$GITHUB_ACTION" -a $OS = "darwin" -a $ARCH = "aarch64" ]; then
  if [ ! -f tmp/stage-1.tar.gz ]; then
    echo '! Missing stage 1 artifacts'
    exit 1
  fi
  tar zxf tmp/stage-1.tar.gz
  mv out out.x86
  # FIXME: For some unknown reason, Mach-O larger than 8MB will always be corrupted
  cp -af rust/build/x86_64-apple-darwin/llvm/lib/*.dylib \
    rust/build/x86_64-apple-darwin/llvm/build/lib
  cp -af rust/build/x86_64-apple-darwin/llvm/bin/. \
    rust/build/x86_64-apple-darwin/llvm/build/bin
fi

build

if [ -n "$GITHUB_ACTION" -a $OS = "darwin" ]; then
  if [ $ARCH = "x86_64" ]; then
    # Pack up first stage artifacts
    mkdir tmp
    tar zcf tmp/stage-1.tar.gz rust/build/$TRIPLE/ll* out
    # Exit early
    exit 0
  else
    mv out out.arm
    universal
  fi
fi

ndk
dist
