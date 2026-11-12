#!/usr/bin/env python3
# Copyright 2022-2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

import argparse
import ast
import base64
from collections import deque
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import time
import tomllib
import types
from typing import Any
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

RUST_VERSION = '1.97.1'
ZLIB_VERSION = '2.3.3'
YASM_COMMIT = '09d1bc90ed53d0ec3e9b074f111058cbf262ed56'
NDK_VERSION = 'r30-beta2'
OUTPUT_VERSION = 'r30.1'

AOSP_URL = 'https://android.googlesource.com'

ROOT = Path(__file__).resolve().parent
SRC_DIR = ROOT / 'src'
BUILD_DIR = ROOT / 'build'
OUT_DIR = ROOT / 'out'
DIST_DIR = ROOT / 'dist'
PATCHES_DIR = ROOT / 'patches'
ONDK_DIR = OUT_DIR / f'ondk-{OUTPUT_VERSION}'


# -----------------------------------------------------------------------------
# Filesystem, Process & Gitiles Primitives
# -----------------------------------------------------------------------------

def run(cmd: list[str | Path], *, cwd: Path = ROOT, env: dict[str, str] | None = None):
    subprocess.run([str(c) for c in cmd], cwd=cwd, env=env, check=True)


def git(*args: str | Path, cwd: Path = ROOT, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ['git', '-c', 'core.symlinks=true', *(str(a) for a in args)],
        cwd=cwd,
        check=check,
    )


def apply_patch(target_dir: Path, patch_file: Path):
    data = patch_file.read_bytes().replace(b'\r\n', b'\n')
    subprocess.run(['patch', '-p1'], cwd=target_dir, input=data, check=True)


def parallel(*tasks: Callable[[], object], max_workers: int | None = None):
    if not tasks:
        return
    with ThreadPoolExecutor(max_workers=max_workers or len(tasks)) as pool:
        futures = [pool.submit(fn) for fn in tasks]
        for fut in futures:
            fut.result()


def _remove_readonly(func: Callable[..., Any], path: str, _: Any):
    os.chmod(path, stat.S_IWRITE)
    func(path)


def _rm_batch_unix(batch: list[str]):
    if subprocess.run(['rm', '-rf', '--', *batch], stderr=subprocess.DEVNULL).returncode != 0:
        existing = [p for p in batch if os.path.lexists(p)]
        if existing:
            subprocess.run(['chmod', '-R', 'u+rwX', '--', *existing])
            run(['rm', '-rf', '--', *existing])


def _rmtree_unix(dirs: list[Path]):
    abs_dirs = list(dict.fromkeys(Path(os.path.abspath(d)) for d in dirs))
    dir_set = set(abs_dirs)
    frontier = deque(str(d) for d in abs_dirs if not any(p in dir_set for p in d.parents))

    workers = min(os.cpu_count() or 4, 16)
    target_shards = workers * 8
    skeletons: list[str] = []
    targets: list[str] = []

    while frontier and len(frontier) + len(targets) // 64 < target_shards:
        d = frontier.popleft()
        if not os.access(d, os.W_OK | os.X_OK):
            os.chmod(d, stat.S_IRWXU)
        skeletons.append(d)
        with os.scandir(d) as it:
            for entry in it:
                if entry.is_dir(follow_symlinks=False):
                    frontier.append(entry.path)
                else:
                    targets.append(entry.path)

    targets.extend(frontier)
    if targets:
        num_batches = min(len(targets), workers * 4)
        batches = [targets[i::num_batches] for i in range(num_batches)]
        parallel(*(lambda b=b: _rm_batch_unix(b) for b in batches), max_workers=workers)

    for d in reversed(skeletons):
        os.rmdir(d)


def rm_rf(*paths: Path):
    dirs: list[Path] = []
    for p in dict.fromkeys(paths):
        try:
            mode = p.lstat().st_mode
        except FileNotFoundError:
            continue
        if stat.S_ISDIR(mode):
            dirs.append(p)
        else:
            try:
                p.unlink()
            except PermissionError:
                if os.name == 'nt' and stat.S_ISLNK(mode):
                    p.rmdir()
                else:
                    os.chmod(p, stat.S_IWRITE)
                    p.unlink()
    if dirs:
        if os.name == 'nt':
            for d in dirs:
                if sys.version_info >= (3, 12):
                    shutil.rmtree(d, onexc=_remove_readonly)
                else:
                    shutil.rmtree(d, onerror=_remove_readonly)
        else:
            _rmtree_unix(dirs)


def rm_glob(base: Path, *patterns: str):
    rm_rf(*(p for pat in patterns for p in base.glob(pat)))


def copy_file(src: Path, dst: Path):
    rm_rf(dst)
    shutil.copy2(src, dst)


def copy_symlink(src_link: Path, dst_link: Path):
    rm_rf(dst_link)
    target = os.readlink(src_link)
    if os.name == 'nt':
        target = target.replace('/', '\\')
    dst_link.symlink_to(target, target_is_directory=src_link.is_dir())


def symlink_rel(target: Path, link: Path, *, is_dir: bool | None = None):
    rm_rf(link)
    rel = os.path.relpath(target, link.parent)
    if os.name == 'nt':
        rel = rel.replace('/', '\\')
    link.symlink_to(rel, target_is_directory=target.is_dir() if is_dir is None else is_dir)


def copy_tree(src: Path, dst: Path):
    """Two-pass copy (files/dirs first, symlinks second) for Windows symlink safety."""
    dst.mkdir(parents=True, exist_ok=True)
    symlinks: list[tuple[Path, Path]] = []

    for root, dirs, files in os.walk(src, followlinks=False):
        dst_root = dst / Path(root).relative_to(src)
        dst_root.mkdir(parents=True, exist_ok=True)

        real_dirs = []
        for d in dirs:
            s_dir = Path(root) / d
            if s_dir.is_symlink():
                symlinks.append((s_dir, dst_root / d))
            else:
                real_dirs.append(d)
                (dst_root / d).mkdir(exist_ok=True)
        dirs[:] = real_dirs

        for f in files:
            s_file = Path(root) / f
            if s_file.is_symlink():
                symlinks.append((s_file, dst_root / f))
            else:
                copy_file(s_file, dst_root / f)

    for s_link, d_link in symlinks:
        copy_symlink(s_link, d_link)


def overlay_dir(src: Path, dst: Path, *, ignore_suffix: str = ''):
    """Replace matching entries already present in dst with built artifacts from src."""
    entries = [d for d in dst.iterdir() if not (ignore_suffix and d.name.endswith(ignore_suffix))]
    for d in entries:
        s = src / d.name
        if not s.is_symlink() and s.is_file():
            copy_file(s, d)
    for d in entries:
        s = src / d.name
        if s.is_symlink():
            copy_symlink(s, d)


def sha256_file(path: Path) -> str:
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def dump_toml(data: dict[str, Any], prefix: str = '') -> str:
    def fmt(v: Any) -> str:
        if isinstance(v, bool):
            return 'true' if v else 'false'
        if isinstance(v, int):
            return str(v)
        if isinstance(v, str):
            return json.dumps(v)
        if isinstance(v, list):
            return '[' + ', '.join(fmt(x) for x in v) + ']'
        raise TypeError(f'Unsupported TOML value: {v!r}')

    scalars = [f'{k} = {fmt(v)}' for k, v in data.items() if not isinstance(v, dict)]
    blocks: list[str] = []
    if scalars:
        header = [f'[{prefix}]'] if prefix else []
        blocks.append('\n'.join(header + scalars))
    for k, v in data.items():
        if isinstance(v, dict):
            sub = f'{prefix}.{k}' if prefix else k
            blocks.append(dump_toml(v, sub).rstrip('\n'))
    return '\n\n'.join(blocks) + '\n'


def gitiles_fetch(url: str, retries: int = 5) -> bytes:
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            retry_after = e.headers.get('Retry-After') if e.headers else None
            e.close()
            if e.code not in (429, 500, 502, 503, 504) or attempt == retries - 1:
                raise
            delay = int(retry_after) if retry_after and retry_after.isdigit() else 2 ** attempt
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt == retries - 1:
                raise
            delay = 2 ** attempt
        time.sleep(delay)
    raise AssertionError('unreachable')


def gitiles_text(path: str) -> str:
    return base64.b64decode(gitiles_fetch(f'{AOSP_URL}/{path}?format=TEXT')).decode('utf-8')


def gitiles_json(path: str) -> dict:
    data = gitiles_fetch(f'{AOSP_URL}/{path}?format=JSON').decode('utf-8')
    return json.loads(data.split('\n', 1)[1])  # Strip Gitiles ")]}'\n" prefix


def extract_var(py_src: str, name: str) -> str:
    for node in ast.parse(py_src).body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return ast.literal_eval(node.value)
    raise KeyError(f'{name} not found')


def clone_bundle(repo: str, ref: str, dest: str | None = None):
    url = f'{AOSP_URL}/{repo}'
    target_dir = SRC_DIR / (dest or repo.rsplit('/', 1)[-1])
    print(f"Cloning into '{target_dir}'...", flush=True)
    rm_rf(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)

    git('init', '-q', cwd=target_dir)
    git('remote', 'add', 'origin', url, cwd=target_dir)

    bundle = target_dir / 'clone.bundle'
    if subprocess.run(['curl', '-fsSL', f'{url}/clone.bundle', '-o', 'clone.bundle'], cwd=target_dir).returncode == 0:
        git('fetch', '-q', '-u', 'clone.bundle', '+refs/*:refs/*', cwd=target_dir)
        bundle.unlink()
        if git('reset', '--hard', ref, cwd=target_dir, check=False).returncode == 0:
            return

    bundle.unlink(missing_ok=True)
    git('fetch', '--depth', '1', 'origin', ref, cwd=target_dir)
    git('reset', '--hard', 'FETCH_HEAD', cwd=target_dir)


def clone_sha(url: str, sha: str, dest: str | None = None):
    target_dir = SRC_DIR / (dest or url.rsplit('/', 1)[-1])
    print(f"Cloning into '{target_dir}'...", flush=True)
    rm_rf(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)
    git('init', '-q', cwd=target_dir)
    git('remote', 'add', 'origin', url, cwd=target_dir)
    git('fetch', '--depth', '1', 'origin', sha, cwd=target_dir)
    git('reset', '--hard', 'FETCH_HEAD', cwd=target_dir)


def git_clone_branch(url: str, branch: str, dest: str | None = None):
    target_dir = SRC_DIR / (dest or url.rsplit('/', 1)[-1])
    rm_rf(target_dir)
    git('clone', '--single-branch', '--depth', '1', '--branch', branch, url, target_dir)


# -----------------------------------------------------------------------------
# Shared Build Pipeline & Host Abstraction
# -----------------------------------------------------------------------------

class Host:
    os_name: str
    arch: str
    ndk_dirname: str
    triple: str
    dyn_ext: str = ''
    exe_suffix: str = ''

    def __init__(self, arch: str):
        self.arch = arch

    def setup_env(self):
        pass

    def is_host_binary(self, path: Path) -> bool:
        raise NotImplementedError

    def strip_cmd(self) -> list[str | Path]:
        return [OUT_DIR / f'llvm/bin/llvm-strip{self.exe_suffix}', '--strip-all-gnu']

    def iter_host_binaries(self) -> Iterator[Path]:
        for root, dirs, files in os.walk(ONDK_DIR, followlinks=False):
            rel_root = Path(root).relative_to(ONDK_DIR)
            dirs[:] = [
                d for d in dirs
                if d != 'sysroot'
                and (rel_root / d).as_posix() not in ('simpleperf/bin/android', 'toolchains/rust/lib/rustlib/src')
                and not (rel_root / d).as_posix().endswith('/lib/clang')
            ]
            for f in files:
                p = Path(root) / f
                if self.is_host_binary(p):
                    yield p

    def strip_binaries(self):
        targets = [
            p.relative_to(ONDK_DIR) for p in self.iter_host_binaries()
            if not re.match(r'^(lib)?std-[0-9a-f]+\.', p.name)
        ]
        if targets:
            run([*self.strip_cmd(), *targets], cwd=ONDK_DIR)

    def cmake_install(self, src: Path, build_dir: Path, cfg: dict[str, str | Path]):
        defs = [f'-D{k}={v.as_posix() if isinstance(v, Path) else v}' for k, v in cfg.items()]
        run(['cmake', '-G', 'Ninja', '-S', src, '-B', build_dir, *defs])
        run(['cmake', '--build', build_dir, '--target', 'install'])

    # -- Clone Stage ----------------------------------------------------------

    def extra_ndk_repos(self) -> list[str]:
        return []

    def clone_ndk(self):
        ndk_dirs = ('llvm-project', 'llvm_android', 'toolchain-utils', 'zstd', 'zlib', 'shaderc', 'make', 'yasm', 'ndk')
        rm_rf(*(SRC_DIR / name for name in ndk_dirs))

        ndk_tag = f'ndk-{NDK_VERSION}'
        clang_ver = extract_var(gitiles_text(f'platform/ndk/+/refs/tags/{ndk_tag}/ndk/toolchains.py'), 'CLANG_VERSION')

        prebuilt_path = f'platform/prebuilts/clang/host/linux-x86/+/refs/tags/{ndk_tag}/{clang_ver}'
        manifest_name = next(
            e['name'] for e in gitiles_json(f'{prebuilt_path}/')['entries']
            if e['name'].startswith('manifest_') and e['name'].endswith('.xml')
        )
        manifest_xml = gitiles_text(f'{prebuilt_path}/{manifest_name}')
        revs = {p.attrib['name']: p.attrib['revision'] for p in ET.fromstring(manifest_xml).findall('project')}

        top_ndk_repos = ['platform/external/shaderc/shaderc', 'toolchain/make', *self.extra_ndk_repos()]
        parallel(
            lambda: clone_bundle('toolchain/llvm_android', revs['toolchain/llvm_android']),
            lambda: clone_bundle('platform/external/toolchain-utils', revs['platform/external/toolchain-utils']),
            lambda: clone_bundle('platform/external/zstd', revs['platform/external/zstd']),
            lambda: git_clone_branch('https://github.com/zlib-ng/zlib-ng', ZLIB_VERSION, 'zlib'),
            *(lambda r=repo: clone_bundle(r, ndk_tag) for repo in top_ndk_repos),
            lambda: clone_sha('https://github.com/yasm/yasm', YASM_COMMIT),
        )

        sys.path.insert(0, str(SRC_DIR / 'llvm_android/src'))
        from llvm_android import android_version
        llvm_sha = android_version.get_git_sha()

        parallel(
            lambda: clone_sha('https://github.com/llvm/llvm-project', llvm_sha),
            lambda: clone_bundle('platform/external/shaderc/glslang', ndk_tag, 'shaderc/third_party/glslang'),
            lambda: clone_bundle('platform/external/shaderc/spirv-headers', ndk_tag, 'shaderc/third_party/spirv-headers'),
            lambda: clone_bundle('platform/external/shaderc/spirv-tools', ndk_tag, 'shaderc/third_party/spirv-tools'),
        )

        apply_patch(SRC_DIR / 'make', PATCHES_DIR / 'fix_make_glibc.patch')

        if os.name == 'nt':
            sys.modules.setdefault('fcntl', types.ModuleType('fcntl'))
        sys.path.insert(0, str(SRC_DIR / 'toolchain-utils'))
        from llvm_tools import patch_manager

        rc = patch_manager.main([
            '--svn_version', android_version.get_svn_revision_number(),
            '--patch_metadata_file', str(SRC_DIR / 'llvm_android/patches/PATCHES.json'),
            '--src_path', str(SRC_DIR / 'llvm-project'),
        ])
        if rc:
            sys.exit(rc)

    def clone_rust(self):
        rust_dir = SRC_DIR / 'rust'
        git_clone_branch('https://github.com/rust-lang/rust', RUST_VERSION)
        for sub in ('src/llvm-project', 'src/gcc', 'src/tools/enzyme'):
            git('config', 'set', '-f', '.gitmodules', f'submodule.{sub}.update', 'none', cwd=rust_dir)
        git('submodule', 'update', '--init', '--depth=1', cwd=rust_dir)

        for patch_name in ('support_ndk_llvm_r30.patch', 'support_static_libcxx.patch', 'support_external_lld.patch'):
            apply_patch(rust_dir, PATCHES_DIR / patch_name)

        symlink_rel(SRC_DIR / 'llvm-project', rust_dir / 'src/llvm-project', is_dir=True)

    # -- Build Stage: Tools, LLVM & Rust --------------------------------------

    def tools_cmake_cfg(self, prefix: Path) -> dict[str, str | Path]:
        return {
            'CMAKE_BUILD_TYPE': 'Release',
            'CMAKE_INSTALL_PREFIX': prefix,
            'CMAKE_POLICY_VERSION_MINIMUM': '3.5',
            'CMAKE_C_FLAGS': '-Os -fomit-frame-pointer -w',
            'CMAKE_CXX_FLAGS': '-Os -fomit-frame-pointer -w -fno-rtti -fno-exceptions',
        }

    def build_tools(self):
        tools_out = OUT_DIR / 'tools'
        rm_rf(tools_out)
        specs: list[tuple[str, dict[str, str | Path]]] = [
            ('shaderc', {
                'SHADERC_SKIP_TESTS': 'ON',
                'SHADERC_SKIP_EXAMPLES': 'ON',
                'SHADERC_SKIP_COPYRIGHT_CHECK': 'ON',
                'SPIRV-Headers_SOURCE_DIR': SRC_DIR / 'shaderc/third_party/spirv-headers',
            }),
            ('make', {'CMAKE_C_STANDARD': '17'}),
            ('yasm', {'BUILD_SHARED_LIBS': 'OFF', 'YASM_BUILD_TESTS': 'OFF'}),
        ]
        for name, extra in specs:
            self.cmake_install(SRC_DIR / name, BUILD_DIR / name, self.tools_cmake_cfg(tools_out) | extra)

    def llvm_cmake_cfg(self, prefix: Path) -> dict[str, str | Path]:
        ver_src = (SRC_DIR / 'llvm_android/src/llvm_android/android_version.py').read_text()
        patch_level = extract_var(ver_src, '_patch_level')
        svn_rev = extract_var(ver_src, '_svn_revision')
        return {
            'CMAKE_BUILD_TYPE': 'Release',
            'CMAKE_INSTALL_PREFIX': prefix,
            'LLVM_TARGETS_TO_BUILD': 'AArch64;ARM;BPF;RISCV;WebAssembly;X86',
            'LLVM_VERSION_PATCH': patch_level,
            'LLVM_VERSION_SUFFIX': '',
            'CLANG_VENDOR': f'Android (ONDK {OUTPUT_VERSION}, based on {svn_rev})',
            'CLANG_REPOSITORY_STRING': 'https://android.googlesource.com/toolchain/llvm-project',
            'BUG_REPORT_URL': 'https://github.com/topjohnwu/ondk/issues',
            'CLANG_DEFAULT_LINKER': 'lld',
            'CLANG_DEFAULT_OBJCOPY': 'llvm-objcopy',
            'CLANG_ENABLE_OBJC_REWRITER': 'OFF',
            'CLANG_PYTHON_BINDINGS_VERSIONS': '3',
            'CMAKE_PLATFORM_NO_VERSIONED_SONAME': 'ON',
            'LLVM_TARGET_ARCH': self.arch,
            'LLVM_HOST_TRIPLE': self.triple,
            'LLVM_DEFAULT_TARGET_TRIPLE': self.triple,
            'LLVM_ENABLE_ZLIB': 'FORCE_ON',
            'ZLIB_LIBRARY': OUT_DIR / 'zlib/lib/libz.a',
            'ZLIB_INCLUDE_DIR': OUT_DIR / 'zlib/include',
            'LLVM_ENABLE_LIBXML2': 'OFF',
            'LLVM_ENABLE_ZSTD': 'FORCE_ON',
            'LLVM_USE_STATIC_ZSTD': 'ON',
            'zstd_LIBRARY': OUT_DIR / 'zstd/lib/libzstd.a',
            'zstd_INCLUDE_DIR': OUT_DIR / 'zstd/include',
            'LLVM_INCLUDE_TESTS': 'OFF',
            'LLVM_ENABLE_LIBEDIT': 'OFF',
            'LLVM_ENABLE_TERMINFO': 'OFF',
            'LLVM_ENABLE_BINDINGS': 'OFF',
            'LLVM_ENABLE_Z3_SOLVER': 'OFF',
            'LLVM_ENABLE_ASSERTIONS': 'OFF',
            'LLVM_UNREACHABLE_OPTIMIZE': 'OFF',
            'LLVM_INCLUDE_EXAMPLES': 'OFF',
            'LLVM_INCLUDE_DOCS': 'OFF',
            'LLVM_INCLUDE_BENCHMARKS': 'OFF',
            'LLVM_ENABLE_WARNINGS': 'OFF',
            'LLVM_INSTALL_UTILS': 'ON',
            'LLVM_ENABLE_PROJECTS': 'clang;lld;clang-tools-extra;polly;bolt',
            'LLVM_ENABLE_LTO': 'Thin',
            'LLVM_ENABLE_PLUGINS': 'FORCE_ON',
        }

    def build_llvm_deps(self):
        self.cmake_install(SRC_DIR / 'zlib', BUILD_DIR / 'zlib', self.tools_cmake_cfg(OUT_DIR / 'zlib') | {
            'CMAKE_INSTALL_LIBDIR': 'lib',
            'CMAKE_POSITION_INDEPENDENT_CODE': 'ON',
            'ZLIB_COMPAT': 'ON',
            'BUILD_SHARED_LIBS': 'OFF',
            'BUILD_TESTING': 'OFF',
        })
        self.cmake_install(SRC_DIR / 'zstd/build/cmake', BUILD_DIR / 'zstd', self.tools_cmake_cfg(OUT_DIR / 'zstd') | {
            'CMAKE_INSTALL_LIBDIR': 'lib',
            'CMAKE_POSITION_INDEPENDENT_CODE': 'ON',
            'ZSTD_BUILD_PROGRAMS': 'OFF',
            'ZSTD_BUILD_SHARED': 'OFF',
        })

    def build_llvm(self):
        rm_rf(OUT_DIR / 'llvm', OUT_DIR / 'zlib', OUT_DIR / 'zstd')
        self.build_llvm_deps()
        llvm_out = OUT_DIR / 'llvm'
        cfg = self.llvm_cmake_cfg(llvm_out) | {'LLVM_LINK_LLVM_DYLIB': 'ON'}
        self.cmake_install(SRC_DIR / 'llvm-project/llvm', BUILD_DIR / 'llvm', cfg)

    def build_ndk(self):
        self.build_llvm()
        self.build_tools()

    def rust_bootstrap_cfg(self, env: dict[str, str]) -> dict[str, Any]:
        cfg = tomllib.loads((ROOT / 'bootstrap.toml').read_text())
        cfg.setdefault('build', {})['build-dir'] = (BUILD_DIR / 'rust').as_posix()
        cfg.setdefault('install', {})['prefix'] = (OUT_DIR / 'rust').as_posix()
        cfg.setdefault('target', {})[self.triple] = {
            'llvm-config': (OUT_DIR / f'llvm/bin/llvm-config{self.exe_suffix}').as_posix(),
        }
        return cfg

    def build_rust(self):
        rm_rf(OUT_DIR / 'rust')
        env = os.environ.copy()
        BUILD_DIR.mkdir(parents=True, exist_ok=True)
        cfg_path = BUILD_DIR / 'bootstrap.toml'
        cfg_path.write_text(dump_toml(self.rust_bootstrap_cfg(env)))

        run([sys.executable, './x.py', '--config', cfg_path.as_posix(), '--build', self.triple, 'install'],
            cwd=SRC_DIR / 'rust', env=env)

    # -- NDK Packaging & Verification Stage -----------------------------------

    def prepare_ndk(self) -> dict[Path, str]:
        ndk_zip = ROOT / f'android-ndk-{NDK_VERSION}-{self.os_name}.zip'
        extract_tmp = BUILD_DIR / 'ndk-tmp'

        if not ndk_zip.exists():
            url = f'https://dl.google.com/android/repository/{ndk_zip.name}'
            print(f'Downloading {url}...', flush=True)
            part = ndk_zip.with_suffix('.zip.part')
            rm_rf(part)
            run(['curl', '-fSL', '--retry', '3', '-o', part.name, url], cwd=ROOT)
            part.rename(ndk_zip)

        rm_rf(extract_tmp, ONDK_DIR)
        extract_tmp.mkdir(parents=True, exist_ok=True)
        rel_zip = Path(os.path.relpath(ndk_zip, extract_tmp)).as_posix()
        run(['unzip', '-q', rel_zip], cwd=extract_tmp)
        extracted_dirs = list(extract_tmp.iterdir())
        if len(extracted_dirs) != 1:
            sys.exit(f'Unexpected archive layout in {ndk_zip.name}: {extracted_dirs}')
        extracted_dirs[0].rename(ONDK_DIR)
        rm_rf(extract_tmp)
        (ONDK_DIR / 'ONDK_VERSION').write_text(f'{OUTPUT_VERSION}\n')

        llvm_dir = ONDK_DIR / f'toolchains/llvm/prebuilt/{self.ndk_dirname}'
        prebuilt_bin = ONDK_DIR / f'prebuilt/{self.ndk_dirname}/bin'

        rm_glob(llvm_dir,
                'python3', 'musl',
                'bin/lldb*', 'bin/liblldb*', 'bin/libxml2*', 'bin/libwinpthread*',
                'lib/liblldb*', 'lib/libpython*', 'lib/python*', 'lib/site-packages',
                'lib/libxml2*', 'lib/libedit*', 'lib/libncurses*', 'lib/libform*',
                'lib/libpanel*', 'lib/liblzma*', 'lib/libwinpthread*', 'lib/libc++*',
                'lib/libunwind*', 'lib/libsimpleperf_readelf.a', 'lib/LLVMPolly.so',
                'lib/*-linux-*', 'lib/*-windows-*')
        rm_glob(ONDK_DIR, 'ndk-gdb*', 'ndk-lldb*', 'ndk-stack*',
                f'shader-tools/{self.ndk_dirname}/libc++*', f'simpleperf/bin/{self.os_name}')
        rm_glob(prebuilt_bin, 'ndk-gdb*', 'ndkgdb.pyz', 'ndk-stack*', 'ndkstack.pyz',
                'yasm*', 'ytasm*', 'vsyasm*')

        return {p: sha256_file(p) for p in self.iter_host_binaries()}

    def link_rustlib_tools(self, rust_dir: Path, llvm_dir: Path):
        rustlib_bin = rust_dir / f'lib/rustlib/{self.triple}/bin'
        llvm_bin = llvm_dir / 'bin'
        symlink_rel(llvm_bin / f'lld{self.exe_suffix}', rustlib_bin / f'rust-lld{self.exe_suffix}')
        symlink_rel(llvm_bin / f'llvm-objcopy{self.exe_suffix}', rustlib_bin / f'rust-objcopy{self.exe_suffix}')

    def wire_ndk_toolchains(self, rust_dir: Path, llvm_dir: Path):
        """Unix default: stage libLLVM/libclang shared libs in rust/lib and symlink into llvm/lib."""
        overlay_dir(OUT_DIR / 'llvm/bin', llvm_dir / 'bin')
        for lib in (OUT_DIR / 'llvm/lib').glob(f'*.{self.dyn_ext}*'):
            dst = rust_dir / 'lib' / lib.name
            if not (dst.exists() or dst.is_symlink()):
                if lib.is_symlink():
                    copy_symlink(lib, dst)
                else:
                    copy_file(lib, dst)
        for lib in (rust_dir / 'lib').glob(f'*.{self.dyn_ext}*'):
            symlink_rel(lib, llvm_dir / 'lib' / lib.name)
        self.link_rustlib_tools(rust_dir, llvm_dir)

    def package(self):
        orig_hashes = self.prepare_ndk()

        rust_dir = ONDK_DIR / 'toolchains/rust'
        llvm_dir = ONDK_DIR / f'toolchains/llvm/prebuilt/{self.ndk_dirname}'
        prebuilt_bin = ONDK_DIR / f'prebuilt/{self.ndk_dirname}/bin'
        shader_tools = ONDK_DIR / f'shader-tools/{self.ndk_dirname}'

        copy_tree(OUT_DIR / 'rust', rust_dir)
        for old in rust_dir.rglob('*.old'):
            rm_rf(old)

        self.wire_ndk_toolchains(rust_dir, llvm_dir)

        for target_dir in (llvm_dir / 'bin', prebuilt_bin, shader_tools):
            overlay_dir(OUT_DIR / 'tools/bin', target_dir, ignore_suffix='.dll')

        # Verify every upstream host binary was replaced and no symlinks are broken
        unreplaced = [
            p for p, old_hash in orig_hashes.items()
            if p.exists() and not p.is_symlink() and sha256_file(p) == old_hash
        ]
        dangling: list[Path] = []
        for root, dirs, files in os.walk(ONDK_DIR, followlinks=False):
            for name in (*dirs, *files):
                p = Path(root) / name
                if p.is_symlink() and not p.exists():
                    dangling.append(p)
        if unreplaced or dangling:
            if unreplaced:
                print('Error: Unreplaced host binaries in NDK:', file=sys.stderr)
                for p in unreplaced:
                    print(f'  {p.relative_to(ROOT)}', file=sys.stderr)
            if dangling:
                print('Error: Dangling symlinks in NDK:', file=sys.stderr)
                for p in dangling:
                    print(f'  {p.relative_to(ROOT)}', file=sys.stderr)
            sys.exit(1)

        # Strip all host binaries shipped in the final ONDK tree
        self.strip_binaries()

    def dist(self):
        if not ONDK_DIR.is_dir():
            sys.exit(f"Missing {ONDK_DIR}; run 'package' action first")
        DIST_DIR.mkdir(parents=True, exist_ok=True)
        archive = DIST_DIR / f'{ONDK_DIR.name}-{self.os_name}-{self.arch}.tar.xz'

        xz_cmd = ['xz', '--x86', '--lzma2'] if self.arch == 'x86_64' else ['xz']
        with archive.open('wb') as out_f:
            tar_proc = subprocess.Popen(['tar', '-c', ONDK_DIR.name], cwd=OUT_DIR, stdout=subprocess.PIPE)
            assert tar_proc.stdout is not None
            xz_proc = subprocess.Popen(xz_cmd, stdin=tar_proc.stdout, stdout=out_f)
            tar_proc.stdout.close()
            tar_rc = tar_proc.wait()
            xz_rc = xz_proc.wait()
            if tar_rc != 0 or xz_rc != 0:
                sys.exit(1)


# -----------------------------------------------------------------------------
# Platform Implementations
# -----------------------------------------------------------------------------

class LinuxHost(Host):
    os_name = 'linux'
    ndk_dirname = 'linux-x86_64'
    dyn_ext = 'so'

    def __init__(self, arch: str):
        super().__init__(arch)
        self.triple = f'{arch}-unknown-linux-gnu'
        suffix = os.environ.get('LINUX_HOST_LLVM_SUFFIX', '')
        self.cc = f'clang{suffix}'
        self.cxx = f'clang++{suffix}'

    def is_host_binary(self, path: Path) -> bool:
        if path.is_symlink() or not path.is_file():
            return False
        with path.open('rb') as f:
            hdr = f.read(18)
        if len(hdr) < 18 or hdr[:4] != b'\x7fELF':
            return False
        endian = 'little' if hdr[5] == 1 else 'big'
        return int.from_bytes(hdr[16:18], endian) in (2, 3)  # ET_EXEC, ET_DYN

    def tools_cmake_cfg(self, prefix: Path) -> dict[str, str | Path]:
        cfg = super().tools_cmake_cfg(prefix)
        return cfg | {
            'CMAKE_C_COMPILER': self.cc,
            'CMAKE_CXX_COMPILER': self.cxx,
            'CMAKE_CXX_FLAGS': f"{cfg['CMAKE_CXX_FLAGS']} -stdlib=libc++",
            'CMAKE_EXE_LINKER_FLAGS': '-fuse-ld=lld -static-libstdc++',
            'CMAKE_SHARED_LINKER_FLAGS': '-fuse-ld=lld -static-libstdc++',
        }

    def llvm_cmake_cfg(self, prefix: Path) -> dict[str, str | Path]:
        return super().llvm_cmake_cfg(prefix) | {
            'LLVM_BINUTILS_INCDIR': '/usr/include',
            'CMAKE_C_COMPILER': self.cc,
            'CMAKE_CXX_COMPILER': self.cxx,
            'LLVM_USE_LINKER': 'lld',
            'LLVM_STATIC_LINK_CXX_STDLIB': 'ON',
            'LLVM_ENABLE_LIBCXX': 'ON',
        }

    def rust_bootstrap_cfg(self, env: dict[str, str]) -> dict[str, Any]:
        env['LD_LIBRARY_PATH'] = str(OUT_DIR / 'llvm/lib')
        cfg = super().rust_bootstrap_cfg(env)
        cfg['llvm'] |= {'use-libcxx': True, 'static-libstdcpp': True}
        cfg['rust'] |= {'use-lld': True}
        cfg['target'][self.triple] |= {'cc': self.cc, 'cxx': self.cxx, 'linker': self.cc}
        return cfg


class DarwinHost(Host):
    os_name = 'darwin'
    ndk_dirname = 'darwin-x86_64'
    dyn_ext = 'dylib'
    brew_prefix: str = ''
    xcode_bin: Path

    def __init__(self, arch: str):
        super().__init__(arch)
        self.triple = f'{arch}-apple-darwin'

    def setup_env(self):
        os.environ['CMAKE_APPLE_SILICON_PROCESSOR'] = 'arm64' if self.arch == 'aarch64' else self.arch
        os.environ['MACOSX_DEPLOYMENT_TARGET'] = '11.0'
        os.environ['SDKROOT'] = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()

        self.brew_prefix = subprocess.check_output(['brew', '--prefix'], text=True).strip()
        self.xcode_bin = Path(subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()).parent
        gpatch_bin = f'{self.brew_prefix}/opt/gpatch/libexec/gnubin'

        path_parts = os.environ['PATH'].split(os.pathsep)
        if '/usr/bin' in path_parts:
            path_parts.insert(path_parts.index('/usr/bin'), str(self.xcode_bin))
        os.environ['PATH'] = os.pathsep.join([gpatch_bin, *path_parts])

    def is_host_binary(self, path: Path) -> bool:
        if path.is_symlink() or not path.is_file():
            return False
        with path.open('rb') as f:
            hdr = f.read(24)
            if len(hdr) >= 20 and hdr[:4] == b'\xca\xfe\xba\xbe' and 1 <= int.from_bytes(hdr[4:8], 'big') < 32:
                f.seek(int.from_bytes(hdr[16:20], 'big'))
                hdr = f.read(16)
            elif len(hdr) == 24 and hdr[:4] == b'\xca\xfe\xba\xbf' and 1 <= int.from_bytes(hdr[4:8], 'big') < 32:
                f.seek(int.from_bytes(hdr[16:24], 'big'))
                hdr = f.read(16)
        if len(hdr) < 16:
            return False
        if hdr[:4] in (b'\xfe\xed\xfa\xce', b'\xfe\xed\xfa\xcf'):
            endian = 'big'
        elif hdr[:4] in (b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe'):
            endian = 'little'
        else:
            return False
        return int.from_bytes(hdr[12:16], endian) in (2, 6, 8)  # MH_EXECUTE, MH_DYLIB, MH_BUNDLE

    def strip_cmd(self) -> list[str | Path]:
        return ['strip', '-x']

    def tools_cmake_cfg(self, prefix: Path) -> dict[str, str | Path]:
        return super().tools_cmake_cfg(prefix) | {
            'CMAKE_C_COMPILER': 'clang',
            'CMAKE_CXX_COMPILER': 'clang++',
            'CMAKE_C_COMPILER_TARGET': self.triple,
            'CMAKE_CXX_COMPILER_TARGET': self.triple,
        }

    def llvm_cmake_cfg(self, prefix: Path) -> dict[str, str | Path]:
        return super().llvm_cmake_cfg(prefix) | {
            'LLVM_BINUTILS_INCDIR': f'{self.brew_prefix}/opt/binutils/include',
        }

    def rust_bootstrap_cfg(self, env: dict[str, str]) -> dict[str, Any]:
        # Clang infers --target=<triple> from argv[0] when invoked via <triple>-clang
        shim_dir = BUILD_DIR / 'cc-shims'
        rm_rf(shim_dir)
        shim_dir.mkdir(parents=True, exist_ok=True)
        for tool in ('clang', 'clang++'):
            (shim_dir / f'{self.triple}-{tool}').symlink_to(self.xcode_bin / tool)

        env['PATH'] = f"{shim_dir}{os.pathsep}{env['PATH']}"
        env['LZMA_API_STATIC'] = '1'
        env['DYLD_FALLBACK_LIBRARY_PATH'] = str(OUT_DIR / 'llvm/lib')

        cc = f'{self.triple}-clang'
        cfg = super().rust_bootstrap_cfg(env)
        cfg['target'][self.triple] |= {'jemalloc': True, 'cc': cc, 'cxx': f'{cc}++', 'linker': cc}
        return cfg


class WindowsHost(Host):
    os_name = 'windows'
    ndk_dirname = 'windows-x86_64'
    exe_suffix = '.exe'

    MINGW_SELF_CONTAINED_LIBS = (
        'libm.a', 'libmingw32.a', 'libmingwex.a', 'libiconv.a', 'libmoldname.a', 'libpthread.a',
        'libunwind.a', 'libunwind.dll.a',
        'libadvapi32.a', 'libbcrypt.a', 'libcomctl32.a', 'libcomdlg32.a', 'libcredui.a', 'libcrypt32.a',
        'libdbghelp.a', 'libgdi32.a', 'libimagehlp.a', 'libiphlpapi.a', 'libkernel32.a', 'libmsimg32.a',
        'libmsvcrt.a', 'libntdll.a', 'libodbc32.a', 'libole32.a', 'liboleaut32.a', 'libopengl32.a',
        'libpsapi.a', 'librpcrt4.a', 'libsecur32.a', 'libsetupapi.a', 'libshell32.a', 'libsynchronization.a',
        'libuser32.a', 'libuserenv.a', 'libuuid.a', 'libwinhttp.a', 'libwinmm.a', 'libwinspool.a',
        'libws2_32.a', 'libwsock32.a',
    )

    def __init__(self, arch: str):
        super().__init__(arch)
        self.triple = f'{arch}-pc-windows-gnullvm'
        self.mingw_prefix = Path(os.environ.get('MINGW_PREFIX') or sys.prefix)

    def setup_env(self):
        os.environ['MSYS'] = 'winsymlinks:nativestrict'
        os.environ['__COMPAT_LAYER'] = 'RunAsInvoker'
        os.environ['PATH'] = f"{os.environ['PATH']}{os.pathsep}C:\\Program Files\\Git\\cmd"

    def is_host_binary(self, path: Path) -> bool:
        if path.is_symlink() or not path.is_file():
            return False
        with path.open('rb') as f:
            hdr = f.read(64)
            if len(hdr) < 64 or hdr[:2] != b'MZ':
                return False
            f.seek(int.from_bytes(hdr[0x3c:0x40], 'little'))
            pe = f.read(6)
        return len(pe) == 6 and pe[:4] == b'PE\x00\x00' and int.from_bytes(pe[4:6], 'little') == 0x20b

    def extra_ndk_repos(self) -> list[str]:
        return ['platform/ndk']

    def tools_cmake_cfg(self, prefix: Path) -> dict[str, str | Path]:
        cfg = super().tools_cmake_cfg(prefix)
        return cfg | {
            'CMAKE_C_COMPILER': 'clang',
            'CMAKE_CXX_COMPILER': 'clang++',
            'CMAKE_CXX_FLAGS': f"{cfg['CMAKE_CXX_FLAGS']} -include type_traits",
            'CMAKE_EXE_LINKER_FLAGS': '-static',
            'CMAKE_SHARED_LINKER_FLAGS': '-static',
        }

    def build_tools(self):
        super().build_tools()
        bin_dir = OUT_DIR / 'tools/bin'
        bin_dir.mkdir(parents=True, exist_ok=True)
        toolbox_src = SRC_DIR / 'ndk/sources/host-tools/toolbox'
        for tool in ('echo', 'cmp'):
            run(['clang', '-Os', '-fomit-frame-pointer', '-static',
                 '-o', bin_dir / f'{tool}.exe', toolbox_src / f'{tool}_win.c'])

    def llvm_cmake_cfg(self, prefix: Path) -> dict[str, str | Path]:
        cfg = super().llvm_cmake_cfg(prefix)
        win_gnu_triple = f'{self.arch}-pc-windows-gnu'
        return cfg | {
            'CMAKE_C_COMPILER': 'clang',
            'CMAKE_CXX_COMPILER': 'clang++',
            'LLVM_USE_LINKER': 'lld',
            'LLVM_ENABLE_LIBCXX': 'ON',
            'LLVM_ENABLE_PLUGINS': 'OFF',
            'LLVM_USE_SYMLINKS': 'ON',
            'LLVM_ENABLE_PROJECTS': 'clang;lld;clang-tools-extra;polly',
            'LLVM_HOST_TRIPLE': win_gnu_triple,
            'LLVM_DEFAULT_TARGET_TRIPLE': win_gnu_triple,
            'CLANG_DEFAULT_RTLIB': 'compiler-rt',
            'CLANG_DEFAULT_UNWINDLIB': 'libunwind',
            'CLANG_DEFAULT_CXX_STDLIB': 'libc++',
        }

    def build_llvm(self):
        super().build_llvm()
        llvm_out = OUT_DIR / 'llvm'

        # Build libclang_rt.builtins-${ARCH}.a for self-contained host linking
        clang_res_dir = next((llvm_out / 'lib/clang').glob('*'))
        self.cmake_install(
            SRC_DIR / 'llvm-project/compiler-rt/lib/builtins',
            BUILD_DIR / 'builtins',
            {
                'CMAKE_BUILD_TYPE': 'Release',
                'CMAKE_INSTALL_PREFIX': clang_res_dir,
                'CMAKE_C_COMPILER': 'clang',
                'CMAKE_CXX_COMPILER': 'clang++',
                'LLVM_CMAKE_DIR': llvm_out / 'lib/cmake/llvm',
            },
        )

    def rust_bootstrap_cfg(self, env: dict[str, str]) -> dict[str, Any]:
        # Prevent cc-rs from inheriting -flto=thin from rustc flags
        env['CFLAGS'] = '-fno-lto'
        env['CXXFLAGS'] = '-fno-lto'

        dlls_dir = BUILD_DIR / 'llvm-dlls'
        rm_rf(dlls_dir)
        dlls_dir.mkdir(parents=True)
        for dll in (OUT_DIR / 'llvm/bin').glob('*.dll'):
            symlink_rel(dll, dlls_dir / dll.name)
        env['PATH'] = f"{dlls_dir}{os.pathsep}{env['PATH']}"

        cfg = super().rust_bootstrap_cfg(env)
        cfg['llvm'] |= {'use-libcxx': True}
        cfg['rust'] |= {'use-lld': True}
        cfg['target'][self.triple] |= {'cc': 'clang', 'cxx': 'clang++', 'linker': 'clang'}
        return cfg

    def bundle_mingw_dlls(self, entry_exe: Path, dest_dir: Path):
        """Statically walk PE import tables via llvm-objdump and copy MinGW runtime DLLs."""
        objdump = OUT_DIR / 'llvm/bin/llvm-objdump.exe'
        mingw_dlls = {p.name.lower(): p for p in (self.mingw_prefix / 'bin').glob('*.dll')}
        local_map = {p.name.lower(): p for p in dest_dir.glob('*.dll')}
        visited: set[Path] = set()
        queue = deque([entry_exe])

        while queue:
            binary = queue.popleft().resolve()
            if binary in visited or not binary.is_file():
                continue
            visited.add(binary)

            out = subprocess.check_output([str(objdump), '--private-headers', str(binary)], text=True)
            for match in re.finditer(r'^\s*DLL(?: Name)?:\s*(\S+)', out, re.MULTILINE):
                dll_lower = match.group(1).lower()
                # Check dest_dir's own DLLs first so MSYS2 host LLVM/Clang DLLs
                # (e.g. libclang-cpp.dll in MINGW_PREFIX/bin) never shadow our built DLLs.
                if dll_lower in local_map:
                    queue.append(local_map[dll_lower])
                elif dll_lower in mingw_dlls:
                    src_dll = mingw_dlls[dll_lower]
                    dst_dll = dest_dir / src_dll.name
                    copy_file(src_dll, dst_dll)
                    local_map[dll_lower] = dst_dll
                    queue.append(src_dll)

    def wire_ndk_toolchains(self, rust_dir: Path, llvm_dir: Path):
        llvm_bin = llvm_dir / 'bin'
        rust_bin = rust_dir / 'bin'
        rustlib_bin = rust_dir / f'lib/rustlib/{self.triple}/bin'

        # 1. Install Clang/LLVM binaries and runtime DLLs into llvm/bin
        for name in ('lld.exe', 'lld-link.exe', 'ld64.lld.exe'):
            (llvm_bin / name).touch()
        overlay_dir(OUT_DIR / 'llvm/bin', llvm_bin, ignore_suffix='.dll')
        symlink_rel(llvm_bin / 'lld.exe', llvm_bin / 'ld.exe')
        for dll in (OUT_DIR / 'llvm/bin').glob('*.dll'):
            copy_file(dll, llvm_bin / dll.name)
        self.link_rustlib_tools(rust_dir, llvm_dir)

        # 2. Bundle MinGW runtime DLLs and deduplicate shared DLLs via symlinks
        self.bundle_mingw_dlls(llvm_bin / 'clang.exe', llvm_bin)
        for pat in ('libLLVM*.dll', 'libclang-cpp.dll'):
            for dll in llvm_bin.glob(pat):
                symlink_rel(dll, rust_bin / dll.name)
        for dll in llvm_bin.glob('libLLVM*.dll'):
            symlink_rel(dll, rustlib_bin / dll.name)

        self.bundle_mingw_dlls(rust_bin / 'rustc.exe', rust_bin)
        self.bundle_mingw_dlls(rustlib_bin / 'rust-lld.exe', rustlib_bin)
        for d in (rust_bin, rustlib_bin):
            for dll in d.glob('*.dll'):
                shared = llvm_bin / dll.name
                if not dll.is_symlink() and shared.is_file():
                    symlink_rel(shared, dll)

        # 3. Stage Rust std DLLs, MinGW self-contained static libs, and compiler-rt builtins
        rustlib_dir = rust_dir / f'lib/rustlib/{self.triple}/lib'
        for std_dll in rust_bin.glob('std-*.dll'):
            symlink_rel(std_dll, rustlib_dir / std_dll.name)

        mingw_lib = self.mingw_prefix / 'lib'
        self_contained = rustlib_dir / 'self-contained'
        for lib in self.MINGW_SELF_CONTAINED_LIBS:
            copy_file(mingw_lib / lib, self_contained / lib)

        win_builtins = next((OUT_DIR / 'llvm/lib/clang').glob('*/lib/windows'))
        clang_lib_dir = next((llvm_dir / 'lib/clang').glob('*/lib'))
        copy_tree(win_builtins, clang_lib_dir / 'windows')

        # 4. Expose clang and llvm-ar as rustc's self-contained host linker and dlltool
        symlink_rel(llvm_bin / 'clang.exe', rust_bin / f'{self.arch}-w64-mingw32-clang.exe')
        symlink_rel(llvm_bin / 'llvm-ar.exe', rust_bin / 'dlltool.exe')


def create_host() -> Host:
    msystem = os.environ.get('MSYSTEM', '')
    if sys.platform == 'win32' or msystem:
        if not re.match(r'^CLANG(ARM)?64$', msystem):
            sys.exit('This script should run on MSYS2 CLANG64 or CLANGARM64')
        return WindowsHost('aarch64' if msystem == 'CLANGARM64' else 'x86_64')

    raw_arch = platform.machine().lower()
    native_arch = {'arm64': 'aarch64', 'amd64': 'x86_64'}.get(raw_arch, raw_arch)
    arch = os.environ.get('ARCH') or native_arch

    if sys.platform == 'darwin':
        return DarwinHost(arch)
    return LinuxHost(arch)


# -----------------------------------------------------------------------------
# CLI Entrypoint
# -----------------------------------------------------------------------------

def main():
    host = create_host()
    actions: dict[str, Callable[[], object]] = {
        'clone':      lambda: (host.clone_ndk(), host.clone_rust()),
        'clone-ndk':  host.clone_ndk,
        'clone-rust': host.clone_rust,
        'build':      lambda: (host.build_ndk(), host.build_rust()),
        'build-ndk':  host.build_ndk,
        'build-rust': host.build_rust,
        'package':    host.package,
        'dist':       lambda: (rm_rf(DIST_DIR), host.dist()),
        'clean':      lambda: (rm_rf(SRC_DIR, BUILD_DIR, OUT_DIR, DIST_DIR), rm_glob(ROOT, 'android-ndk-*.zip*')),
    }

    parser = argparse.ArgumentParser(description='Build and package Oxidized NDK (ONDK)')
    parser.add_argument('actions', nargs='*', default=['clone', 'build', 'package', 'dist'],
                        choices=list(actions), metavar='ACTION',
                        help=f"Actions to run ({', '.join(actions)})")
    args = parser.parse_args()

    host.setup_env()
    for action in args.actions:
        actions[action]()


if __name__ == '__main__':
    main()
