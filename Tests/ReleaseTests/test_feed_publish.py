import os, sys
from unittest.mock import patch
import json,runpy,subprocess,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parents[2]/'scripts'))
SCRIPT=Path(__file__).parents[2]/'scripts/publish-feed.py'
class FeedPublicationTests(unittest.TestCase):
    def run_feed(self,previous=None,missing=False,api_error=False):
        calls=[]
        def run(args,**kwargs):
            path=args[2]; payload=json.loads(kwargs['input']) if kwargs.get('input') else None
            calls.append((path,payload,args))
            if path.endswith('git/ref/heads/updates'):
                if api_error: return subprocess.CompletedProcess(args,1,'','HTTP 403')
                if missing: return subprocess.CompletedProcess(args,1,'','HTTP 404')
                result={'object':{'sha':'old'}}
            elif path.endswith('git/commits/old'): result={'tree':{'sha':'old-tree'}}
            elif 'contents/release.json' in path:
                import base64
                result={'content':base64.b64encode(json.dumps(previous).encode()).decode()}
            else: result={'sha':'new'}
            return subprocess.CompletedProcess(args,0,json.dumps(result),'')
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'appcast.xml').write_text('signed bytes')
            (root/'release.json').write_text(json.dumps(dict(tag='v0.3.0-preview.4',build=4,mode='preview')))
            with patch.dict(os.environ, CUTLINE_RELEASE_REPOSITORY='example-org/example-editor'), patch('sys.argv',[str(SCRIPT),str(root),'source-commit']),patch('subprocess.run',side_effect=run):
                try: runpy.run_path(str(SCRIPT),run_name='__main__')
                except SystemExit as e:
                    if e.code not in (0,None): raise
        return calls
    def test_first_publish_creates_nonempty_tree_then_branch(self):
        calls=self.run_feed(missing=True)
        tree=next(p for path,p,_ in calls if path.endswith('git/trees'))
        self.assertEqual({x['path'] for x in tree['tree']},{'appcast.xml','release.json'})
        self.assertNotIn('base_tree',tree)
        self.assertTrue(calls[-1][0].endswith('git/refs'))
    def test_existing_feed_uses_nonforce_update(self):
        calls=self.run_feed(previous=dict(tag='v0.2.0-preview.3',build=3,mode='preview'))
        self.assertEqual(calls[-1][1],dict(sha='new',force=False))
        self.assertIn('PATCH',calls[-1][2])
    def test_older_build_cannot_replace_newer_feed(self):
        with self.assertRaises(AssertionError): self.run_feed(previous=dict(tag='v0.4.0',build=5,mode='signed'))
    def test_preview_cannot_replace_signed_feed(self):
        with self.assertRaises(AssertionError): self.run_feed(previous=dict(tag='v0.2.0',build=3,mode='signed'))
    def test_permission_failure_does_not_initialize_new_branch(self):
        with self.assertRaises(RuntimeError): self.run_feed(api_error=True)
    def test_retry_of_same_release_is_noop(self):
        calls=self.run_feed(previous=dict(tag='v0.3.0-preview.4',build=4,mode='preview'))
        self.assertTrue(all(payload is None for _,payload,_ in calls))
