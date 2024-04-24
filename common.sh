# Copyright 2022-2024 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='1.77.2'

NDK_VERSION='r27-beta1'
NDK_DIR_VERSION=$NDK_VERSION

# These revisions are obtained from the NDK's LLVM manifest.xml and clang_source_info.md
# Update in sync with the NDK package
LLVM_VERSION='3c92011b600bdf70424e2547594dd461fe411a41'
LLVM_SVN='522817'
LLVM_ANDROID_VERSION='ac5b80f23decc96c1c188f6361fc13dfe72b62c5'
TOOLCHAIN_UTILS_VERSION='c688b0e8f5df2c2d16b72ec23beebd2f89c18658'

OUTPUT_VERSION='r27.0'

PYTHON_CMD='python3'

# url sha
git_clone_sha() {
  local dir=${1##*/}
  mkdir "$dir"
  cd "$dir"
  git init
  git remote add origin $1
  git fetch --depth 1 origin $2
  git reset --hard FETCH_HEAD
  cd ../
}

git_clone_branch() {
  git clone --single-branch --depth 1 --branch $2 $1
}

clone() {
  git_clone_branch https://github.com/rust-lang/rust $RUST_VERSION
  cd rust
  # for p in ../patches/*.patch; do
  #   patch -p1 < $p
  # done
  # Skip rust llvm
  sed 's:\[submodule "src/llvm-project"\]:&\n\tupdate = none:' .gitmodules > .gitmodules.p
  mv .gitmodules.p .gitmodules
  git submodule update --init --depth=1
  cd ../

  git_clone_sha https://github.com/llvm/llvm-project $LLVM_VERSION
  git_clone_sha https://android.googlesource.com/toolchain/llvm_android $LLVM_ANDROID_VERSION
  git_clone_sha https://android.googlesource.com/platform/external/toolchain-utils $TOOLCHAIN_UTILS_VERSION

  # Patch the LLVM source code
  $PYTHON_CMD toolchain-utils/llvm_tools/patch_manager.py \
    --svn_version $LLVM_SVN \
    --patch_metadata_file llvm_android/patches/PATCHES.json \
    --src_path llvm-project

  # Move the NDK LLVM into Rust's source
  rm -rf rust/src/llvm-project
  mv llvm-project rust/src/llvm-project
}

dl_ndk() {
  local NDK_ZIP="android-ndk-${NDK_VERSION}-${OS}.zip"
  local NDK_EXTRACT="android-ndk-${NDK_DIR_VERSION}"

  # Download and extract
  [ -f $NDK_ZIP ] || curl -O -L "https://dl.google.com/android/repository/$NDK_ZIP"
  rm -rf $NDK_EXTRACT
  unzip -q $NDK_ZIP
  mv $NDK_EXTRACT ndk
}

dist() {
  echo $OUTPUT_VERSION > ndk/ONDK_VERSION
  mv ndk "ondk-${OUTPUT_VERSION}"
  mkdir dist
  tar c "ondk-${OUTPUT_VERSION}" | xz --x86 --lzma2 > "dist/ondk-${OUTPUT_VERSION}-${OS}.tar.xz"
}
