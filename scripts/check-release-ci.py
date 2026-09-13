#!/usr/bin/env python3
from release_config import release_repository
import json,subprocess,sys
sha=sys.argv[1]
r=subprocess.run(['gh','api',f'repos/{release_repository()}/actions/workflows/tests.yml/runs?head_sha={sha}&branch=main&event=push&per_page=100'],check=True,capture_output=True,text=True)
runs=json.loads(r.stdout)['workflow_runs']
assert runs, 'No main push CI run found for this exact commit'
latest=max(runs,key=lambda r:(r['run_number'],r.get('run_attempt',1)))
assert latest['head_sha']==sha and latest['conclusion']=='success', 'Latest CI attempt for this commit must pass before publishing'
print('Verified successful main CI for',sha)
