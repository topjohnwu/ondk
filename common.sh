# Copyright 2022 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='beta'
NDK_VERSION='r24'
OUTPUT_VERSION='r24.0'

RUST_CLANG='14.0.0'
NDK_CLANG='14.0.1'

clone() {
  git clone --depth 1 --branch $RUST_VERSION https://github.com/rust-lang/rust.git
  cd rust
  git submodule update --init --depth=1

  patch -p1 < ../patches/patch-bootstrap-native.patch
  patch -p1 < ../patches/forced-vendored-openssl.patch

  if [ $OS = 'darwin' ]; then
    # Dirty fix of llvm-config for macOS
    cd src/llvm-project
    patch -p1 < ../../../patches/fix-llvm-config.patch
    cd ../../
  fi

  cd ../
}

dist() {
  echo $OUTPUT_VERSION > ndk/ONDK_VERSION
  mv ndk "ondk-${OUTPUT_VERSION}"
  mkdir dist
  tar zcf "dist/ondk-${OUTPUT_VERSION}-${OS}.tar.gz" "ondk-${OUTPUT_VERSION}"
}
