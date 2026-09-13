#!/usr/bin/env python3
from release_config import release_repository
import hashlib, json, re, sys, xml.etree.ElementTree as ET
from pathlib import Path

def validate(root):
    meta = json.loads((root/'release.json').read_text())
    version, build, mode = meta['version'], meta['build'], meta['mode']
    assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'Invalid version'
    assert type(build) is int and build > 0, 'Invalid build'
    assert mode in ('signed','preview'), 'Invalid release mode'
    tag = f'v{version}' if mode == 'signed' else f'v{version}-preview.{build}'
    assert meta['tag'] == tag, 'Tag/version mismatch'
    name = f'Cutline-{tag[1:]}-macos-universal'
    assert meta['name'] == name, 'Unexpected archive name'
    checksums = dict(line.split()[::-1] for line in (root/'SHA256SUMS.txt').read_text().splitlines())
    assert set(checksums) == {name+'.zip', name+'.dmg'}, 'Unexpected checksum files'
    for filename, digest in checksums.items():
        assert hashlib.sha256((root/filename).read_bytes()).hexdigest() == digest, 'Checksum mismatch'
    ns={'s':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
    items = ET.parse(root/'appcast.xml').getroot().findall('./channel/item')
    assert len(items) == 1, 'Expected exactly one update'
    item=items[0]; enclosure=item.find('enclosure')
    assert item.findtext('s:version',namespaces=ns) == str(build), 'Feed build mismatch'
    assert item.findtext('s:shortVersionString',namespaces=ns) == version, 'Feed version mismatch'
    assert enclosure.attrib['url'] == f'https://github.com/{release_repository()}/releases/download/{tag}/{name}.zip', 'Unexpected download URL'
    assert int(enclosure.attrib['length']) == (root/(name+'.zip')).stat().st_size, 'Archive size mismatch'
    assert enclosure.attrib['{'+ns['s']+'}edSignature'], 'Missing archive signature'
    return meta

if __name__ == '__main__':
    validate(Path(sys.argv[1])); print('Release checksums, feed version and immutable download URL verified.')
