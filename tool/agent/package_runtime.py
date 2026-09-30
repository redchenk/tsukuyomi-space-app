#!/usr/bin/env python3
"""Copy verified runtimes into a native bundle, preserving macOS JIT signing."""
import argparse,json,os,shutil,subprocess
from pathlib import Path
from prepare_runtime import ROOT,TARGETS,digest

def verify(directory):
    manifest=json.loads((directory/'runtime-manifest.json').read_text())
    assert manifest['opencode']=='1.18.33' and manifest['codex']=='0.159.0'
    assert any(name.startswith('licenses/') for name in manifest['files'])
    for name,checksum in manifest['files'].items():
        file=(directory/name).resolve()
        assert file.is_relative_to(directory.resolve()) and digest(file)==checksum, name
    return manifest

def package(platform,bundle):
    destination=bundle/'Contents/Resources/agent' if platform=='macos' else bundle/'agent'
    destination.mkdir(parents=True,exist_ok=True)
    for target in TARGETS:
        if not target.startswith(platform): continue
        source=ROOT/'build/agent-runtime'/target
        manifest=verify(source)
        dest=destination/target
        if dest.exists():shutil.rmtree(dest)
        shutil.copytree(source,dest)
        if platform=='macos':
            for file in dest.rglob('*'):
                if not file.is_file():continue
                description=subprocess.check_output(['file','-b',str(file)],text=True)
                if 'Mach-O' not in description:continue
                args=['codesign','--force','--sign','-']
                if file.name=='opencode':args+=['--options','runtime','--entitlements',str(ROOT/'tool/agent/runtime.entitlements')]
                subprocess.run(args+[str(file)],check=True)
            manifest['files']={str(p.relative_to(dest)):digest(p) for p in sorted(dest.rglob('*')) if p.is_file() and p.name!='runtime-manifest.json'}
            (dest/'runtime-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        verify(dest)
        print('Packaged and verified:',target)
    if platform=='macos':
        subprocess.run(['codesign','--force','--sign','-','--entitlements',str(ROOT/'macos/Runner/Release.entitlements'),str(bundle)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(bundle)],check=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--platform',choices=['macos','windows','linux'],required=True);p.add_argument('--bundle',type=Path,required=True)
    args=p.parse_args();package(args.platform,args.bundle)
