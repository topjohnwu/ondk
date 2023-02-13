# Copyright 2022 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='9eb3afe9ebe9c7d2b84b71002d44f4a0edac95e0'
NDK_VERSION='r25c'
OUTPUT_VERSION='r25.3'

NDK_CLANG='14.0.7'

clone() {
  mkdir rust
  cd rust
  git init
  git remote add origin https://github.com/rust-lang/rust.git
  git fetch --depth 1 origin $RUST_VERSION
  git reset --hard FETCH_HEAD
  git submodule update --init --depth=1
  for p in ../patches/*.patch; do
    patch -p1 < $p
  done
  cd ../
}

dist() {
  echo $OUTPUT_VERSION > ndk/ONDK_VERSION
  mv ndk "ondk-${OUTPUT_VERSION}"
  mkdir dist
  tar zcf "dist/ondk-${OUTPUT_VERSION}-${OS}.tar.gz" "ondk-${OUTPUT_VERSION}"
}
