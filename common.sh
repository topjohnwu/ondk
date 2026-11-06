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

# key value
set_tools_cfg() {
  local cfg="\"-D${1}=$2\""
  if [ -z "$TOOLS_CMAKE_CFG" ]; then
    TOOLS_CMAKE_CFG="$cfg"
  else
    TOOLS_CMAKE_CFG="$TOOLS_CMAKE_CFG $cfg"
  fi
}

strip_exe() {
  find bin llvm-bin tools-bin lib -maxdepth 1 -type f -exec file {} + \
    | grep "$EXE_FMT" | cut -d: -f1 | xargs ../llvm/bin/llvm-strip -s
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
  local dir=${3:-${1##*/}}
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
  sed -i.bak '/import fcntl/d' src/toolchain-utils/llvm_tools/get_llvm_hash.py
  PYTHONPATH=src/toolchain-utils python3 src/toolchain-utils/py/bin/llvm_tools/patch_manager.py \
    --svn_version $llvm_svn \
    --patch_metadata_file src/llvm_android/patches/PATCHES.json \
    --src_path src/llvm-project
}

clone_tools() {
  rm -rf src/shaderc src/ndk

  local tag="ndk-$NDK_VERSION"
  git_clone_branch https://android.googlesource.com/platform/external/shaderc/shaderc $tag
  git_clone_branch https://android.googlesource.com/platform/external/shaderc/glslang $tag shaderc/third_party/glslang
  git_clone_branch https://android.googlesource.com/platform/external/shaderc/spirv-headers $tag shaderc/third_party/spirv-headers
  git_clone_branch https://android.googlesource.com/platform/external/shaderc/spirv-tools $tag shaderc/third_party/spirv-tools
  if [ "$OS" = "windows" ]; then
    git_clone_branch https://android.googlesource.com/platform/ndk $tag
  fi
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

common_config_tools() {
  unset TOOLS_CMAKE_CFG
  set_tools_cfg CMAKE_BUILD_TYPE Release
  set_tools_cfg CMAKE_INSTALL_PREFIX "$(realpath ..)"
  set_tools_cfg CMAKE_POLICY_VERSION_MINIMUM 3.5
  config_tools_build
}

build_shaderc() {
  mkdir -p out/tools/build-shaderc
  cd out/tools/build-shaderc
  common_config_tools
  set_tools_cfg SHADERC_SKIP_TESTS ON
  set_tools_cfg SHADERC_SKIP_EXAMPLES ON
  set_tools_cfg SHADERC_SKIP_COPYRIGHT_CHECK ON
  set_tools_cfg SPIRV-Headers_SOURCE_DIR "$(realpath ../../../src/shaderc/third_party/spirv-headers)"
  eval cmake -G Ninja ../../../src/shaderc $TOOLS_CMAKE_CFG
  cmake --build . --target install
  cd ../../../
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
  cleanup_ndk
}

cleanup_ndk() {
  local llvm_dir="out/ndk/toolchains/llvm/prebuilt/$NDK_DIRNAME"
  local prebuilt_bin="out/ndk/prebuilt/$NDK_DIRNAME/bin"

  # 1. Remove bundled python3 and host LLDB executables/wrappers/libraries
  rm -rf \
    "$llvm_dir/python3" \
    "$llvm_dir/bin/lldb"* \
    "$llvm_dir/bin/liblldb"* \
    "$llvm_dir/bin/libxml2"* \
    "$llvm_dir/lib/liblldb"* \
    "$llvm_dir/lib/libpython"* \
    "$llvm_dir/lib/python"* \
    "$llvm_dir/lib/site-packages" \
    "$llvm_dir/lib/libxml2"* \
    "$llvm_dir/lib/libedit"* \
    "$llvm_dir/lib/libncurses"* \
    "$llvm_dir/lib/libform"* \
    "$llvm_dir/lib/libpanel"* \
    "$llvm_dir/lib/liblzma"*

  # 2. Remove NDK scripts and zipapps that rely on lldb / bundled python3, and duplicate yasm binaries
  rm -rf \
    out/ndk/ndk-gdb* \
    out/ndk/ndk-lldb* \
    out/ndk/ndk-stack* \
    "$prebuilt_bin/ndk-gdb"* \
    "$prebuilt_bin/ndkgdb.pyz" \
    "$prebuilt_bin/ndk-stack"* \
    "$prebuilt_bin/ndkstack.pyz" \
    "$prebuilt_bin/"{yasm,ytasm,vsyasm}*

  # 3. Remove unused upstream host C++ runtime libraries and host triple dirs
  rm -rf \
    "$llvm_dir/musl" \
    "$llvm_dir/bin/libwinpthread"* \
    "$llvm_dir/lib/libwinpthread"* \
    "$llvm_dir/lib/libc++"* \
    "$llvm_dir/lib/libunwind"* \
    "$llvm_dir/lib/libsimpleperf_readelf.a" \
    "$llvm_dir/lib/"*-linux-* \
    "$llvm_dir/lib/"*-windows-* \
    "out/ndk/shader-tools/$NDK_DIRNAME/libc++"*

  # 4. Remove simpleperf host executables and shared libraries
  rm -rf "out/ndk/simpleperf/bin/$OS"

  # 5. Record all remaining host binaries to verify replacement later
  find out/ndk -type f \
    ! -path '*/sysroot/*' \
    ! -path '*/lib/clang/*' \
    ! -path '*/simpleperf/bin/android/*' \
    -exec file {} + | grep "$EXE_FMT" | cut -d: -f1 | xargs sha256sum > out/ndk_bins.txt
}

check_ndk() {
  local unreplaced=$(sha256sum -c out/ndk_bins.txt 2>/dev/null | grep ': OK$' | sed 's/: OK$//')
  local dangling=$(find out/ndk -xtype l)
  local failed=0

  rm -f out/ndk_bins.txt

  if [ -n "$unreplaced" ]; then
    echo "Error: Unreplaced host binaries in NDK:" >&2
    echo "$unreplaced" >&2
    failed=1
  fi

  if [ -n "$dangling" ]; then
    echo "Error: Dangling symlinks in NDK:" >&2
    echo "$dangling" >&2
    failed=1
  fi

  if [ $failed -ne 0 ]; then
    exit 1
  fi
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
      clone_tools
      clone_rust
      ;;
    clone-llvm)
      clone_llvm
      ;;
    clone-tools)
      clone_tools
      ;;
    clone-rust)
      clone_rust
      ;;
    build)
      rm -rf out/llvm out/lld out/tools
      build_llvm
      build_tools
      build_rust
      ;;
    build-llvm)
      rm -rf out/llvm out/lld
      build_llvm
      ;;
    build-tools)
      rm -rf out/tools
      build_tools
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
