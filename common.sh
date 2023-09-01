# Copyright 2022-2023 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='2f5df8a94bb3c5fae4e3fcbfc8ef20f1f976cb19'

NDK_VERSION='r26-rc1'
NDK_DIR_VERSION='r26-beta2'

# These revisions are obtained from the NDK's LLVM manifest.xml
# Update in sync with the NDK package
LLVM_VERSION='d9f89f4d16663d5012e5c09495f3b30ece3d2362'
LLVM_SVN='487747'
LLVM_ANDROID_VERSION='8443a75fcd5c80245b194f6510b98a11098fe7fe'
TOOLCHAIN_UTILS_VERSION='584b8e46d146a2bcfeffd64448a2d8e92904168d'

OUTPUT_VERSION='r26.0'

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

clone() {
  git_clone_sha https://github.com/rust-lang/rust $RUST_VERSION
  cd rust
  for p in ../patches/*.patch; do
    patch -p1 < $p
  done
  git submodule update --init --depth=1
  cd ../

  git_clone_sha https://android.googlesource.com/toolchain/llvm-project $LLVM_VERSION
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

dist() {
  echo $OUTPUT_VERSION > ndk/ONDK_VERSION
  mv ndk "ondk-${OUTPUT_VERSION}"
  mkdir dist
  tar c "ondk-${OUTPUT_VERSION}" | xz --x86 --lzma2 > "dist/ondk-${OUTPUT_VERSION}-${OS}.tar.xz"
}
