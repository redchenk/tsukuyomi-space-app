#!/usr/bin/env python3
"""Check that every native site asset survives Flutter release packaging."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def expected_assets(root=ROOT):
    result = {}
    for directory in ("images", "game"):
        source = root / "assets" / directory
        if not source.is_dir():
            raise ValueError(f"Missing {source}")
        for path in source.rglob("*"):
            if path.is_file() and not any(part.startswith(".") for part in path.relative_to(source).parts):
                result[path.relative_to(root).as_posix()] = path
    project = json.loads((root / "assets/game/project.json").read_text())
    game_refs = {item.get("file", item.get("md5ext"))
                 for target in project["targets"]
                 for category in ("costumes", "sounds")
                 for item in target.get(category, [])}
    game_refs.update(font["md5ext"] for font in project.get("customFonts", []) if not font.get("system"))
    for name in game_refs:
        if not name or f"assets/game/{name}" not in result:
            raise ValueError(f"Game references missing asset: {name}")
    manifest_path = root / "assets/live2d/character.model3.json"
    refs = json.loads(manifest_path.read_text())["FileReferences"]
    models = ["character.model3.json", refs["Moc"], *refs["Textures"]]
    models += [refs[key] for key in ("Physics", "Pose") if key in refs]
    models += [item["File"] for item in refs.get("Expressions", [])]
    for name in models:
        path = root / "assets/live2d" / name
        if not path.is_file() or not path.resolve().is_relative_to((root / "assets/live2d").resolve()):
            raise ValueError(f"Model references missing or unsafe asset: {name}")
        result[path.relative_to(root).as_posix()] = path
    return result


def verify(target, root=ROOT):
    expected = expected_assets(root)
    archive = None
    if target.is_dir():
        def read(name):
            return (target / name).read_bytes()
    else:
        archive = zipfile.ZipFile(target)
        prefix = ("assets/flutter_assets/" if target.suffix == ".apk" else
                  "Payload/Runner.app/Frameworks/App.framework/flutter_assets/")

        def read(name):
            return archive.read(prefix + name)
    try:
        for name, source in expected.items():
            data = read(name)
            if hashlib.sha256(data).digest() != hashlib.sha256(source.read_bytes()).digest():
                raise ValueError(f"Missing or changed packaged asset: {name}")
        if not read("assets/shaders/kaguya_effect.frag"):
            raise ValueError("Native game shader is missing")
    finally:
        if archive:
            archive.close()
    print(f"PASS {target}: {len(expected)} exact site/game/model assets and compiled game shader")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path, help="flutter_assets directory, APK, or unsigned IPA")
    args = parser.parse_args()
    verify(args.target)
