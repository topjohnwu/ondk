#!/usr/bin/env bash

set -e

RUST_VERSION='1.59.0'
NDK_VERSION='r23b'
OS=$(uname | tr '[:upper:]' '[:lower:]')

# Clone the rust repository
git clone --depth 1 --branch $RUST_VERSION https://github.com/rust-lang/rust.git
cd rust
git submodule update --init --depth=1

# OS specific stuffs
if [ $OS = "darwin" ]; then
  # Apply patches required for macOS
  patch -p1 < ../patches/macos-llvm-link-shared.patch
  cd src/llvm-project
  patch -p1 < ../../../patches/fix-llvm-config.patch
  cd ../../
  NDK_DIRNAME='darwin-x86_64'
  TRIPLE='x86_64-apple-darwin'
  DYN_EXT='dylib'
else
  NDK_DIRNAME='linux-x86_64'
  TRIPLE='x86_64-unknown-linux-gnu'
  DYN_EXT='so'
fi

# Build
python3 ./x.py --config ../config.toml install

cd ../

# Finish up the output directory
cd out
cp -af ../rust/build/$TRIPLE/llvm/bin llvm-bin
ln -s ../lib/rustlib/x86_64-apple-darwin/bin/rust-lld llvm-bin/lld
ln -s lld llvm-bin/ld
find ../rust/build/$TRIPLE/llvm/lib -type f -name "*.${DYN_EXT}*" -exec cp -an {} lib \;
cd ..

# Download latest NDK
curl -O -L "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-${OS}.zip"
unzip -q "android-ndk-${NDK_VERSION}-${OS}.zip"
mv "android-ndk-${NDK_VERSION}" ndk

# Copy the whole output folder into ndk
cp -af out ndk/toolchains/rust

# Redirect libraries
cd ndk/toolchains/rust/lib
mkdir clang
cd clang
ln -s ../../../llvm/prebuilt/$NDK_DIRNAME/lib64/clang/12.0.8 13.0.0
cd ../../../

# Replace files with those from the rust toolchain
cd llvm/prebuilt/$NDK_DIRNAME/bin
ln -sf ../../../../rust/llvm-bin/* .
rm clang-12
cd ../lib64
ln -sf ../../../../rust/lib/*.$DYN_EXT* .
rm libclang_cxx.*  # libclang-cxx is unused
cd ../lib
mkdir clang
cd clang
ln -s ../../lib64/clang/12.0.8 13.0.0
