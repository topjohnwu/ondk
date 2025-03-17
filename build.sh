#!/usr/bin/env bash

# Copyright 2022-2025 Google LLC.
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
  # Always use GNU patch
  export PATH="$(brew --prefix)/opt/gpatch/bin:$PATH"
else
  NDK_DIRNAME='linux-x86_64'
  TRIPLE="${ARCH}-unknown-linux-gnu"
  NATIVE_TRIPLE="${NATIVE_ARCH}-unknown-linux-gnu"
  DYN_EXT='so'
  EXE_FMT='ELF'
fi

build() {
  if [ $OS = "darwin" ]; then
    export MACOSX_DEPLOYMENT_TARGET=11.0
    # Manually set page size if cross compilation is required (arm64 require 16k page)
    # export JEMALLOC_SYS_WITH_LG_PAGE=14

    set_llvm_cfg LLVM_BINUTILS_INCDIR $(brew --prefix)/opt/binutils/include
    set_build_cfg rust.jemalloc true
  else
    set_llvm_cfg LLVM_BINUTILS_INCDIR /usr/include
    set_build_cfg llvm.static-libstdcpp true
    set_build_cfg rust.use-lld true
  fi

  set_llvm_cfg LLVM_ENABLE_PLUGINS FORCE_ON

  cd src/rust
  eval python3 ./x.py --config ../../config.toml --host $TRIPLE $(print_build_cfg) install
  cd ../../
}

collect() {
  cp -af out/rust out/collect
  cd out/collect

  local RUST_BUILD=../../src/rust/build

  find . -name '*.old' -delete
  cp -af $RUST_BUILD/$TRIPLE/llvm/bin llvm-bin
  find $RUST_BUILD/$TRIPLE/llvm/lib -name "*.${DYN_EXT}*" -exec cp -an {} lib \;
  strip_exe llvm-bin/llvm-strip
  cd ../../
}

ndk() {
  dl_ndk
  cd out

  # Copy the whole output folder into ndk
  cp -af collect ndk/toolchains/rust

  cd ndk/toolchains

  local LLVM_DIR=llvm/prebuilt/$NDK_DIRNAME

  # Replace files with those from the rust toolchain
  update_dir rust/llvm-bin $LLVM_DIR/bin
  rm -rf rust/llvm-bin
  cd $LLVM_DIR/lib
  ln -sf ../../../../rust/lib/*.$DYN_EXT* .

  cd ../../../../../../../
}


parse_args $@
