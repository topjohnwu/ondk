# Copyright 2022-2025 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='1.85.0'

NDK_VERSION='r28'
NDK_DIR_VERSION=$NDK_VERSION

# These revisions are obtained from the NDK's LLVM manifest.xml
# Update in sync with the NDK package
LLVM_VERSION='97a699bf4812a18fb657c2779f5296a4ab2694d2'
LLVM_SVN='530567'
LLVM_ANDROID_VERSION='a04a3e119c2bbc35ab20cc2b7147d4a0daab7d78'
TOOLCHAIN_UTILS_VERSION='dd1ee45a84cb07337f9d5d0a6769d9b865c6e620'

OUTPUT_VERSION='r28.3'

PYTHON_CMD='python3'

set -e
shopt -s nullglob

# key value
set_llvm_cfg() {
  if [ -z "$LLVM_BUILD_CFG" ]; then
    LLVM_BUILD_CFG="\"$1\" = \"$2\""
  else
    LLVM_BUILD_CFG="$LLVM_BUILD_CFG, \"$1\" = \"$2\""
  fi
}

# key value
set_build_cfg() {
  RUST_CFG="$RUST_CFG '--set=$1=$2'"
}

print_build_cfg() {
  echo $RUST_CFG "'--set=llvm.build-config={ $LLVM_BUILD_CFG }'"
}

strip_exe() {
  llvm-bin/llvm-strip -s $(find llvm-bin -type f -exec sh -c "file {} | grep -q $EXE_FMT" \; -print)
  llvm-bin/llvm-strip -s $(find lib -maxdepth 1 -type f -exec sh -c "file {} | grep -q $EXE_FMT" \; -print)
}

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

update_dir() {
  local src=$1
  local dest=$2

  for d in $dest/*; do
    local s=$src/$(basename $d)
    # Copy regular files first
    if [ -f $s ] && [ ! -L $s ]; then
      cp -af $s $d
    fi
  done

  for d in $dest/*; do
    local s=$src/$(basename $d)
    # Then copy over symlinks
    if [ -L $s ]; then
      cp -af $s $d
    fi
  done
}

dl_ndk() {
  local NDK_ZIP="android-ndk-${NDK_VERSION}-${OS}.zip"
  local NDK_EXTRACT="android-ndk-${NDK_DIR_VERSION}"

  # Download and extract
  [ -f $NDK_ZIP ] || curl -O -L "https://dl.google.com/android/repository/$NDK_ZIP"
  rm -rf $NDK_EXTRACT
  unzip -q $NDK_ZIP
  mv $NDK_EXTRACT ndk
  echo $OUTPUT_VERSION > ndk/ONDK_VERSION
}

dist() {
  mv ndk "ondk-${OUTPUT_VERSION}"
  mkdir dist
  tar c "ondk-${OUTPUT_VERSION}" | xz --x86 --lzma2 > "dist/ondk-${OUTPUT_VERSION}-${OS}.tar.xz"
}

run_cmd() {
  case $1 in
    clone)
      rm -rf rust llvm-project llvm_android toolchain-utils
      clone
      ;;
    build)
      rm -rf out
      # Set common LLVM configs
      set_llvm_cfg LLVM_VERSION_SUFFIX
      build
      ;;
    ndk)
      rm -rf ndk
      ndk
      ;;
    dist)
      rm -rf dist ondk-*
      dist
      ;;
    clean)
      rm -rf rust llvm-project llvm_android toolchain-utils \
        out out.arm out.x86 ndk tmp mingw64 \
        android-ndk-*.zip ondk-* dist mingw.7z
      ;;
    *)
      echo "Unknown action \"$1\""
      echo "./build.sh clone/build/ndk/dist"
      exit 1
      ;;
  esac
}

parse_args() {
  if [ $# -eq 0 ]; then
    run_cmd clone
    run_cmd build
    run_cmd ndk
    run_cmd dist
  else
    for arg in $@; do
      run_cmd $arg
    done
  fi
}
