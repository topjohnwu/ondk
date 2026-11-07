#!/usr/bin/env bash

# Copyright 2022-2025 Google LLC.
# SPDX-License-Identifier: Apache-2.0

if ! uname | grep -q 'MINGW64_NT'; then
  echo 'This script should run on MSYS2 bash'
  echo
  exit 1
fi

. common.sh

OS='windows'
NDK_DIRNAME='windows-x86_64'
# msys-2.0.dll is emulated x86_64 on ARM64 Windows, so `uname -m` returns x86_64.
# Check $MSYSTEM_CARCH or `uname -s` instead, and force a POSIX MINGW_PREFIX for `ldd`.
if [ "$MSYSTEM_CARCH" = "aarch64" ] || uname -s | grep -q 'ARM64'; then
  ARCH='aarch64'
  TRIPLE='aarch64-pc-windows-gnullvm'
  MINGW_PREFIX='/clangarm64'
else
  ARCH='x86_64'
  TRIPLE='x86_64-pc-windows-gnu'
  MINGW_PREFIX='/mingw64'
fi
DYN_EXT='dll'
EXE_FMT='PE32+'

config_rust_build() {
  unset RUST_CFG

  # MinGW libstdc++ is incompatible with clang when LTO is enabled, we have to use libc++
  set_build_cfg llvm.use-libcxx true
  set_build_cfg rust.use-lld true
  set_build_cfg dist.include-mingw-linker true

  # Prevent cc-rs from inheriting -flto=thin from rustc flags, as MSYS2's host clang
  # is newer than ONDK's LLVM and emits bitcode that stage1 rustc/lld cannot read.
  export CFLAGS="-fno-lto"
  export CXXFLAGS="-fno-lto"

  # Expose all LLVM dlls to stage1 rustc
  rm -rf out/llvm/dlls
  mkdir -p out/llvm/dlls
  cp -af out/llvm/bin/*.dll out/llvm/dlls
  export PATH="$(realpath out/llvm/dlls):$PATH"
}

config_tools_build() {
  set_tools_cfg CMAKE_C_COMPILER clang
  set_tools_cfg CMAKE_CXX_COMPILER clang++
  set_tools_cfg CMAKE_C_FLAGS "-Os -fomit-frame-pointer -w"
  set_tools_cfg CMAKE_CXX_FLAGS "-Os -fomit-frame-pointer -w -fno-rtti -fno-exceptions -stdlib=libc++ -include type_traits"
  set_tools_cfg CMAKE_EXE_LINKER_FLAGS "-fuse-ld=lld -static -static-libgcc -static-libstdc++"
  set_tools_cfg CMAKE_SHARED_LINKER_FLAGS "-fuse-ld=lld -static -static-libgcc -static-libstdc++"
}

build_toolbox() {
  mkdir -p out/tools/bin
  local src_dir="src/ndk/sources/host-tools/toolbox"
  local flags="-Os -fomit-frame-pointer -fuse-ld=lld -static -static-libgcc"
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
  if [ "$ARCH" = "aarch64" ]; then
    # LLVM does not recognize Rust's 'windows-gnullvm' environment name in triples
    set_llvm_cfg LLVM_DEFAULT_TARGET_TRIPLE aarch64-pc-windows-gnu
    # Default the MinGW driver to LLVM runtime libraries to match windows-gnullvm
    set_llvm_cfg CLANG_DEFAULT_RTLIB compiler-rt
    set_llvm_cfg CLANG_DEFAULT_UNWINDLIB libunwind
    set_llvm_cfg CLANG_DEFAULT_CXX_STDLIB libc++
  fi
}

build_lld() {
  mkdir -p out/lld/build
  cd out/lld/build

  config_llvm
  set_llvm_cfg LLVM_ENABLE_PROJECTS lld
  set_llvm_cfg LLVM_BUILD_TOOLS OFF
  set_llvm_cfg CMAKE_EXE_LINKER_FLAGS "-s -static -static-libgcc"

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

  if [ "$ARCH" = "aarch64" ]; then
    # Build libclang_rt.builtins-aarch64.a for self-contained host linking
    build_builtins
  fi

  # We have to build LLD statically to prevent flakiness
  build_lld
}

collect() {
  # Build rust-mingw
  config_rust_build
  cd src/rust
  eval python3 ./x.py --config ../../bootstrap.toml --build $TRIPLE $RUST_CFG dist rust-mingw
  cd ../../

  # Copy sysroot
  cp -af out/rust out/collect

  # Install rust-mingw
  tar xvf src/rust/build/dist/rust-mingw-nightly-${TRIPLE}.tar.gz -C out
  bash out/rust-mingw-nightly-${TRIPLE}/install.sh --prefix=out/collect --components=rust-mingw
  rm -rf out/rust-mingw-nightly-${TRIPLE}

  cd out/collect

  find . -name '*.old' -delete
  cp -af ../llvm/bin llvm-bin || true
  cp -an ../llvm/bin/. llvm-bin/.
  cp -af ../lld/bin/. llvm-bin/. || true
  cp -an ../lld/bin/. llvm-bin/.
  for dll in llvm-bin/libLLVM*.dll; do
    ln -sf ../$dll bin
  done
  cp -af ../tools/bin tools-bin
  rm -f tools-bin/*.dll
  cp -af $MINGW_PREFIX/bin/yasm.exe tools-bin
  cp -af $MINGW_PREFIX/bin/mingw32-make.exe tools-bin/make.exe

  if [ "$ARCH" = "aarch64" ]; then
    # rust-mingw for windows-gnullvm only bundles 6 Windows import libs (unlike windows-gnu's
    # make_win_dist which bundles 32) and no bin/self-contained. Bundle the full make_win_dist
    # import lib set and stage the compiler-rt builtins built during build_llvm.
    local SELF_CONTAINED_LIB=lib/rustlib/$TRIPLE/lib/self-contained
    for lib in \
      libm.a libiconv.a libmoldname.a libpthread.a \
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
  else
    local MINGW_DIR=lib/rustlib/$TRIPLE/bin/self-contained

    # Fix-up mingw components
    rm $MINGW_DIR/dlltool.exe
    cp -af $MINGW_PREFIX/bin/dlltool.exe $MINGW_PREFIX/bin/as.exe bin

    # Copy runtime dlls
    (
      export PATH="$(pwd)/bin:$PATH"
      cp_sys_dlls bin/rustc.exe
      cp_sys_dlls bin/dlltool.exe
      cp_sys_dlls $MINGW_DIR/ld.exe
      cp_sys_dlls $MINGW_DIR/x86_64-w64-mingw32-gcc.exe
    )
  fi
  cp_sys_dlls llvm-bin/clang.exe
  cp_sys_dlls tools-bin/yasm.exe
  cp_sys_dlls tools-bin/make.exe

  for dll in lib/rustlib/$TRIPLE/lib/*.dll; do
    dll=$(basename $dll)
    if [ -f bin/$dll ]; then
      ln -sf ../../../../bin/$dll lib/rustlib/$TRIPLE/lib/$dll
    fi
  done

  strip_exe
  cd ../../
}

cp_sys_dlls() {
  local dir=$(dirname $1)
  for lib in $(ldd $1 | grep " $MINGW_PREFIX/bin/" | awk '{ print $1 }'); do
    cp -v $MINGW_PREFIX/bin/$lib $dir
  done
}

ndk() {
  dl_ndk
  cd out

  # Copy the whole output folder into ndk
  cp -af collect ndk/toolchains/rust || true
  cp -an collect/. ndk/toolchains/rust/.

  cd ndk/toolchains

  local LLVM_DIR=llvm/prebuilt/$NDK_DIRNAME

  # First copy over all runtime dlls and deduplicate with symlinks
  cp -af rust/llvm-bin/*.dll $LLVM_DIR/bin
  cp -af rust/tools-bin/*.dll $LLVM_DIR/bin
  for dll in rust/tools-bin/*.dll; do
    dll=$(basename $dll)
    ln -sf ../../../toolchains/$LLVM_DIR/bin/$dll ../prebuilt/$NDK_DIRNAME/bin/$dll
  done
  for dll in rust/bin/*.dll; do
    dll=$(basename $dll)
    if [ -f $LLVM_DIR/bin/$dll ]; then
      ln -sf ../../$LLVM_DIR/bin/$dll rust/bin/$dll
    fi
  done

  # Replace files with those from the rust toolchain
  touch $LLVM_DIR/bin/lld.exe
  ln -sf lld.exe $LLVM_DIR/bin/ld.exe
  update_dir rust/llvm-bin $LLVM_DIR/bin
  rm -rf rust/llvm-bin
  if [ "$ARCH" = "aarch64" ]; then
    # Install Windows compiler-rt builtins into Clang's resource dir and expose
    # our built clang and llvm-ar as rustc's self-contained host linker and dlltool.
    mv rust/clang-windows-lib $(echo $LLVM_DIR/lib/clang/*/lib)/windows
    ln -sf ../../$LLVM_DIR/bin/clang.exe rust/bin/aarch64-w64-mingw32-clang.exe
    ln -sf ../../$LLVM_DIR/bin/libclang-cpp.dll rust/bin/libclang-cpp.dll
    ln -sf ../../$LLVM_DIR/bin/llvm-ar.exe rust/bin/dlltool.exe
  else
    for dll in rust/lib/rustlib/$TRIPLE/bin/self-contained/*.dll; do
      dll=$(basename $dll)
      if [ -f $LLVM_DIR/bin/$dll ]; then
        ln -sf ../../../../../../$LLVM_DIR/bin/$dll rust/lib/rustlib/$TRIPLE/bin/self-contained/$dll
      fi
    done
  fi
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
