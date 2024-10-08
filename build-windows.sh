#!/usr/bin/env bash

# Copyright 2022-2024 Google LLC.
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

clean_storage() {
  # Clean up storage to fit in all our build output
  rm -rf /c/SeleniumWebDrivers /c/selenium /c/Android /c/tools /c/Modules \
    '/c/Program Files/PostgreSQL' '/c/Program Files/dotnet' \
    "$JAVA_HOME_8_X64" "$JAVA_HOME_11_X64" "$JAVA_HOME_17_X64" \
    "$GOROOT_1_15_X64" "$GOROOT_1_16_X64" "$GOROOT_1_17_X64" "$GOROOT_1_18_X64"
}

build() {
  set_llvm_cfg LLVM_USE_SYMLINKS TRUE
  set_llvm_cfg LLVM_ENABLE_LLD TRUE
  set_build_cfg rust.use-lld self-contained
  set_build_cfg dist.include-mingw-linker true

  cd rust
  eval python ./x.py --config ../config.toml --build $TRIPLE $(print_build_cfg) install
  cd ../

  cd out
  find . -name '*.old' -delete
  cp -af ../rust/build/$TRIPLE/llvm/bin llvm-bin || true
  cp -an ../rust/build/$TRIPLE/llvm/bin/. llvm-bin/.
  cp -af lib/rustlib/$TRIPLE/bin/rust-lld.exe llvm-bin/lld.exe
  cp -af ../rust/build/tmp/dist/lib/rustlib/. lib/rustlib/.

  local MINGW_DIR=lib/rustlib/$TRIPLE/bin/self-contained

  # Copy runtime dlls
  cp_sys_dlls bin/rustc.exe
  cp_sys_dlls llvm-bin/clang.exe
  cp_sys_dlls $MINGW_DIR/ld.exe
  cp_sys_dlls $MINGW_DIR/x86_64-w64-mingw32-gcc.exe
  cd ..
}

cp_sys_dlls() {
  local dir=$(dirname $1)
  for lib in $(ldd $1 | grep ' /ucrt64/bin/' | awk '{ print $1 }'); do
    cp /ucrt64/bin/$lib $dir
  done
}

ndk() {
  dl_ndk

  # Copy the whole output folder into ndk
  cp -af out ndk/toolchains/rust || true
  cp -an out/. ndk/toolchains/rust/.

  cd ndk/toolchains

  local LLVM_DIR=llvm/prebuilt/$NDK_DIRNAME

  # First copy over all runtime dlls
  cp -af rust/llvm-bin/*.dll $LLVM_DIR/bin

  # Replace files with those from the rust toolchain
  touch $LLVM_DIR/bin/lld.exe
  update_dir rust/llvm-bin $LLVM_DIR/bin
  rm -rf rust/llvm-bin
  ln -sf lld.exe $LLVM_DIR/bin/ld.exe
  ln -sf lld.exe $LLVM_DIR/bin/ld.lld.exe

  cd ../..
}

export PATH='/c/Program Files/Git/cmd':$PATH

if [ -n "$GITHUB_ACTION" ]; then
  clean_storage
fi

parse_args $@
