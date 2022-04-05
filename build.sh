#!/usr/bin/env bash

set -e

RUST_VERSION='beta'
NDK_VERSION='r24'
OUTPUT_VERSION='r24.0'
OS=$(uname | tr '[:upper:]' '[:lower:]')

if [ $OS = "darwin" ]; then
  NDK_DIRNAME='darwin-x86_64'
  TRIPLE='x86_64-apple-darwin'
  DYN_EXT='dylib'

  command -v ninja || brew install ninja
else
  NDK_DIRNAME='linux-x86_64'
  TRIPLE='x86_64-unknown-linux-gnu'
  DYN_EXT='so'

  command -v ninja || sudo apt-get install ninja-build
fi

clone() {
  git clone --depth 1 --branch $RUST_VERSION https://github.com/rust-lang/rust.git
  cd rust
  git submodule update --init --depth=1

  patch -p1 < ../patches/patch-bootstrap-native.patch

  if [ $OS = "darwin" ]; then
    # Dirty fix of llvm-config for macOS
    cd src/llvm-project
    patch -p1 < ../../../patches/fix-llvm-config.patch
    cd ../../
  fi

  cd ../
}

build() {
  cd rust
  python3 ./x.py --config "../config-${OS}.toml" install
  cd ../

  cd out
  cp -af ../rust/build/$TRIPLE/llvm/bin llvm-bin
  cp -af ../rust/build/$TRIPLE/llvm/lib/clang/14.0.0/include clang-include
  ln -s ../lib/rustlib/$TRIPLE/bin/rust-lld llvm-bin/lld
  ln -s lld llvm-bin/ld
  find ../rust/build/$TRIPLE/llvm/lib -name "*.${DYN_EXT}*" -exec cp -an {} lib \;
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

  # Replace headers
  cd ndk/toolchains
  mv llvm/prebuilt/$NDK_DIRNAME llvm.dir
  ln -s ../../llvm.dir llvm/prebuilt/$NDK_DIRNAME
  rm -rf llvm.dir/lib64/clang/14.0.1/include
  mv rust/clang-include llvm.dir/lib64/clang/14.0.1/include

  # Redirect library
  cd rust/lib
  mkdir clang
  ln -s ../../../llvm.dir/lib64/clang/14.0.1 clang/14.0.0
  cd ../../

  # Replace files with those from the rust toolchain
  cd llvm.dir/bin
  ln -sf ../../rust/llvm-bin/* .
  rm clang-14
  cd ../lib64
  ln -sf ../../rust/lib/*.$DYN_EXT* .
  rm -f libclang.so.13 libLLVM-14git.so libLTO.so.14git libRemarks.so.14git

  # Redirect library
  cd ../lib
  mkdir clang
  ln -s ../../lib64/clang/14.0.1 clang/14.0.0
  cd ../../
}

archive() {
  mv ndk "ondk-${OUTPUT_VERSION}"
  mkdir dist
  tar zcvf "dist/ondk-${OUTPUT_VERSION}-${OS}.tar.gz" "ondk-${OUTPUT_VERSION}"
}

clone
build
ndk
archive
