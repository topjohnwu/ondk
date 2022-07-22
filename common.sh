# Copyright 2022 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='master'
NDK_VERSION='r25'
OUTPUT_VERSION='r25.1'

NDK_CLANG='14.0.6'

clone() {
  git clone --depth 1 --branch $RUST_VERSION https://github.com/topjohnwu/rust.git
  cd rust
  git submodule update --init --depth=1
  # for p in ../patches/*.patch; do
  #   patch -p1 < $p
  # done
  cd ../
}

dist() {
  echo $OUTPUT_VERSION > ndk/ONDK_VERSION
  mv ndk "ondk-${OUTPUT_VERSION}"
  mkdir dist
  tar zcf "dist/ondk-${OUTPUT_VERSION}-${OS}.tar.gz" "ondk-${OUTPUT_VERSION}"
}
