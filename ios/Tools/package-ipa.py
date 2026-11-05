#!/usr/bin/env python3
"""Package a device .app without AppleDouble files.

AltSign's unzipAppBundleAtURL selects Payload's first *.app entry without
checking that it is a directory. ditto can emit ._PocketFilm.app beside the
actual bundle, causing an invalid-format error before signing starts.
"""
import argparse
import plistlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


def metadata(path):
    return any(part.startswith('._') or part in {'__MACOSX', '.DS_Store'} for part in path.parts)


def package(app, output):
    app = Path(app).resolve()
    output = Path(output).resolve()
    if app.suffix != '.app' or not app.is_dir():
        raise ValueError('Input must be a built .app directory')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or '/' in executable or not (app / executable).is_file():
        raise ValueError('Missing bundle executable')
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Expected an iPhoneOS device build, not simulator/macOS')
    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, 'w', compression=ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob('*')):
            relative = path.relative_to(app)
            if metadata(relative):
                continue
            archive.write(path, 'Payload/' + app.name + '/' + relative.as_posix())
    with ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError('IPA integrity check failed')
        names = archive.namelist()
        if any(metadata(Path(name)) for name in names):
            raise ValueError('Archive contains macOS metadata')
        apps = {name.split('/')[1] for name in names if name.startswith('Payload/')}
        if apps != {app.name}:
            raise ValueError('Payload must contain exactly one actual app bundle')
    print('Packaged:', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app')
    parser.add_argument('output')
    args = parser.parse_args()
    package(args.app, args.output)
