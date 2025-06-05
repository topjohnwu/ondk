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
TRIPLE='x86_64-pc-windows-gnu'
DYN_EXT='dll'
EXE_FMT='PE32+'
PYTHON_CMD='python'

config_build() {
  set_llvm_cfg LLVM_USE_SYMLINKS ON
  set_llvm_cfg LLVM_USE_LINKER lld
  # BUG: llvm.use-libcxx will not actually set LLVM_ENABLE_LIBCXX
  set_llvm_cfg LLVM_ENABLE_LIBCXX ON
  # BUG: latest LLVM shipped with MSYS2 cannot build with LTO
  set_build_cfg llvm.thin-lto false
  # MinGW libstdc++ is incompatible with clang when LTO is enabled, we have to use libc++
  set_build_cfg llvm.use-libcxx true
  set_build_cfg rust.use-lld true
  set_build_cfg dist.include-mingw-linker true
}

build_lld() {
  mkdir -p out/lld/build
  cd out/lld/build
  cmake -G Ninja ../../../src/llvm-project/llvm \
    -DCMAKE_INSTALL_PREFIX=../ -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_PROJECTS=lld \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DLLVM_USE_LINKER=lld \
    -DLLVM_ENABLE_LIBCXX=ON -DLLVM_STATIC_LINK_CXX_STDLIB=ON \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_BUILD_TOOLS=OFF -DLLVM_USE_SYMLINKS=ON -DLLVM_VERSION_SUFFIX='' \
    -DLLVM_TARGETS_TO_BUILD="AArch64;ARM;X86;RISCV" \
    -DCMAKE_EXE_LINKER_FLAGS="-s -static -static-libgcc"
  cmake --build . --target install
  cd ../../../
}

collect() {
  cp -af out/rust out/collect
  cd out/collect

  local RUST_BUILD=../../src/rust/build

  find . -name '*.old' -delete
  cp -af $RUST_BUILD/$TRIPLE/llvm/bin llvm-bin || true
  cp -an $RUST_BUILD/$TRIPLE/llvm/bin/. llvm-bin/.
  cp -af ../lld/bin/. llvm-bin/. || true
  cp -an ../lld/bin/. llvm-bin/.
  cp -af $RUST_BUILD/tmp/dist/lib/rustlib/. lib/rustlib/.

  local MINGW_DIR=lib/rustlib/$TRIPLE/bin/self-contained

  # Copy runtime dlls
  cp_sys_dlls bin/rustc.exe
  cp_sys_dlls llvm-bin/clang.exe
  cp_sys_dlls $MINGW_DIR/ld.exe
  cp_sys_dlls $MINGW_DIR/x86_64-w64-mingw32-gcc.exe

  strip_exe $RUST_BUILD/$TRIPLE/llvm/bin/llvm-strip.exe
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

export PATH='/c/Program Files/Git/cmd':$PATH

parse_args $@
