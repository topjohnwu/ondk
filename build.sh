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
  export PATH="$(brew --prefix)/opt/gpatch/libexec/gnubin:$PATH"
  export MACOSX_DEPLOYMENT_TARGET=11.0
else
  NDK_DIRNAME='linux-x86_64'
  TRIPLE="${ARCH}-unknown-linux-gnu"
  NATIVE_TRIPLE="${NATIVE_ARCH}-unknown-linux-gnu"
  DYN_EXT='so'
  EXE_FMT='ELF'
fi

config_rust_build() {
  if [ $OS = "darwin" ]; then
    export DYLD_FALLBACK_LIBRARY_PATH="$(realpath out/llvm/lib)"
  else
    set_build_cfg rust.use-lld true
    export LD_LIBRARY_PATH="$(realpath out/llvm/lib)"
  fi
}

build_llvm() {
  mkdir -p out/llvm/build
  cd out/llvm/build

  common_config_llvm

  if [ $OS = "darwin" ]; then
    set_llvm_cfg LLVM_BINUTILS_INCDIR $(brew --prefix)/opt/binutils/include
  else
    set_llvm_cfg LLVM_BINUTILS_INCDIR /usr/include
    set_llvm_cfg CMAKE_C_COMPILER clang-19
    set_llvm_cfg CMAKE_CXX_COMPILER clang++-19
    set_llvm_cfg LLVM_USE_LINKER lld
    set_llvm_cfg LLVM_STATIC_LINK_CXX_STDLIB ON
  fi

  set_llvm_cfg LLVM_ENABLE_PROJECTS "clang;lld"
  set_llvm_cfg LLVM_ENABLE_LTO Thin
  set_llvm_cfg LLVM_ENABLE_PLUGINS FORCE_ON
  set_llvm_cfg LLVM_LINK_LLVM_DYLIB ON

  eval cmake -G Ninja ../../../src/llvm-project/llvm $LLVM_BUILD_CFG
  cmake --build . --target install
  cd ../../../
}

collect() {
  cp -af out/rust out/collect
  cd out/collect

  find . -name '*.old' -delete
  cp -af ../llvm/bin llvm-bin
  find ../llvm/lib -name "*.${DYN_EXT}*" -exec cp -an {} lib \;
  strip_exe
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
