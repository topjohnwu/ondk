# Oxidized NDK

This is not an officially supported Google product.

Oxidized NDK (ONDK) is an unofficial repackaged [Android NDK](https://developer.android.com/ndk) that includes a Rust toolchain.
This repository hosts build scripts to build and package ONDK using [GitHub Actions](https://github.com/topjohnwu/ondk/actions).
Every file included in the final package either originates from the official NDK zip or is built in GitHub Actions.

This project does not include or attempt to do any modifications to Rust and LLVM.<br>
This project is for experimental purposes, and **does not** guarantee any Android NDK or Rust functionality.<br>
Use at your own risk.

Download the latest ONDK in [releases](https://github.com/topjohnwu/ondk/releases/latest).

Supports all NDK host platforms:<br>
Linux (x64), Windows (x64), and macOS (x64 + arm64, universal binaries).

## How to Use

For building C/C++ code, ONDK is just like any ordinary Android NDK, no special configurations are needed.

For building Rust code, link ONDK's Rust toolchain with `rustup`:

```
rustup toolchain link <name> <ondk>/toolchains/rust
```

The `std` crate is _intentionally_ not prebuilt and included in ONDK, so building requires a little bit of setup.<br>
Here is an example for building a project targeting API 21 for ARM64:

```bash
LLVM_BIN="<ondk>/toolchains/llvm/prebuilt/<os>-x86_64/bin"

# We need to tell cargo where to find the NDK linker for Android.
# You can also set this in config.toml, check the official documentation.
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$LLVM_BIN/aarch64-linux-android21-clang"

# We also need to specify the NDK C compiler with proper flags.
# This is used for feature detection internally in std's build system.
export TARGET_CC="$LLVM_BIN/clang"
export TARGET_CFLAGS='--target=aarch64-linux-android21'

# Finally, build our project with -Z build-std
cargo <+name> build -Z build-std --target aarch64-linux-android
```

P.S. I strongly recommend checking out [min-sized-rust](https://github.com/johnthagen/min-sized-rust) to minimize Rust binaries.

## How ONDK is Built

- Download the latest [Rust](https://github.com/rust-lang/rust) source code
- Apply some patches to its build system (no patches to any code that is part of the final product)
- Build a Rust sysroot with `rustc` + `cargo` + `std` source code + `clang`
- Download the latest stable [NDK](https://developer.android.com/ndk/downloads) zip
- Replace **only** the LLVM/Clang executables of NDK, and copy the Rust sysroot into the package

## FAQ

- **Q: Why do we need this? Doesn't the official Rust toolchains already work for Android?**<br>
  A: I started this project because I wanted to enable [Cross-Language LTO](https://doc.rust-lang.org/rustc/linker-plugin-lto.html). This allows C/C++ and Rust code to be optimized together during link time, extremely useful for mixed language projects. However, because NDK's Clang and official Rust toolchains are not built with the same LLVM, their LTO output format is very likely to be incompatible with each other. ONDK builds `rustc` and `clang` from scratch with the same LLVM source code to ensure cross-language LTO compatibility.

- **Q: Why is `std` not prebuilt for Android targets?**<br>
  A: I personally strongly dislike the idea of prebuilding any dependency that will be included in the final product of a project. Building `std` along with the project's compilation pipeline makes it easy to disable features, such as removing `unwind` for `panic`, and allow `std` to be LTO-ed with your project. The toolchain should not forcefully include and link code that is unnecessary for your project!

## License

    Copyright 2022-2024 Google LLC

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        https://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
