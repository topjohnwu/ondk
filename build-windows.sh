#!/usr/bin/env bash

# Copyright 2022 Google LLC.
# SPDX-License-Identifier: Apache-2.0

set -e

if ! uname | grep -q 'MINGW64_NT'; then
  echo 'This script should run on MSYS2 bash'
  echo
  exit 1
fi

. common.sh

OS='windows'
NDK_DIRNAME='windows-x86_64'
TRIPLE='x86_64-pc-windows-msvc'
DYN_EXT='dll'

clean_storage() {
  # Clean up storage to fit in all our build output
  rm -rf /c/SeleniumWebDrivers /c/selenium /c/Android /c/msys64 /c/tools /c/Modules \
    '/c/Program Files/PostgreSQL' '/c/Program Files/dotnet' \
    "$JAVA_HOME_8_X64" "$JAVA_HOME_11_X64" "$JAVA_HOME_17_X64" \
    "$GOROOT_1_15_X64" "$GOROOT_1_16_X64" "$GOROOT_1_17_X64" "$GOROOT_1_18_X64"
}

build() {
  if ! command -v ninja >/dev/null; then
    if [ ! -d ninja ]; then
      curl -L -O https://github.com/ninja-build/ninja/releases/download/v1.10.2/ninja-win.zip
      mkdir ninja
      unzip -q ninja-win.zip -d ninja
      rm ninja-win.zip
    fi
    export PATH="$(pwd)/ninja:$PATH"
  fi

  # The Git bundled msys2 perl will not work when compiling OpenSSL, we need to use strawberry perl.
  # However, we cannot just simply override the msys2 perl globally because Git relies on it internally,
  # so instead we only explicitly switch to strawberry perl when compiling cargo.
  if [ ! -d strawberry ]; then
    curl -L -O https://strawberryperl.com/download/5.32.1.1/strawberry-perl-5.32.1.1-64bit-portable.zip
    mkdir strawberry
    unzip -q strawberry-perl-*.zip -d strawberry
    rm strawberry-perl-*.zip
  fi

  cd rust
  PATH="$(pwd)/../strawberry/perl/bin:$PATH" python ./x.py \
    --config '../config-windows.toml' \
    --build $TRIPLE install
  cd ../

  RUST_CLANG=$(rust/build/$TRIPLE/llvm/bin/llvm-config --version)

  cd out
  cp -af ../rust/build/$TRIPLE/llvm/bin llvm-bin
  cp -af ../rust/build/$TRIPLE/lld/bin/. llvm-bin/.
  cp -af llvm-bin/lld llvm-bin/ld
  cp -af ../rust/build/$TRIPLE/llvm/lib/clang/$RUST_CLANG/include clang-include
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
    if [ -f $a ]; then
      cp -af $a $b
    fi
  done
  rm -rf rust/llvm-bin

  cd ../../
}

clean_storage
clone
build
ndk
dist
