#!/usr/bin/env python3
"""Stage an already downloaded official Cubism SDK and an existing model locally."""
import argparse
import json
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--sdk', required=True, type=Path, help='Extracted CubismSdkForNative-5-r.5 directory')
p.add_argument('--model', required=True, type=Path, help='Existing .model3.json file')
a = p.parse_args()
if not (a.sdk / 'Core/include/Live2DCubismCore.h').is_file():
    p.error('The selected directory is not a Cubism Native SDK.')
manifest = json.loads(a.model.read_text())
refs = manifest['FileReferences']
source = a.model.resolve().parent
out = root / 'assets/live2d'
out.mkdir(parents=True, exist_ok=True)

def copy_asset(relative, destination):
    src = (source / relative).resolve()
    if not src.is_relative_to(source) or not src.is_file():
        raise ValueError(f'Invalid model reference: {relative}')
    target = out / destination
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, target)
    return destination

refs['Moc'] = copy_asset(refs['Moc'], 'character.moc3')
refs['Textures'] = [copy_asset(f, f'textures/texture_{i}{Path(f).suffix}') for i, f in enumerate(refs['Textures'])]
if refs.get('Physics'):
    refs['Physics'] = copy_asset(refs['Physics'], 'character.physics3.json')
for i, expression in enumerate(refs.get('Expressions', [])):
    expression['File'] = copy_asset(expression['File'], f'expression_{i}.exp3.json')
# Motion playback is not part of this prototype; do not leave dangling references.
for key in ['Motions', 'Pose', 'UserData', 'DisplayInfo']:
    refs.pop(key, None)
(out / 'character.model3.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
vendor = root / 'packages/tsukuyomi_live2d/vendor/cubism'
for component in ['Core', 'Framework']:
    shutil.copytree(a.sdk / component, vendor / component, dirs_exist_ok=True, copy_function=shutil.copyfile)
print('Staged local Cubism SDK and model. These files are ignored by Git.')
print('Run flutter clean after changing SDK availability, then flutter pub get.')
