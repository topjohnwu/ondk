# Copyright 2022-2025 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='1.87.0'

NDK_VERSION='r28b'
NDK_DIR_VERSION=$NDK_VERSION

# Android LLVM versions:
# https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/mirror-goog-main-llvm-toolchain-source/README.md
# These revisions are obtained from the Android's LLVM manifest.xml
LLVM_SVN='536225'
LLVM_VERSION='b3a530ec6537146650e42be89f1089e9a3588460'
LLVM_ANDROID_VERSION='43ef7af1325b43e13d926d74a89741d4ace5fcf8'
TOOLCHAIN_UTILS_VERSION='760c253c1ed00ce9abd48f8546f08516e57485fe'

OUTPUT_VERSION='r28.4'

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
  $1 -s $(find bin -type f -exec sh -c "file {} | grep -q $EXE_FMT" \; -print)
  $1 -s $(find llvm-bin -type f -exec sh -c "file {} | grep -q $EXE_FMT" \; -print)
  $1 -s $(find lib -maxdepth 1 -type f -exec sh -c "file {} | grep -q $EXE_FMT" \; -print)
}

# url sha
git_clone_sha() {
  local dir=${1##*/}
  echo "Cloning into 'src/$dir'..."
  mkdir -p "src/$dir"
  cd "src/$dir"
  git init -q
  git remote add origin $1
  git fetch --depth 1 origin $2
  git reset --hard FETCH_HEAD
  cd ../../
}

git_clone_branch() {
  local dir=${1##*/}
  git clone --single-branch --depth 1 --branch $2 $1 src/$dir
}

skip_submodule() {
  git config set -f .gitmodules "submodule.$1.update" none
}

clone_llvm() {
  rm -rf src/llvm-project src/llvm_android src/toolchain-utils

  git_clone_sha https://android.googlesource.com/toolchain/llvm-project $LLVM_VERSION
  git_clone_sha https://android.googlesource.com/toolchain/llvm_android $LLVM_ANDROID_VERSION
  git_clone_sha https://android.googlesource.com/platform/external/toolchain-utils $TOOLCHAIN_UTILS_VERSION

  # Patch the LLVM source code
  $PYTHON_CMD src/toolchain-utils/llvm_tools/patch_manager.py \
    --svn_version $LLVM_SVN \
    --patch_metadata_file src/llvm_android/patches/PATCHES.json \
    --src_path src/llvm-project
}

clone_rust() {
  rm -rf src/rust

  git_clone_branch https://github.com/rust-lang/rust $RUST_VERSION
  cd src/rust

  # Skip unused submodules
  skip_submodule src/llvm-project
  skip_submodule src/gcc
  skip_submodule src/tools/enzyme

  # Clone submodules
  git submodule update --init --depth=1

  # Apply patches
  patch -p1 < ../../patches/patch_llvm_build.patch
  # patch -p1 < ../../patches/support_ndk_llvm.patch

  # Link NDK LLVM into Rust's source
  rm -rf src/llvm-project
  ln -s ../../llvm-project src/llvm-project

  cd ../../
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

build() {
  set_llvm_cfg LLVM_VERSION_SUFFIX
  config_build
  cd src/rust
  eval $PYTHON_CMD ./x.py --config ../../bootstrap.toml --build $TRIPLE $(print_build_cfg) install
  cd ../../
}

dl_ndk() {
  local NDK_ZIP="android-ndk-${NDK_VERSION}-${OS}.zip"
  local NDK_EXTRACT="android-ndk-${NDK_DIR_VERSION}"

  # Download and extract
  [ -f $NDK_ZIP ] || curl -O -L "https://dl.google.com/android/repository/$NDK_ZIP"
  rm -rf $NDK_EXTRACT
  unzip -q $NDK_ZIP
  mv $NDK_EXTRACT out/ndk
  echo $OUTPUT_VERSION > out/ndk/ONDK_VERSION
}

dist() {
  cd out
  mv ndk "ondk-${OUTPUT_VERSION}"
  mkdir ../dist
  tar c "ondk-${OUTPUT_VERSION}" | xz --x86 --lzma2 > "../dist/ondk-${OUTPUT_VERSION}-${OS}.tar.xz"
  cd ../
}

run_cmd() {
  case $1 in
    clone)
      clone_llvm
      clone_rust
      ;;
    clone-llvm)
      clone_llvm
      ;;
    clone-rust)
      clone_rust
      ;;
    build)
      rm -rf out/rust
      build
      ;;
    collect)
      rm -rf out/collect
      collect
      ;;
    ndk)
      rm -rf out/ndk
      ndk
      ;;
    dist)
      rm -rf dist out/ondk-*
      dist
      ;;
    clean)
      rm -rf src out dist tmp android-ndk-*.zip
      ;;
    *)
      echo "Unknown action \"$1\""
      exit 1
      ;;
  esac
}

parse_args() {
  if [ $# -eq 0 ]; then
    run_cmd clone
    run_cmd build
    run_cmd collect
    run_cmd ndk
    run_cmd dist
  else
    for arg in $@; do
      run_cmd $arg
    done
  fi
}
