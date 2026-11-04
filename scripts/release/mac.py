#!/usr/bin/env python3
"""Explicit local build/notarization and GitHub draft/release pipeline. No CI secrets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
REPO = 'matthewjgl/duo-display'
TEAM = '23222L722A'
ACCOUNT = 'com.matthewjgl.duodisplay.sparkle'
IDENTITY = f'Developer ID Application: Matthew Gonzalez ({TEAM})'
PRODUCTS = [
    ('OpenSidecarMac', 'Duo Display', 'com.matthewjgl.duodisplay.mac', 'appcast.xml', '14.0'),
    ('OpenSidecarMacReceiver', 'Duo Display Receiver', 'com.matthewjgl.duodisplay.mac.receiver', 'appcast-receiver.xml', '12.0'),
]


def run(*args, cwd=ROOT, log=None):
    if log:
        with open(log, 'w') as output:
            result = subprocess.run(args, cwd=cwd, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'{args[0]} failed; inspect {log}')
        return ''
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def tools(derived):
    return derived / 'SourcePackages/artifacts/sparkle/Sparkle/bin'


def validate_feed(path, version, build, asset):
    ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    tree = ET.parse(path)
    item = tree.find('./channel/item')
    if item is None:
        raise RuntimeError('Appcast has no update')
    enclosure = item.find('enclosure')
    if enclosure is None or not enclosure.get(ns + 'edSignature'):
        raise RuntimeError('Appcast archive signature is missing')
    url = f'https://github.com/{REPO}/releases/download/v{version}/{asset.name}'
    if enclosure.get('url') != url or int(enclosure.get('length')) != asset.stat().st_size:
        raise RuntimeError('Appcast download identity or size mismatch')
    if item.findtext(ns + 'version') != build:
        raise RuntimeError('Appcast build number mismatch')


def build_order(value):
    parts = tuple(int(p) for p in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def check_increasing_build(build):
    response = subprocess.run(['gh', 'api', f'repos/{REPO}/releases/latest'], capture_output=True, text=True)
    if response.returncode:
        if '404' in response.stderr:
            return  # No stable release yet (including the first repository setup).
        raise RuntimeError('Cannot verify the previous release; check GitHub authentication before preparing an update.')
    latest = json.loads(response.stdout)
    manifests = [a for a in latest['assets'] if a['name'] == 'release.json']
    if len(manifests) != 1:
        raise RuntimeError('Latest release has no unique release manifest; inspect it before choosing a build number.')
    previous = json.loads(run('gh', 'api', '-H', 'Accept: application/octet-stream',
                              f'repos/{REPO}/releases/assets/{manifests[0]["id"]}'))
    if build_order(build) <= build_order(previous['build']):
        raise RuntimeError(f'Build must increase beyond {previous["build"]}, including across marketing versions.')


def prepare(args):
    check_increasing_build(args.build)
    out = ROOT / 'build/releases' / f'{args.version}-{args.build}'
    if out.exists():
        raise RuntimeError(f'{out} already exists. Resume notarization with the recorded request ID; do not overwrite a frozen candidate.')
    out.mkdir(parents=True)
    source = out / 'source'
    source.mkdir()
    # Include only explicit app/build sources; exclude working notes, .env, websites and artifacts.
    paths = ['Mac', 'MacReceiver', 'Shared', 'iOS', 'MacTests', 'project.yml', 'LICENSE']
    hashes = {}
    for name in paths:
        p = ROOT / name
        candidates = p.rglob('*') if p.is_dir() else [p]
        for f in candidates:
            if not f.is_file() or f.name == '.DS_Store' or f.suffix in ('.p8', '.p12', '.key'):
                continue
            if f.name == 'Info.plist':  # regenerated from the frozen spec
                continue
            rel = f.relative_to(ROOT)
            target = source / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, target)
            hashes[str(rel)] = sha(target)
    save(out / 'source-sha256.json', hashes)
    snapshot = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    metadata = {'version': args.version, 'build': args.build, 'team': TEAM,
                'repository': REPO, 'source_snapshot': snapshot, 'state': 'preparing', 'assets': {}}
    save(out / 'release.json', metadata)
    env = os.environ.copy()
    env['DEVELOPMENT_TEAM'] = TEAM
    subprocess.run(['xcodegen', 'generate'], cwd=source, env=env, check=True)
    derived = out / 'DerivedData'
    for scheme, product, bundle, feed, minimum in PRODUCTS:
        archive = out / f'{scheme}.xcarchive'
        run('xcodebuild', '-project', str(source / 'OpenSidecar.xcodeproj'), '-scheme', scheme,
            '-configuration', 'Release', '-destination', 'generic/platform=macOS',
            '-derivedDataPath', str(derived), '-archivePath', str(archive),
            f'MARKETING_VERSION={args.version}', f'CURRENT_PROJECT_VERSION={args.build}',
            f'DEVELOPMENT_TEAM={TEAM}', 'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={IDENTITY}',
            'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO', 'OTHER_CODE_SIGN_FLAGS=--timestamp',
            'archive', log=out / f'{scheme}-archive.log')
        app = archive / 'Products/Applications' / f'{product}.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] == bundle
        assert info['CFBundleVersion'] == args.build
        assert info['CFBundleShortVersionString'] == args.version
        assert info['SUFeedURL'] == f'https://github.com/{REPO}/releases/latest/download/{feed}'
        public_key = run(str(tools(derived) / 'generate_keys'), '--account', ACCOUNT, '-p')
        assert info['SUPublicEDKey'] == public_key
        run('codesign', '--verify', '--deep', '--strict', str(app))
        signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], capture_output=True, text=True, check=True).stderr
        assert f'TeamIdentifier={TEAM}' in signature and 'runtime' in signature
        assert IDENTITY in signature
        archs = run('lipo', '-archs', str(app / 'Contents/MacOS' / product))
        assert 'arm64' in archs and 'x86_64' in archs
    metadata['state'] = 'awaiting-notarization'
    save(out / 'release.json', metadata)
    if args.build_only:
        print(f'Signed archives prepared at {out}; notarization is pending. Nothing published.')
    else:
        finish_notarization(out, args.profile)


def notarize(path, record, profile):
    request_file = record.with_name(record.name + '-request.json')
    status_file = record.with_name(record.name + '-status.json')
    if request_file.exists():
        request = json.loads(request_file.read_text())
    else:
        request = json.loads(run('xcrun', 'notarytool', 'submit', str(path),
                                 '--keychain-profile', profile, '--output-format', 'json'))
        save(request_file, request)
    # Keep every submission ID. Re-running resumes the same request, not another upload.
    status = json.loads(run('xcrun', 'notarytool', 'info', request['id'], '--keychain-profile',
                            profile, '--output-format', 'json'))
    if status.get('status') == 'In Progress':
        status = json.loads(run('xcrun', 'notarytool', 'wait', request['id'], '--keychain-profile',
                                profile, '--output-format', 'json', '--timeout', '20m'))
    save(status_file, status)
    if status.get('status') != 'Accepted':
        raise RuntimeError(f'Apple notarization is {status.get("status")}; inspect request {request["id"]}. Do not resubmit blindly.')


def finish_notarization(out, profile):
    metadata = json.loads((out / 'release.json').read_text())
    if metadata['state'] not in ('awaiting-notarization', 'ready-for-draft'):
        raise RuntimeError('Signed archive preparation is incomplete')
    args = argparse.Namespace(version=metadata['version'], build=metadata['build'])
    source = out / 'source'
    derived = out / 'DerivedData'
    for scheme, product, bundle, feed, minimum in PRODUCTS:
        app = out / f'{scheme}.xcarchive/Products/Applications/{product}.app'
        zipfile = out / f'{product.replace(" ", "")}-notary.zip'
        if not zipfile.exists():
            run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(zipfile))
        notarize(zipfile, out / f'{scheme}-app-notary', profile)
        run('xcrun', 'stapler', 'staple', str(app))
        run('xcrun', 'stapler', 'validate', str(app))
        run('spctl', '--assess', '--type', 'execute', '--verbose=2', str(app))
        stage = out / f'{scheme}-dmg-source'
        dmg = out / f'{product.replace(" ", "")}.dmg'
        if not dmg.exists():
            stage.mkdir(exist_ok=True)
            shutil.copytree(app, stage / app.name, symlinks=True, dirs_exist_ok=True)
            if not (stage / 'Applications').is_symlink():
                (stage / 'Applications').symlink_to('/Applications')
            (stage / 'LICENSE').write_bytes((source / 'LICENSE').read_bytes())
            run('hdiutil', 'create', '-volname', product, '-srcfolder', str(stage), '-format', 'UDZO', str(dmg))
            run('codesign', '--sign', IDENTITY, '--timestamp', str(dmg))
        notarize(dmg, out / f'{scheme}-dmg-notary', profile)
        run('xcrun', 'stapler', 'staple', str(dmg))
        run('xcrun', 'stapler', 'validate', str(dmg))
        run('codesign', '--verify', '--strict', str(dmg))
        feed_dir = out / f'{scheme}-feed'
        feed_dir.mkdir(exist_ok=True)
        shutil.copy2(dmg, feed_dir / dmg.name)
        run(str(tools(derived) / 'generate_appcast'), '--account', ACCOUNT, '--maximum-deltas', '0',
            '--download-url-prefix', f'https://github.com/{REPO}/releases/download/v{args.version}/',
            '--link', 'https://myduodisplay.com', '-o', str(out / feed), str(feed_dir))
        validate_feed(out / feed, args.version, args.build, dmg)
        run(str(tools(derived) / 'sign_update'), '--account', ACCOUNT, '--verify', str(out / feed))
        enclosure = ET.parse(out / feed).find('./channel/item/enclosure')
        run(str(tools(derived) / 'sign_update'), '--account', ACCOUNT, '--verify', str(dmg),
            enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'))
        metadata['assets'][dmg.name] = sha(dmg)
        metadata['assets'][feed] = sha(out / feed)
        save(out / 'release.json', metadata)
    metadata['state'] = 'ready-for-draft'
    save(out / 'release.json', metadata)
    print(f'Prepared {out}; source snapshot {metadata["source_snapshot"]}. Nothing published.')


def upload(args):
    out = Path(args.artifact).resolve()
    metadata = json.loads((out / 'release.json').read_text())
    if metadata['state'] != 'ready-for-draft' or metadata['repository'] != REPO:
        raise RuntimeError('Candidate is not ready')
    for name, expected in metadata['assets'].items():
        assert sha(out / name) == expected, f'Changed artifact: {name}'
    if not re.fullmatch(r'[a-fA-F0-9]{40}', args.commit):
        raise RuntimeError('Use an exact 40-character source commit SHA')
    tree = json.loads(run('gh', 'api', f'repos/{REPO}/git/trees/{args.commit}?recursive=1'))
    if tree.get('truncated'):
        raise RuntimeError('Source tree is truncated; cannot verify corresponding source')
    blobs = {entry['path']: entry['sha'] for entry in tree['tree'] if entry['type'] == 'blob'}
    source_hashes = json.loads((out / 'source-sha256.json').read_text())
    for name, digest in source_hashes.items():
        data = (out / 'source' / name).read_bytes()
        git_hash = hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()
        if hashlib.sha256(data).hexdigest() != digest or blobs.get(name) != git_hash:
            raise RuntimeError(f'Frozen source differs from release commit: {name}')
    # Corresponding source is included with the exact binary candidate (GPL).
    source_zip = out / 'DuoDisplay-Source.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(out / 'source'), str(source_zip))
    notes = Path(args.notes).resolve()
    tag = f'v{metadata["version"]}'
    # Reject an existing tag/release: never overwrite a released artifact/feed.
    existing = subprocess.run(['gh', 'release', 'view', tag, '--repo', REPO], capture_output=True)
    if existing.returncode == 0:
        raise RuntimeError('Release already exists. Inspect it rather than overwriting.')
    run('gh', 'release', 'create', tag, '--repo', REPO, '--target', args.commit,
        '--draft', '--title', f'Duo Display {metadata["version"]}', '--notes-file', str(notes),
        *[str(out / n) for n in metadata['assets']], str(source_zip), str(out / 'release.json'))
    print(f'Draft created: https://github.com/{REPO}/releases. Not public and not in the update feed.')


def publish(args):
    # User runs this only after explicit approval to release this exact draft.
    data = json.loads(run('gh', 'release', 'view', args.tag, '--repo', REPO, '--json', 'isDraft,assets,isPrerelease'))
    if not data['isDraft'] or data['isPrerelease']:
        raise RuntimeError('Expected a stable draft')
    required = {'DuoDisplay.dmg', 'DuoDisplayReceiver.dmg', 'appcast.xml', 'appcast-receiver.xml', 'release.json', 'DuoDisplay-Source.zip'}
    assert required <= {a['name'] for a in data['assets']}, 'Draft assets are incomplete'
    with tempfile.TemporaryDirectory(prefix='duo-release-verify-') as tmp:
        run('gh', 'release', 'download', args.tag, '--repo', REPO, '--dir', tmp)
        artifact = Path(tmp)
        manifest = json.loads((artifact / 'release.json').read_text())
        if args.tag != f'v{manifest["version"]}' or manifest['state'] != 'ready-for-draft':
            raise RuntimeError('Draft tag/manifest mismatch')
        for name, digest in manifest['assets'].items():
            if sha(artifact / name) != digest:
                raise RuntimeError(f'Draft asset changed: {name}')
        for _, product, _, feed, _ in PRODUCTS:
            validate_feed(artifact / feed, manifest['version'], manifest['build'],
                          artifact / f'{product.replace(" ", "")}.dmg')
    run('gh', 'release', 'edit', args.tag, '--repo', REPO, '--draft=false', '--latest')
    print(f'Published https://github.com/{REPO}/releases/tag/{args.tag}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('prepare')
    p.add_argument('--version', required=True)
    p.add_argument('--build', required=True)
    p.add_argument('--profile', default='DuoDisplay')
    p.add_argument('--build-only', action='store_true', help='Freeze and sign archives while notarization credentials are pending')
    p.set_defaults(func=prepare)
    p = commands.add_parser('notarize')
    p.add_argument('--artifact', required=True)
    p.add_argument('--profile', default='DuoDisplay')
    p.set_defaults(func=lambda args: finish_notarization(Path(args.artifact).resolve(), args.profile))
    p = commands.add_parser('draft')
    p.add_argument('--artifact', required=True)
    p.add_argument('--notes', required=True)
    p.add_argument('--commit', required=True, help='Exact source commit already pushed to the Duo repository')
    p.set_defaults(func=upload)
    p = commands.add_parser('publish')
    p.add_argument('--tag', required=True)
    p.set_defaults(func=publish)
    args = parser.parse_args()
    if args.command == 'prepare':
        if not re.fullmatch(r'\d+\.\d+\.\d+', args.version) or not re.fullmatch(r'[1-9]\d{0,3}(?:\.\d{1,2}){0,2}', args.build):
            parser.error('Use a numeric x.y.z version and an Apple-valid numeric build number.')
    args.func(args)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, AssertionError) as error:
        sys.exit(str(error))
