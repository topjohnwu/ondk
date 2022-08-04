# Copyright 2022 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='3830ecaa8db798d2727cbdfa4ddf314ff938f268'
NDK_VERSION='r25'
OUTPUT_VERSION='r25.1'

NDK_CLANG='14.0.6'

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
