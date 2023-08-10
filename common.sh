# Copyright 2022-2023 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='832db2fcee27ee1079608ac78f82b7c14394e89b'
NDK_VERSION='r25c'
OUTPUT_VERSION='r25.7'

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
  tar c "ondk-${OUTPUT_VERSION}" | xz --x86 --lzma2 > "dist/ondk-${OUTPUT_VERSION}-${OS}.tar.xz"
}
