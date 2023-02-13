#!/usr/bin/env bash

# Copyright 2022 Google LLC.
# SPDX-License-Identifier: Apache-2.0

set -e

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

link() {
  local BASE="$(realpath -s "$PWD")"
  local TARGET="$(realpath -s "$2")"
  if [ ! -d "$TARGET" ]; then
    local NAME="$(basename "$TARGET")"
    local TARGET="$(dirname "$TARGET")"
  else
    local NAME="$(basename "$1")"
  fi
  local SRC="$(realpath -s --relative-to="$TARGET" "$1")"
  cd "$TARGET"
  ln -sf "$SRC" "$NAME"
  cd "$BASE"
}

clean_storage() {
  # Clean up storage to fit in all our build output
  rm -rf /c/SeleniumWebDrivers /c/selenium /c/Android /c/tools /c/Modules \
    '/c/Program Files/PostgreSQL' '/c/Program Files/dotnet' \
    "$JAVA_HOME_8_X64" "$JAVA_HOME_11_X64" "$JAVA_HOME_17_X64" \
    "$GOROOT_1_15_X64" "$GOROOT_1_16_X64" "$GOROOT_1_17_X64" "$GOROOT_1_18_X64"
}

build() {
  cd rust
  python ./x.py \
    --config '../config-windows.toml' \
    --build $TRIPLE install
  cd ../

  RUST_CLANG=$(rust/build/$TRIPLE/llvm/bin/llvm-config --version)

  cd out
  cp -af ../rust/build/$TRIPLE/llvm/bin llvm-bin
  cp -af ../rust/build/$TRIPLE/lld/bin/. llvm-bin/.
  link llvm-bin/lld.exe llvm-bin/ld.exe
  cp -af ../rust/build/$TRIPLE/llvm/lib/clang/$RUST_CLANG/include clang-include
  cd ..
}

ndk() {
  local NDK_ZIP="android-ndk-${NDK_VERSION}-${OS}.zip"

  # Download and extract
  [ -f $NDK_ZIP ] || curl -O -L "https://dl.google.com/android/repository/$NDK_ZIP"
  unzip -q $NDK_ZIP
  mv "android-ndk-${NDK_VERSION}" ndk

  curl -o mingw.7z -O -L "https://github.com/niXman/mingw-builds-binaries/releases/download/12.2.0-rt_v10-rev2/x86_64-12.2.0-release-win32-seh-ucrt-rt_v10-rev2.7z"
  7z x mingw.7z

  # Copy the whole output folder into ndk
  cp -af out ndk/toolchains/rust

  cd ndk/toolchains
  local LLVM_DIR=llvm/prebuilt/$NDK_DIRNAME

  # Replace headers
  rm -rf $LLVM_DIR/lib64/clang/$NDK_CLANG/include
  mv rust/clang-include $LLVM_DIR/lib64/clang/$NDK_CLANG/include

  # Move library
  mkdir -p $LLVM_DIR/lib/clang
  mv $LLVM_DIR/lib64/clang/$NDK_CLANG $LLVM_DIR/lib/clang/$RUST_CLANG

  # Replace llvm files with those from the rust toolchain
  for b in $LLVM_DIR/bin/*; do
    local a="rust/llvm-bin/$(basename $b)"
    if [ -f $a ] && [ ! -L $a ]; then
      cp -af $a $b
    elif [ -L $a ]; then
      local c="$(realpath $a)"
      local d=$LLVM_DIR/bin/$(basename $c)
      cp -af $c $d
      link $d $b
    fi
  done

  # Copy extra useful tools
  for a in rust/llvm-bin/*; do
    local b="$LLVM_DIR/bin/$(basename $a)"
    if [[ $(basename $a) == clang* ]] && [ ! -f $b ] && [ ! -L $b ]; then
        if [ ! -L $a ]; then
          cp -af $a $b
        elif [ -L $a ]; then
          local c="$(realpath $a)"
          local d=$LLVM_DIR/bin/$(basename $c)
          cp -af $c $d
          link $d $b
        fi
    fi	
  done

  rm -rf rust/llvm-bin
  cp -af ../../mingw64/* rust/

  cd ../../
}

export PATH='/c/Program Files/Git/cmd':$PATH 

clean_storage
clone
build
ndk
dist
