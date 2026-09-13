"""Build-time publication settings; never infer a creator identity in the application."""
import os, re, subprocess

def release_repository():
    value = os.environ.get('CUTLINE_RELEASE_REPOSITORY') or os.environ.get('GITHUB_REPOSITORY')
    if not value:
        result = subprocess.run(['git', 'remote', 'get-url', 'origin'], capture_output=True, text=True, check=True)
        remote = result.stdout.strip()
        match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?', remote)
        if not match:
            raise ValueError('Set CUTLINE_RELEASE_REPOSITORY to the GitHub owner/repository for this build.')
        value = match[1]
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', value) or any(p in ('.','..') for p in value.split('/')):
        raise ValueError('Invalid release repository; expected owner/repository.')
    return value

if __name__ == '__main__':
    print(release_repository())
