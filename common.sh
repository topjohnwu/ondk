# Copyright 2022-2024 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='1.77.0'

NDK_VERSION='r26c'
NDK_DIR_VERSION='r26c'

# These revisions are obtained from the NDK's LLVM manifest.xml and clang_source_info.md
# Update in sync with the NDK package
LLVM_VERSION='c4c5e79dd4b4c78eee7cffd9b0d7394b5bedcf12'
LLVM_SVN='487747'
LLVM_ANDROID_VERSION='0f058ab00ec6c9b8b39956c1393bcc405a5498d3'
TOOLCHAIN_UTILS_VERSION='584b8e46d146a2bcfeffd64448a2d8e92904168d'

OUTPUT_VERSION='r26.4'

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
  for p in ../patches/*.patch; do
    patch -p1 < $p
  done
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

  # Extract first stage build artifacts if exists
  if [ -f tmp/build.tar.xz ]; then
    xz -d < tmp/build.tar.xz | tar x
  fi
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
