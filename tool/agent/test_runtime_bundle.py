import json,tempfile,unittest
from pathlib import Path
from prepare_runtime import extract,TARGETS,RELEASES
from package_runtime import verify
import tarfile,io,hashlib

class RuntimeBundles(unittest.TestCase):
 def test_all_assets_are_pinned_and_versioned(self):
  self.assertEqual(RELEASES['opencode']['version'],'v1.18.33')
  self.assertEqual(RELEASES['codex']['version'],'rust-v0.159.0')
  for op,co in TARGETS.values():
   for runtime,asset in [('opencode',op),('codex',co)]:
    self.assertRegex(RELEASES[runtime]['assets'][asset]['sha256'],r'^[a-f0-9]{64}$')
 def test_unsafe_archives_are_rejected(self):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);archive=root/'bad.tar.gz'
   with tarfile.open(archive,'w:gz') as t:
    info=tarfile.TarInfo('../escape');info.size=1;t.addfile(info,io.BytesIO(b'x'))
   with self.assertRaises(ValueError):extract(archive,root/'out')
   self.assertFalse((root/'escape').exists())
 def test_modified_packaged_file_fails_verification(self):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);(root/'licenses').mkdir();(root/'licenses/test.txt').write_text('license')
   (root/'opencode').write_bytes(b'pinned')
   manifest={'opencode':'1.18.33','codex':'0.159.0','files':{name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in ['opencode','licenses/test.txt']}}
   (root/'runtime-manifest.json').write_text(json.dumps(manifest))
   verify(root);(root/'opencode').write_bytes(b'changed')
   with self.assertRaises(AssertionError):verify(root)
if __name__=='__main__':unittest.main()
