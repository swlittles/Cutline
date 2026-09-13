import os, sys
from unittest.mock import patch
import importlib.util, tempfile, unittest, json, hashlib
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parents[2]/'scripts'))
spec=importlib.util.spec_from_file_location('validation',Path(__file__).parents[2]/'scripts/validate-release.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
class ReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, CUTLINE_RELEASE_REPOSITORY="example-org/example-editor"); env.start(); self.addCleanup(env.stop)
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup); self.root=Path(self.tmp.name)
        self.meta=dict(version='0.3.0',build=4,mode='preview',tag='v0.3.0-preview.4',name='Cutline-0.3.0-preview.4-macos-universal')
        self.write()
    def write(self):
        r=self.root; m=self.meta; name=m['name']
        (r/'release.json').write_text(json.dumps(m))
        for ext in ['zip','dmg']: (r/f'{name}.{ext}').write_bytes(b'fixture')
        (r/'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(b"fixture").hexdigest()}  {name}.{ext}\n' for ext in ['zip','dmg']))
        (r/'appcast.xml').write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>4</sparkle:version><sparkle:shortVersionString>0.3.0</sparkle:shortVersionString><enclosure url="https://github.com/example-org/example-editor/releases/download/{m['tag']}/{name}.zip" length="7" sparkle:edSignature="fixture"/></item></channel></rss>''')
    def change_feed(self,a,b):
        p=self.root/'appcast.xml'; p.write_text(p.read_text().replace(a,b))
    def test_valid_manifest(self): self.assertEqual(module.validate(self.root)['build'],4)
    def test_corrupted_archive(self):
        (self.root/(self.meta['name']+'.zip')).write_bytes(b'corrupt')
        with self.assertRaises(AssertionError): module.validate(self.root)
    def test_external_download_rejected(self):
        self.change_feed('https://github.com/example-org','https://example.com/example-org')
        with self.assertRaises(AssertionError): module.validate(self.root)
    def test_wrong_build_rejected(self):
        self.change_feed('<sparkle:version>4','<sparkle:version>3')
        with self.assertRaises(AssertionError): module.validate(self.root)
    def test_missing_signature_rejected(self):
        self.change_feed('sparkle:edSignature="fixture"','sparkle:edSignature=""')
        with self.assertRaises(AssertionError): module.validate(self.root)
    def test_unexpected_checksum_path_rejected(self):
        p=self.root/'SHA256SUMS.txt'; p.write_text(p.read_text()+'abc  ../../source.mov\n')
        with self.assertRaises(AssertionError): module.validate(self.root)
    def test_wrong_release_mode_rejected(self):
        self.meta['mode']='signed'; self.write()
        with self.assertRaises(AssertionError): module.validate(self.root)
    def test_wrong_size_rejected(self):
        self.change_feed('length="7"','length="9"')
        with self.assertRaises(AssertionError): module.validate(self.root)
if __name__=='__main__': unittest.main()
