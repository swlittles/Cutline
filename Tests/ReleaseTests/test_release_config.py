import os, sys, unittest, subprocess
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parents[2]/'scripts'))
from release_config import release_repository

class ReleaseConfigurationTests(unittest.TestCase):
    def test_explicit_repository_precedes_runner_default(self):
        with patch.dict(os.environ, {'CUTLINE_RELEASE_REPOSITORY':'example-org/editor','GITHUB_REPOSITORY':'other-org/editor'}, clear=True):
            self.assertEqual(release_repository(), 'example-org/editor')
    def test_github_runner_repository(self):
        with patch.dict(os.environ, {'GITHUB_REPOSITORY':'example-org/editor'}, clear=True):
            self.assertEqual(release_repository(), 'example-org/editor')
    def test_origin_discovery_and_rejects_non_github_remote(self):
        for remote,expected in [('https://github.com/example-org/editor.git','example-org/editor'), ('git@github.com:example-org/editor.git','example-org/editor'), ('https://example.test/editor.git',None)]:
            with patch.dict(os.environ, {}, clear=True), patch('subprocess.run', return_value=subprocess.CompletedProcess([],0,remote,'')):
                if expected:self.assertEqual(release_repository(), expected)
                else:
                    with self.assertRaises(ValueError):release_repository()
    def test_bad_repository_is_rejected(self):
        for value in ['../repo', 'owner/repo/path', 'https://github.com/owner/repo', 'owner/repo\n', 'owner/$(env)']:
            with patch.dict(os.environ, {'CUTLINE_RELEASE_REPOSITORY':value}, clear=True):
                with self.assertRaises(ValueError):release_repository()
