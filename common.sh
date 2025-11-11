# Copyright 2022-2025 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='1.91.1'

NDK_VERSION='r29'
NDK_DIR_VERSION=$NDK_VERSION

# Android LLVM versions:
# https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/mirror-goog-main-llvm-toolchain-source/README.md
# These revisions are obtained from the Android's LLVM manifest.xml
LLVM_SVN='563880'
LLVM_VERSION='5e96669f06077099aa41290cdb4c5e6fa0f59349'
LLVM_ANDROID_VERSION='38546691df970516709cc907bc7387004f69c60c'
TOOLCHAIN_UTILS_VERSION='e4ed541c00706c0108c57921ac4b95ca98e87ec5'

OUTPUT_VERSION='r29.3'

set -e
shopt -s nullglob

# key value
set_llvm_cfg() {
  local cfg="\"-D${1}=$2\""
  if [ -z "$LLVM_BUILD_CFG" ]; then
    LLVM_BUILD_CFG="$cfg"
  else
    LLVM_BUILD_CFG="$LLVM_BUILD_CFG $cfg"
  fi
}

# key value
set_build_cfg() {
  RUST_CFG="$RUST_CFG '--set=$1=$2'"
}

strip_exe() {
  for path in bin llvm-bin lib; do
    find $path -maxdepth 1 -type f \
      -exec sh -c "file {} | grep -q $EXE_FMT" \; \
      -exec ../llvm/bin/llvm-strip -s {} \;
  done
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
  python3 src/toolchain-utils/py/bin/llvm_tools/patch_manager.py \
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
  patch -p1 < ../../patches/support_ndk_llvm_r29.patch

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

common_config_llvm() {
  unset LLVM_BUILD_CFG
  set_llvm_cfg CMAKE_BUILD_TYPE Release
  set_llvm_cfg CMAKE_INSTALL_PREFIX ../
  set_llvm_cfg LLVM_TARGETS_TO_BUILD "AArch64;ARM;X86;RISCV"
  set_llvm_cfg LLVM_VERSION_SUFFIX
  set_llvm_cfg LLVM_TARGET_ARCH $ARCH
  set_llvm_cfg LLVM_DEFAULT_TARGET_TRIPLE $TRIPLE
  set_llvm_cfg LLVM_ENABLE_ZLIB OFF
  set_llvm_cfg LLVM_ENABLE_LIBXML2 OFF
  set_llvm_cfg LLVM_ENABLE_ZSTD FORCE_ON
  set_llvm_cfg LLVM_USE_STATIC_ZSTD ON
  set_llvm_cfg LLVM_INCLUDE_TESTS OFF
  set_llvm_cfg LLVM_ENABLE_LIBEDIT OFF
  set_llvm_cfg LLVM_ENABLE_BINDINGS OFF
  set_llvm_cfg LLVM_ENABLE_Z3_SOLVER OFF
  set_llvm_cfg LLVM_ENABLE_ASSERTIONS OFF
  set_llvm_cfg LLVM_UNREACHABLE_OPTIMIZE OFF
  set_llvm_cfg LLVM_INCLUDE_EXAMPLES OFF
  set_llvm_cfg LLVM_INCLUDE_DOCS OFF
  set_llvm_cfg LLVM_INCLUDE_BENCHMARKS OFF
  set_llvm_cfg LLVM_ENABLE_WARNINGS OFF
  set_llvm_cfg LLVM_INSTALL_UTILS ON
}

build_rust() {
  rm -rf out/rust
  config_rust_build
  cd src/rust
  eval python3 ./x.py --config ../../bootstrap.toml --build $TRIPLE $RUST_CFG install
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
      rm -rf out/llvm out/lld
      build_llvm
      build_rust
      ;;
    build-llvm)
      rm -rf out/llvm out/lld
      build_llvm
      ;;
    build-rust)
      build_rust
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
