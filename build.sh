#!/usr/bin/env bash

set -e

if [ -z $1 ]; then
  echo "Usage: $0 <arch>"
  echo "<arch> is either x86_64 or aarch64"
  echo
  exit 1
fi

RUST_VERSION='beta'
NDK_VERSION='r24'
OUTPUT_VERSION='r24.0'
OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH="$1"

if [ $OS = "darwin" ]; then
  NDK_DIRNAME='darwin-x86_64'
  TRIPLE="${ARCH}-apple-darwin"
  DYN_EXT='dylib'

  if [ $ARCH = "aarch64" ]; then
    # Configure jemalloc to use 64k pages for Apple Silicon
    export JEMALLOC_SYS_WITH_LG_PAGE=16
  fi

  command -v ninja >/dev/null || brew install ninja
else
  NDK_DIRNAME='linux-x86_64'
  TRIPLE="${ARCH}-unknown-linux-gnu"
  DYN_EXT='so'

  command -v ninja >/dev/null || sudo apt-get install ninja-build
fi

clone() {
  git clone --depth 1 --branch $RUST_VERSION https://github.com/rust-lang/rust.git
  cd rust
  git submodule update --init --depth=1

  patch -p1 < ../patches/patch-bootstrap-native.patch
  patch -p1 < ../patches/forced-vendored-openssl.patch

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
  python3 ./x.py --config "../config-${OS}.toml" --host $TRIPLE install
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
  cd ../../../../
}

dist() {
  mv ndk "ondk-${OUTPUT_VERSION}"
  mkdir dist
  tar zcf "dist/ondk-${OUTPUT_VERSION}-${OS}.tar.gz" "ondk-${OUTPUT_VERSION}"
}

universal() {
  cp -af out.x86 out
  cp -an out.arm/. out/. || true

  # Replace lld link with universal binary
  rm out/llvm-bin/lld
  lipo -create -output out/llvm-bin/lld \
    out/lib/rustlib/x86_64-apple-darwin/bin/rust-lld \
    out/lib/rustlib/aarch64-apple-darwin/bin/rust-lld

  # Merge all Mach-O files as universal binary and adhoc codesign
  find out -type f -exec sh -c "file {} | grep -q Mach-O" \; -print0 | \
  while IFS= read -r -d '' o; do
    local a="${o/out/out.x86}"
    local b="${o/out/out.arm}"
    if [ -f "$a" -a -f "$b" ]; then
      lipo -create -output "$o" "$a" "$b"
    fi
    codesign -s - "$o"
  done
}

clone

if [ $OS = "darwin" -a $ARCH = "aarch64" ]; then
  if [ ! -f tmp/stage-1.tar.gz ]; then
    echo '! Missing stage 1 artifacts'
    exit 1
  fi
  tar zxf tmp/stage-1.tar.gz
  mv out out.x86
fi

build

if [ $OS = "darwin" ]; then
  if [ $ARCH = "x86_64" ]; then
    # Pack up first stage artifacts
    mkdir tmp
    tar zcf tmp/stage-1.tar.gz rust/build/$TRIPLE out
    # Exit early
    exit 0
  else
    mv out out.arm
    universal
  fi
fi

ndk
dist
