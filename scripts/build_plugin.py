#!/usr/bin/env python3
"""将仓库中的 Skill 打包为官方目录可上传的桌面插件，不修改目标业务项目。"""

import argparse
import hashlib
import json
import re
import shutil
import tempfile
import zipfile
from pathlib import Path


def build_plugin(output_dir):
    """复制发布所需文件、检查清单路径，并生成插件 ZIP 与 SHA-256 校验文件。"""
    root = Path(__file__).resolve().parent.parent
    manifest = json.loads((root / "packaging/plugin.json").read_text())
    name, version = manifest["name"], manifest["version"]
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
        raise ValueError("Invalid plugin name")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Invalid plugin version")
    interface = manifest["extensions"]["com.openai"]["interface"]
    for field, limit in {"displayName": 30, "shortDescription": 30, "longDescription": 4000, "developerName": 80}.items():
        if not isinstance(interface[field], str) or not 0 < len(interface[field]) <= limit:
            raise ValueError(f"Invalid {field}")
    manager_source = (root / "scripts/workflow_manager.rb").read_text()
    if f'VERSION = "{version}"' not in manager_source:
        raise ValueError("Plugin and manager versions must match")
    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"{name}-{version}-plugin.zip"
    with tempfile.TemporaryDirectory(prefix="ai-workflow-plugin-") as temporary:
        package = Path(temporary)
        skill = package / "skills" / name
        skill.mkdir(parents=True)
        for directory in ("agents", "references", "assets"):
            shutil.copytree(root / directory, skill / directory, ignore=shutil.ignore_patterns(".DS_Store", "__pycache__"))
        (skill / "scripts").mkdir()
        for filename in ("workflow_manager.rb", "workflow_manager_test.rb"):
            shutil.copy2(root / "scripts" / filename, skill / "scripts" / filename)
        for filename in ("SKILL.md", "LICENSE"):
            shutil.copy2(root / filename, skill / filename)
        for filename in ("LICENSE", "README.md"):
            shutil.copy2(root / filename, package / filename)
        (package / "assets").mkdir()
        shutil.copy2(root / "packaging/icon.svg", package / "assets/icon.svg")
        (package / "plugin.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        for field in ("logo", "composerIcon"):
            relative = interface[field]
            if not relative.startswith("./") or ".." in Path(relative).parts or not (package / relative).is_file():
                raise ValueError(f"Invalid asset path: {relative}")
        # 项目 Hook 仅作为 Skill 内的安装模板，不能在插件根目录注册生命周期 Hook。
        if "hooks" in manifest["extensions"]["com.openai"] or (package / "hooks").exists():
            raise ValueError("Public package must not register plugin lifecycle hooks")
        files = sorted(path for path in package.rglob("*") if path.is_file())
        if any(path.is_symlink() for path in package.rglob("*")):
            raise ValueError("Release package must not contain symlinks")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for path in files:
                bundle.write(path, path.relative_to(package))
        with zipfile.ZipFile(archive) as bundle:
            if bundle.testzip() is not None:
                raise ValueError("ZIP integrity check failed")
            for path in files:
                if bundle.read(str(path.relative_to(package))) != path.read_bytes():
                    raise ValueError("Packaged content differs from source")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n")
    print(json.dumps({"archive": str(archive), "sha256": digest, "files": len(files)}, ensure_ascii=False))


def main():
    """读取发布目录参数，默认将压缩包放在源码仓库之外，避免复制或提交生成包。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] / "releases")
    build_plugin(parser.parse_args().output.resolve())


if __name__ == "__main__":
    main()
