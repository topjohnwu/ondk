#!/usr/bin/env python3
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

import ast
import base64
import json
from pathlib import Path
import shutil
import subprocess
import sys
import types
import urllib.request
import xml.etree.ElementTree as ET

AOSP_URL = 'https://android.googlesource.com'
SRC_DIR = Path('src')


def fetch_bytes(url: str) -> bytes:
    with urllib.request.urlopen(url) as resp:
        return resp.read()


def gitiles_text(path: str) -> str:
    data = fetch_bytes(f'{AOSP_URL}/{path}?format=TEXT')
    return base64.b64decode(data).decode('utf-8')


def gitiles_json(path: str) -> dict:
    data = fetch_bytes(f'{AOSP_URL}/{path}?format=JSON').decode('utf-8')
    # Strip the Gitiles XSSI prefix ")]}'\n"
    return json.loads(data.split('\n', 1)[1])


def extract_var(py_src: str, name: str) -> str:
    tree = ast.parse(py_src)
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return ast.literal_eval(node.value)
    raise KeyError(f'{name} not found')


def clone_bundle(repo: str, ref: str, dest: str | None = None):
    url = f'{AOSP_URL}/{repo}'
    dir_name = dest or repo.rsplit('/', 1)[-1]
    target_dir = SRC_DIR / dir_name
    print(f"Cloning into '{target_dir}'...", flush=True)
    if target_dir.exists():
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)

    subprocess.run(['git', 'init', '-q'], cwd=target_dir, check=True)
    subprocess.run(['git', 'remote', 'add', 'origin', url], cwd=target_dir, check=True)

    bundle_path = target_dir / 'clone.bundle'
    res = subprocess.run(
        ['curl', '-fL', f'{url}/clone.bundle', '-o', 'clone.bundle'],
        cwd=target_dir,
    )
    if res.returncode == 0:
        subprocess.run(
            ['git', 'fetch', '-q', '-u', 'clone.bundle', '+refs/*:refs/*'],
            cwd=target_dir,
            check=True,
        )
        bundle_path.unlink()
        if subprocess.run(['git', 'reset', '--hard', ref], cwd=target_dir).returncode == 0:
            return

    bundle_path.unlink(missing_ok=True)
    subprocess.run(['git', 'fetch', '--depth', '1', 'origin', ref], cwd=target_dir, check=True)
    subprocess.run(['git', 'reset', '--hard', 'FETCH_HEAD'], cwd=target_dir, check=True)


def clone_sha(url: str, sha: str, dest: str | None = None):
    dir_name = dest or url.rsplit('/', 1)[-1]
    target_dir = SRC_DIR / dir_name
    print(f"Cloning into '{target_dir}'...", flush=True)
    if target_dir.exists():
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)

    subprocess.run(['git', 'init', '-q'], cwd=target_dir, check=True)
    subprocess.run(['git', 'remote', 'add', 'origin', url], cwd=target_dir, check=True)
    subprocess.run(['git', 'fetch', '--depth', '1', 'origin', sha], cwd=target_dir, check=True)
    subprocess.run(['git', 'reset', '--hard', 'FETCH_HEAD'], cwd=target_dir, check=True)


def clone_llvm(ndk_tag: str):
    # 1. Resolve CLANG_VERSION from platform/ndk/ndk/toolchains.py
    toolchains_py = gitiles_text(f'platform/ndk/+/refs/tags/{ndk_tag}/ndk/toolchains.py')
    clang_ver = extract_var(toolchains_py, 'CLANG_VERSION')

    # 2. Find manifest_*.xml in platform/prebuilts/clang/host/linux-x86
    prebuilt_path = f'platform/prebuilts/clang/host/linux-x86/+/refs/tags/{ndk_tag}/{clang_ver}'
    entries = gitiles_json(f'{prebuilt_path}/')['entries']
    manifest_name = next(
        e['name'] for e in entries
        if e['name'].startswith('manifest_') and e['name'].endswith('.xml')
    )

    # 3. Parse manifest XML and clone AOSP LLVM repos
    manifest_xml = gitiles_text(f'{prebuilt_path}/{manifest_name}')
    root = ET.fromstring(manifest_xml)
    revs = {p.attrib['name']: p.attrib['revision'] for p in root.findall('project')}

    for repo in (
        'toolchain/llvm_android',
        'platform/external/toolchain-utils',
        'platform/external/zstd',
    ):
        clone_bundle(repo, revs[repo])

    # 4. Read android_version.py and shallow-clone llvm-project from GitHub
    sys.path.insert(0, str(SRC_DIR / 'llvm_android' / 'src'))
    from llvm_android import android_version

    clone_sha('https://github.com/llvm/llvm-project', android_version.get_git_sha())

    # 5. Apply Android LLVM patches via patch_manager
    sys.modules.setdefault('fcntl', types.ModuleType('fcntl'))
    sys.path.insert(0, str(SRC_DIR / 'toolchain-utils'))
    from llvm_tools import patch_manager

    patch_manager.main([
        '--svn_version', android_version.get_svn_revision_number(),
        '--patch_metadata_file', str(SRC_DIR / 'llvm_android' / 'patches' / 'PATCHES.json'),
        '--src_path', str(SRC_DIR / 'llvm-project'),
    ])


def clone_tools(ndk_tag: str, os_name: str):
    clone_bundle('platform/external/shaderc/shaderc', ndk_tag)
    clone_bundle('platform/external/shaderc/glslang', ndk_tag, 'shaderc/third_party/glslang')
    clone_bundle('platform/external/shaderc/spirv-headers', ndk_tag, 'shaderc/third_party/spirv-headers')
    clone_bundle('platform/external/shaderc/spirv-tools', ndk_tag, 'shaderc/third_party/spirv-tools')
    clone_bundle('toolchain/make', ndk_tag)
    clone_bundle('toolchain/yasm', ndk_tag)
    if os_name == 'windows':
        clone_bundle('platform/ndk', ndk_tag)


def main():
    cmd = sys.argv[1]
    ndk_tag = f'ndk-{sys.argv[2]}'
    if cmd == 'llvm':
        clone_llvm(ndk_tag)
    elif cmd == 'tools':
        clone_tools(ndk_tag, sys.argv[3])
    else:
        raise ValueError(f'Unknown command: {cmd}')


if __name__ == '__main__':
    main()
