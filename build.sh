#!/usr/bin/env bash

# Copyright 2022 Google LLC.
# SPDX-License-Identifier: Apache-2.0

set -e

if [ -z $1 ]; then
  echo "Usage: $0 <arch>"
  echo "<arch> is either x86_64 or aarch64"
  echo
  exit 1
fi

. common.sh

OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH="$1"

if [ $OS = "darwin" ]; then
  NDK_DIRNAME='darwin-x86_64'
  TRIPLE="${ARCH}-apple-darwin"
  DYN_EXT='dylib'

  if [ $ARCH = "aarch64" ]; then
    # Configure jemalloc to use 16k pages for Apple Silicon
    export JEMALLOC_SYS_WITH_LG_PAGE=14
  fi

  command -v ninja >/dev/null || brew install ninja
else
  NDK_DIRNAME='linux-x86_64'
  TRIPLE="${ARCH}-unknown-linux-gnu"
  DYN_EXT='so'

  command -v ninja >/dev/null || sudo apt-get install ninja-build
fi

build() {
  cd rust
  python3 ./x.py --config "../config-${OS}.toml" --host $TRIPLE install
  cd ../

  cd out
  cp -af ../rust/build/$TRIPLE/llvm/bin llvm-bin
  cp -af ../rust/build/$TRIPLE/llvm/lib/clang/$RUST_CLANG/include clang-include
  cp -af lib/rustlib/$TRIPLE/bin/rust-lld llvm-bin/lld
  ln -s lld llvm-bin/ld
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
  mv llvm/prebuilt/$NDK_DIRNAME llvm.dir
  ln -s ../../llvm.dir llvm/prebuilt/$NDK_DIRNAME
  rm -rf llvm.dir/lib64/clang/$NDK_CLANG/include
  mv rust/clang-include llvm.dir/lib64/clang/$NDK_CLANG/include

  # Redirect library
  cd rust/lib
  mkdir clang
  ln -s ../../../llvm.dir/lib64/clang/$NDK_CLANG clang/$RUST_CLANG
  cd ../../

  # Replace files with those from the rust toolchain
  cd llvm.dir/bin
  ln -sf ../../rust/llvm-bin/* .
  rm clang-14
  cd ../lib64
  ln -sf ../../rust/lib/*.$DYN_EXT* .
  rm -f libclang.so.13 libLLVM-14git.so libLTO.so.14git libRemarks.so.14git

  # Redirect library
  cd ../lib
  mkdir clang
  ln -s ../../lib64/clang/$NDK_CLANG clang/$RUST_CLANG
  cd ../../../../
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

if [ $OS = "darwin" -a $ARCH = "aarch64" ]; then
  if [ ! -f tmp/stage-1.tar.gz ]; then
    echo '! Missing stage 1 artifacts'
    exit 1
  fi
  tar zxf tmp/stage-1.tar.gz
  mv out out.x86
fi

build

if [ $OS = "darwin" ]; then
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
