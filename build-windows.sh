#!/usr/bin/env bash

# Copyright 2022-2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

if ! [[ "$MSYSTEM" =~ ^CLANG(ARM)?64$ ]]; then
  echo 'This script should run on MSYS2 CLANG64 or CLANGARM64 bash'
  echo
  exit 1
fi

. /etc/msystem
. common.sh

OS='windows'
NDK_DIRNAME='windows-x86_64'
ARCH=$MSYSTEM_CARCH
TRIPLE="${ARCH}-pc-windows-gnullvm"
DYN_EXT='dll'
EXE_FMT='PE32+'

# With MSYS=winsymlinks:nativestrict, copying a symlink fails if its target
# has not been copied yet. Copy in two passes so targets exist before symlinks.
cp_dir() {
  mkdir -p "$2"
  cp -af "$1/." "$2/." 2>/dev/null || true
  cp -an "$1/." "$2/."
}

cp_sys_dlls() {
  local dir=$(dirname $1)
  for lib in $(ldd $1 | grep " $MINGW_PREFIX/bin/" | awk '{ print $1 }'); do
    cp -v $MINGW_PREFIX/bin/$lib $dir
  done
}

config_rust_build() {
  unset RUST_CFG

  set_build_cfg llvm.use-libcxx true
  set_build_cfg rust.use-lld true

  # Prevent cc-rs from inheriting -flto=thin from rustc flags, as MSYS2's host clang
  # is newer than ONDK's LLVM and emits bitcode that stage1 rustc/lld cannot read.
  export CFLAGS="-fno-lto"
  export CXXFLAGS="-fno-lto"

  # Expose all LLVM dlls to stage1 rustc
  rm -rf out/llvm/dlls
  mkdir -p out/llvm/dlls
  ln -srf out/llvm/bin/*.dll out/llvm/dlls
  export PATH="$(realpath out/llvm/dlls):$PATH"
}

config_tools_build() {
  set_tools_cfg CMAKE_C_COMPILER clang
  set_tools_cfg CMAKE_CXX_COMPILER clang++
  set_tools_cfg CMAKE_C_FLAGS "-Os -fomit-frame-pointer -w"
  set_tools_cfg CMAKE_CXX_FLAGS "-Os -fomit-frame-pointer -w -fno-rtti -fno-exceptions -include type_traits"
  set_tools_cfg CMAKE_EXE_LINKER_FLAGS "-static"
  set_tools_cfg CMAKE_SHARED_LINKER_FLAGS "-static"
}

build_toolbox() {
  mkdir -p out/tools/bin
  local src_dir="src/ndk/sources/host-tools/toolbox"
  local flags="-Os -fomit-frame-pointer -static"
  clang $flags -o out/tools/bin/echo.exe "$src_dir/echo_win.c"
  clang $flags -o out/tools/bin/cmp.exe "$src_dir/cmp_win.c"
}

build_tools() {
  build_shaderc
  build_toolbox
}

config_llvm() {
  common_config_llvm
  set_llvm_cfg CMAKE_C_COMPILER clang
  set_llvm_cfg CMAKE_CXX_COMPILER clang++
  set_llvm_cfg LLVM_USE_LINKER lld
  set_llvm_cfg LLVM_ENABLE_LIBCXX ON
  set_llvm_cfg ZLIB_USE_STATIC_LIBS ON
  set_llvm_cfg LLVM_ENABLE_PLUGINS OFF
  set_llvm_cfg LLVM_USE_SYMLINKS ON
  # LLVM does not recognize Rust's 'windows-gnullvm' environment name in triples
  set_llvm_cfg LLVM_DEFAULT_TARGET_TRIPLE "${ARCH}-pc-windows-gnu"
  # Default the MinGW driver to LLVM runtime libraries to match windows-gnullvm
  set_llvm_cfg CLANG_DEFAULT_RTLIB compiler-rt
  set_llvm_cfg CLANG_DEFAULT_UNWINDLIB libunwind
  set_llvm_cfg CLANG_DEFAULT_CXX_STDLIB libc++
}

build_lld() {
  mkdir -p out/lld/build
  cd out/lld/build

  config_llvm
  set_llvm_cfg LLVM_ENABLE_PROJECTS lld
  set_llvm_cfg LLVM_BUILD_TOOLS OFF
  set_llvm_cfg CMAKE_EXE_LINKER_FLAGS "-s -static"

  eval cmake -G Ninja ../../../src/llvm-project/llvm $LLVM_BUILD_CFG
  cmake --build . --target install
  cd ../../../
}

build_builtins() {
  mkdir -p out/llvm/builtins-build
  cd out/llvm/builtins-build

  cmake -G Ninja ../../../src/llvm-project/compiler-rt/lib/builtins \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$(realpath ../lib/clang/*) \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DLLVM_CMAKE_DIR=$(realpath ../lib/cmake/llvm)
  cmake --build . --target install
  cd ../../../
}

build_llvm() {
  build_zstd

  mkdir -p out/llvm/build
  cd out/llvm/build

  config_llvm
  set_llvm_cfg LLVM_ENABLE_PROJECTS "clang;clang-tools-extra;polly"
  set_llvm_cfg LLVM_LINK_LLVM_DYLIB ON
  # BUG: latest LLVM shipped with MSYS2 cannot build with LTO
  # set_llvm_cfg LLVM_ENABLE_LTO Thin

  eval cmake -G Ninja ../../../src/llvm-project/llvm $LLVM_BUILD_CFG
  cmake --build . --target install
  cd ../../../

  # Build libclang_rt.builtins-${ARCH}.a for self-contained host linking
  build_builtins

  # We have to build LLD statically to prevent flakiness
  build_lld
}

collect() {
  cp -af out/rust out/collect

  cd out/collect

  find . -name '*.old' -delete
  cp_dir ../llvm/bin llvm-bin
  cp_dir ../lld/bin llvm-bin
  ln -srf llvm-bin/libLLVM*.dll llvm-bin/libclang-cpp.dll bin
  cp -af ../tools/bin tools-bin
  rm -f tools-bin/*.dll
  cp -af $MINGW_PREFIX/bin/yasm.exe tools-bin
  cp -af $MINGW_PREFIX/bin/mingw32-make.exe tools-bin/make.exe

  # Copy MinGW static libraries and stage compiler-rt builtins for self-contained host linking
  local SELF_CONTAINED_LIB=lib/rustlib/$TRIPLE/lib/self-contained
  for lib in \
    libm.a libmingw32.a libmingwex.a libiconv.a libmoldname.a libpthread.a \
    libunwind.a libunwind.dll.a \
    libadvapi32.a libbcrypt.a libcomctl32.a libcomdlg32.a libcredui.a libcrypt32.a \
    libdbghelp.a libgdi32.a libimagehlp.a libiphlpapi.a libkernel32.a libmsimg32.a \
    libmsvcrt.a libntdll.a libodbc32.a libole32.a liboleaut32.a libopengl32.a \
    libpsapi.a librpcrt4.a libsecur32.a libsetupapi.a libshell32.a libsynchronization.a \
    libuser32.a libuserenv.a libuuid.a libwinhttp.a libwinmm.a libwinspool.a \
    libws2_32.a libwsock32.a; do
    cp -af $MINGW_PREFIX/lib/$lib $SELF_CONTAINED_LIB
  done
  cp -af ../llvm/lib/clang/*/lib/windows clang-windows-lib

  (
    export PATH="$(pwd)/bin:$PATH"
    cp_sys_dlls bin/rustc.exe
  )
  cp_sys_dlls llvm-bin/clang.exe
  cp_sys_dlls tools-bin/yasm.exe
  cp_sys_dlls tools-bin/make.exe

  ln -srf bin/std-*.dll lib/rustlib/$TRIPLE/lib

  strip_exe
  cd ../../
}

ndk() {
  dl_ndk
  cd out

  # Copy the whole output folder into ndk
  cp_dir collect ndk/toolchains/rust

  cd ndk/toolchains

  local LLVM_DIR=llvm/prebuilt/$NDK_DIRNAME

  # First copy over all runtime dlls and deduplicate with symlinks
  cp -af rust/llvm-bin/*.dll $LLVM_DIR/bin
  for dll in rust/tools-bin/*.dll; do
    mv -f $dll $LLVM_DIR/bin
    ln -srf $LLVM_DIR/bin/$(basename $dll) ../prebuilt/$NDK_DIRNAME/bin
  done
  for dll in rust/bin/*.dll; do
    if [ -f $LLVM_DIR/bin/$(basename $dll) ]; then
      ln -srf $LLVM_DIR/bin/$(basename $dll) $dll
    fi
  done

  # Replace files with those from the rust toolchain
  touch $LLVM_DIR/bin/lld.exe
  ln -sf lld.exe $LLVM_DIR/bin/ld.exe
  update_dir rust/llvm-bin $LLVM_DIR/bin
  rm -rf rust/llvm-bin

  # Install Windows compiler-rt builtins into Clang's resource dir and expose
  # our built clang and llvm-ar as rustc's self-contained host linker and dlltool.
  mv rust/clang-windows-lib $(echo $LLVM_DIR/lib/clang/*/lib)/windows
  ln -srf $LLVM_DIR/bin/clang.exe rust/bin/${ARCH}-w64-mingw32-clang.exe
  ln -srf $LLVM_DIR/bin/llvm-ar.exe rust/bin/dlltool.exe

  update_dir rust/tools-bin $LLVM_DIR/bin
  update_dir rust/tools-bin ../prebuilt/$NDK_DIRNAME/bin
  update_dir rust/tools-bin ../shader-tools/$NDK_DIRNAME
  rm -rf rust/tools-bin

  cd ../../../
  check_ndk
}

export MSYS=winsymlinks:nativestrict
# Disable Windows UAC installer detection heuristics for tools like rust-installer.exe
export __COMPAT_LAYER=RunAsInvoker
export PATH="$PATH:/c/Program Files/Git/cmd"

# Enable symlink support for git
git config --global core.symlinks true

parse_args $@
