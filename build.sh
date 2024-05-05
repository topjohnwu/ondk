#!/usr/bin/env bash

# Copyright 2022-2024 Google LLC.
# SPDX-License-Identifier: Apache-2.0

. common.sh

OS=$(uname | tr '[:upper:]' '[:lower:]')
NATIVE_ARCH=$(uname -m)
if [ $NATIVE_ARCH = "arm64" ]; then
  # Apple calls aarch64 arm64
  NATIVE_ARCH='aarch64'
fi

if [ -z $ARCH ]; then
  # Build the native architecture by default
  ARCH=$NATIVE_ARCH
fi

if [ $OS = "darwin" ]; then
  NDK_DIRNAME='darwin-x86_64'
  TRIPLE="${ARCH}-apple-darwin"
  NATIVE_TRIPLE="${NATIVE_ARCH}-apple-darwin"
  DYN_EXT='dylib'
  EXE_FMT='Mach-O'

  # Hardcode to 16k page to support both x64 and arm64
  # export JEMALLOC_SYS_WITH_LG_PAGE=14

  command -v ninja >/dev/null || brew install ninja
  command -v zstd >/dev/null || brew install zstd
else
  NDK_DIRNAME='linux-x86_64'
  TRIPLE="${ARCH}-unknown-linux-gnu"
  NATIVE_TRIPLE="${NATIVE_ARCH}-unknown-linux-gnu"
  DYN_EXT='so'
  EXE_FMT='ELF'

  command -v cmake >/dev/null || sudo apt-get -y install cmake
  command -v ninja >/dev/null || sudo apt-get -y install ninja-build
  command -v clang-12 >/dev/null || sudo apt-get -y install clang-12
  command -v lld-12 >/dev/null || sudo apt-get -y install lld-12
  dpkg-query -W libzstd-dev >/dev/null 2>&1 || sudo apt-get -y install libzstd-dev
fi

build() {
  cd rust
  python3 ./x.py --config "../config-${OS}.toml" --host $TRIPLE install
  cd ../

  cd out
  find . -name '*.old' -delete
  cp -af ../rust/build/$TRIPLE/llvm/bin llvm-bin
  cp -af lib/rustlib/$TRIPLE/bin/rust-lld llvm-bin/lld
  ln -sf lld llvm-bin/ld
  find ../rust/build/$TRIPLE/llvm/lib -name "*.${DYN_EXT}*" -exec cp -an {} lib \;

  # Strip executables
  llvm-bin/llvm-strip -s $(find llvm-bin -type f -exec sh -c "file {} | grep -q $EXE_FMT" \; -print)
  llvm-bin/llvm-strip -s $(find lib -maxdepth 1 -type f -exec sh -c "file {} | grep -q $EXE_FMT" \; -print)

  cd ..
}

ndk() {
  dl_ndk

  # Copy the whole output folder into ndk
  cp -af out ndk/toolchains/rust

  cd ndk/toolchains

  local LLVM_DIR=llvm/prebuilt/$NDK_DIRNAME

  # Replace files with those from the rust toolchain
  update_dir rust/llvm-bin $LLVM_DIR/bin
  rm -rf rust/llvm-bin
  cd $LLVM_DIR/lib
  ln -sf ../../../../rust/lib/*.$DYN_EXT* .

  cd ../../../../../../
}


parse_args $@
