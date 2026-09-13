#!/usr/bin/env python3
from release_config import release_repository
import plistlib, sys
from pathlib import Path
path, name, identifier, version, build, channel = sys.argv[1:]
info = dict(CFBundleName=name, CFBundleDisplayName=name, CFBundleIdentifier=identifier,
            CFBundleExecutable='Cutline', CFBundlePackageType='APPL', CFBundleShortVersionString=version,
            CFBundleVersion=build, LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True,
            NSPrincipalClass='NSApplication', CutlineReleaseChannel=channel,
            UTExportedTypeDeclarations=[dict(UTTypeIdentifier='studio.cutline.project', UTTypeDescription='Cutline Project',
                UTTypeConformsTo=['public.json'], UTTypeTagSpecification={'public.filename-extension':['cutline']})],
            CFBundleDocumentTypes=[dict(CFBundleTypeName='Cutline Project', CFBundleTypeRole='Editor',
                LSHandlerRank='Owner' if identifier=='studio.cutline.editor' else 'Alternate', LSItemContentTypes=['studio.cutline.project'])])
info['CutlineReleasesURL'] = f'https://github.com/{release_repository()}/releases'
if identifier == 'studio.cutline.editor':
    info.update(SUFeedURL=f'https://raw.githubusercontent.com/{release_repository()}/updates/appcast.xml',
                SUPublicEDKey=Path('Config/SparklePublicKey.txt').read_text().strip(),
                SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                SUEnableSystemProfiling=False, SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
Path(path).write_bytes(plistlib.dumps(info))
