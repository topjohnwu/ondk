#!/usr/bin/env bash

set -e

if ! uname | grep -q 'MINGW64_NT'; then
  echo 'This script should run on MSYS2 bash'
  echo
  exit 1
fi

RUST_VERSION='beta'
NDK_VERSION='r24'
OUTPUT_VERSION='r24.0'
OS='windows'

NDK_DIRNAME='windows-x86_64'
TRIPLE='x86_64-pc-windows-msvc'
DYN_EXT='dll'

clone() {
  git clone --depth 1 --branch $RUST_VERSION https://github.com/rust-lang/rust.git
  cd rust
  git submodule update --init --depth=1

  patch -p1 < ../patches/patch-bootstrap-native.patch
  patch -p1 < ../patches/forced-vendored-openssl.patch

  cd ../
}

build() {
  if ! command -v ninja >/dev/null; then
    if [ ! -d ninja ]; then
      curl -L -O https://github.com/ninja-build/ninja/releases/download/v1.10.2/ninja-win.zip
      mkdir ninja
      unzip -q ninja-win.zip -d ninja
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
  fi

  cd rust
  PATH="$(pwd)/../strawberry/perl/bin:$PATH" python ./x.py \
    --config '../config-windows.toml' \
    --build $TRIPLE install
  cd ../

  cd out
  cp -af ../rust/build/$TRIPLE/llvm/bin llvm-bin
  cp -af ../rust/build/$TRIPLE/lld/bin/. llvm-bin/.
  cp -af llvm-bin/lld llvm-bin/ld
  cp -af ../rust/build/$TRIPLE/llvm/lib/clang/14.0.0/include clang-include
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
  rm -rf $LLVM_DIR/lib64/clang/14.0.1/include
  mv rust/clang-include $LLVM_DIR/lib64/clang/14.0.1/include

  # Move library
  mkdir -p $LLVM_DIR/lib/clang
  mv $LLVM_DIR/lib64/clang/14.0.1 $LLVM_DIR/lib/clang/14.0.0

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

dist() {
  mv ndk "ondk-${OUTPUT_VERSION}"
  mkdir dist
  tar zcf "dist/ondk-${OUTPUT_VERSION}-${OS}.tar.gz" "ondk-${OUTPUT_VERSION}"
}

clone
build
ndk
dist
