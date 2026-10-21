# Copyright 2022-2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

RUST_VERSION='1.97.1'

NDK_VERSION='r30-beta2'
NDK_DIR_VERSION=$NDK_VERSION

# Android LLVM versions:
# https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/mirror-goog-main-llvm-toolchain-source/README.md
# These revisions are obtained from the Android's LLVM manifest.xml
LLVM_VERSION='9f872551d3c681d06fd303b36f16ed5c274735eb'
LLVM_ANDROID_VERSION='cbd9e7f4da965e4be38f3f9b340d06678ac69fce'
TOOLCHAIN_UTILS_VERSION='9b4f94761eea83b6edd1b59f485cddff6bd01b38'

OUTPUT_VERSION='r30.1'

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
  local llvm_svn=$(sed -n "s/^_svn_revision = 'r\([0-9]*\).*'/\1/p" src/llvm_android/src/llvm_android/android_version.py)
  python3 src/toolchain-utils/py/bin/llvm_tools/patch_manager.py \
    --svn_version $llvm_svn \
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
  patch -p1 < ../../patches/support_ndk_llvm_r30.patch
  patch -p1 < ../../patches/support_static_libcxx.patch

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
  local version_py=../../../src/llvm_android/src/llvm_android/android_version.py
  local patch_level=$(sed -n "s/^_patch_level = '\(.*\)'/\1/p" $version_py)
  local svn_rev=$(sed -n "s/^_svn_revision = '\(.*\)'/\1/p" $version_py)
  set_llvm_cfg CMAKE_BUILD_TYPE Release
  set_llvm_cfg CMAKE_INSTALL_PREFIX ../
  set_llvm_cfg LLVM_TARGETS_TO_BUILD "AArch64;ARM;BPF;RISCV;WebAssembly;X86"
  set_llvm_cfg LLVM_VERSION_PATCH $patch_level
  set_llvm_cfg LLVM_VERSION_SUFFIX
  set_llvm_cfg CLANG_VENDOR "Android (ONDK ${OUTPUT_VERSION}, based on ${svn_rev})"
  set_llvm_cfg CLANG_REPOSITORY_STRING "https://android.googlesource.com/toolchain/llvm-project"
  set_llvm_cfg BUG_REPORT_URL "https://github.com/topjohnwu/ondk/issues"
  set_llvm_cfg CLANG_DEFAULT_LINKER lld
  set_llvm_cfg CLANG_DEFAULT_OBJCOPY llvm-objcopy
  set_llvm_cfg CLANG_ENABLE_ARCMT OFF
  set_llvm_cfg CLANG_PYTHON_BINDINGS_VERSIONS 3
  set_llvm_cfg CMAKE_PLATFORM_NO_VERSIONED_SONAME ON
  set_llvm_cfg LLVM_TARGET_ARCH $ARCH
  set_llvm_cfg LLVM_DEFAULT_TARGET_TRIPLE $TRIPLE
  set_llvm_cfg LLVM_ENABLE_ZLIB FORCE_ON
  set_llvm_cfg LLVM_ENABLE_LIBXML2 OFF
  set_llvm_cfg LLVM_ENABLE_ZSTD FORCE_ON
  set_llvm_cfg LLVM_USE_STATIC_ZSTD ON
  set_llvm_cfg LLVM_INCLUDE_TESTS OFF
  set_llvm_cfg LLVM_ENABLE_LIBEDIT OFF
  set_llvm_cfg LLVM_ENABLE_TERMINFO OFF
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
