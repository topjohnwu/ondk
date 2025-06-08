#!/usr/bin/env bash

# Copyright 2022-2025 Google LLC.
# SPDX-License-Identifier: Apache-2.0

if ! uname | grep -q 'MINGW64_NT'; then
  echo 'This script should run on MSYS2 bash'
  echo
  exit 1
fi

export MSYS=winsymlinks:nativestrict

. common.sh

OS='windows'
NDK_DIRNAME='windows-x86_64'
ARCH='x86_64'
TRIPLE='x86_64-pc-windows-gnu'
DYN_EXT='dll'
EXE_FMT='PE32+'
PYTHON_CMD='python'

config_rust_build() {
  # MinGW libstdc++ is incompatible with clang when LTO is enabled, we have to use libc++
  set_build_cfg llvm.use-libcxx true
  set_build_cfg rust.use-lld true
  set_build_cfg dist.include-mingw-linker true

  # Expose all LLVM dlls to stage1 rustc
  mkdir -p out/llvm/dlls
  cp -af out/llvm/bin/*.dll out/llvm/dlls
  export PATH="$(realpath out/llvm/dlls):$PATH"
}

config_llvm() {
  unset LLVM_BUILD_CFG
  common_config_llvm
  set_llvm_cfg CMAKE_C_COMPILER clang
  set_llvm_cfg CMAKE_CXX_COMPILER clang++
  set_llvm_cfg LLVM_USE_LINKER lld
  set_llvm_cfg LLVM_ENABLE_LIBCXX ON
  set_llvm_cfg LLVM_STATIC_LINK_CXX_STDLIB ON
  set_llvm_cfg LLVM_USE_SYMLINKS ON
}

build_lld() {
  mkdir -p out/lld/build
  cd out/lld/build

  config_llvm
  set_llvm_cfg LLVM_ENABLE_PROJECTS lld
  set_llvm_cfg LLVM_BUILD_TOOLS OFF
  set_llvm_cfg CMAKE_EXE_LINKER_FLAGS "-s -static -static-libgcc"

  eval cmake -G Ninja ../../../src/llvm-project/llvm $LLVM_BUILD_CFG
  cmake --build . --target install
  cd ../../../
}

build_llvm() {
  mkdir -p out/llvm/build
  cd out/llvm/build

  config_llvm
  set_llvm_cfg LLVM_ENABLE_PROJECTS clang
  set_llvm_cfg LLVM_LINK_LLVM_DYLIB ON
  # BUG: latest LLVM shipped with MSYS2 cannot build with LTO
  # set_llvm_cfg LLVM_ENABLE_LTO Thin

  eval cmake -G Ninja ../../../src/llvm-project/llvm $LLVM_BUILD_CFG
  cmake --build . --target install
  cd ../../../

  # We have to build LLD statically to prevent flakiness
  build_lld
}

collect() {
  cp -af out/rust out/collect
  cd out/collect

  local RUST_BUILD=../../src/rust/build

  find . -name '*.old' -delete
  cp -af ../llvm/bin llvm-bin || true
  cp -an ../llvm/bin/. llvm-bin/.
  cp -af ../lld/bin/. llvm-bin/. || true
  cp -an ../lld/bin/. llvm-bin/.
  cp -af $RUST_BUILD/tmp/dist/lib/rustlib/. lib/rustlib/.

  local MINGW_DIR=lib/rustlib/$TRIPLE/bin/self-contained

  # Copy runtime dlls
  cp_sys_dlls bin/rustc.exe
  cp_sys_dlls llvm-bin/clang.exe
  cp_sys_dlls $MINGW_DIR/ld.exe
  cp_sys_dlls $MINGW_DIR/x86_64-w64-mingw32-gcc.exe

  strip_exe
  cd ../../
}

cp_sys_dlls() {
  local dir=$(dirname $1)
  for lib in $(ldd $1 | grep ' /mingw64/bin/' | awk '{ print $1 }'); do
    cp -v /mingw64/bin/$lib $dir
  done
}

ndk() {
  dl_ndk
  cd out

  # Copy the whole output folder into ndk
  cp -af collect ndk/toolchains/rust || true
  cp -an collect/. ndk/toolchains/rust/.

  cd ndk/toolchains

  local LLVM_DIR=llvm/prebuilt/$NDK_DIRNAME

  # First copy over all runtime dlls
  cp -af rust/llvm-bin/*.dll $LLVM_DIR/bin

  # Replace files with those from the rust toolchain
  touch $LLVM_DIR/bin/lld.exe
  ln -sf lld.exe $LLVM_DIR/bin/ld.exe
  update_dir rust/llvm-bin $LLVM_DIR/bin
  rm -rf rust/llvm-bin

  cd ../../../
}

export PATH="$PATH:/c/Program Files/Git/cmd"

parse_args $@
