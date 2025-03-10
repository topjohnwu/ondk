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
    set_build_cfg rust.use-lld self-contained
  fi

  set_llvm_cfg LLVM_ENABLE_PLUGINS FORCE_ON
  set_build_cfg llvm.thin-lto true
  set_build_cfg llvm.link-shared true
  set_build_cfg rust.lto thin

  cd rust
  eval python3 ./x.py --config ../config.toml --host $TRIPLE $(print_build_cfg) install
  cd ../

  cd out
  find . -name '*.old' -delete
  cp -af ../rust/build/$TRIPLE/llvm/bin llvm-bin
  cp -af lib/rustlib/$TRIPLE/bin/rust-lld llvm-bin/lld
  ln -sf lld llvm-bin/ld
  find ../rust/build/$TRIPLE/llvm/lib -name "*.${DYN_EXT}*" -exec cp -an {} lib \;
  local lib_llvm="libLLVM.${DYN_EXT}"
  if [ -L "lib/$lib_llvm" ]; then
    lib_llvm=$(readlink "lib/$lib_llvm")
  fi
  ln -s ../../../$lib_llvm lib/rustlib/$TRIPLE/lib/$lib_llvm
  strip_exe
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
