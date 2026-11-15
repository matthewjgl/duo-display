import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile
import subprocess

spec = importlib.util.spec_from_file_location('release_mac', Path(__file__).with_name('mac.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class FeedChecks(unittest.TestCase):
    def test_finder_cleanup_preserves_contents_and_other_attributes(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Example.app'
            app.mkdir()
            helper = app / 'helper'
            helper.write_bytes(b'unchanged signed contents')
            subprocess.run(['/usr/bin/xattr', '-wx', 'com.apple.FinderInfo', '41' * 32, str(helper)], check=True)
            subprocess.run(['/usr/bin/xattr', '-w', 'com.example.preserved', 'keep', str(helper)], check=True)
            release.clear_finder_metadata(app)
            attrs = subprocess.check_output(['/usr/bin/xattr', str(helper)], text=True)
            self.assertNotIn('com.apple.FinderInfo', attrs)
            self.assertIn('com.example.preserved', attrs)
            self.assertEqual(helper.read_bytes(), b'unchanged signed contents')

    def test_packaging_resume_preserves_framework_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / 'distribution/SideExtend.app'
            versions = app / 'Contents/Frameworks/Example.framework/Versions'
            (versions / 'A').mkdir(parents=True)
            (versions / 'A/binary').write_text('signed bytes')
            (versions / 'Current').symlink_to('A')
            stage = root / 'stage'
            release.stage_distribution_app(app, stage)
            release.stage_distribution_app(app, stage)
            copied = stage / app.name / 'Contents/Frameworks/Example.framework/Versions'
            self.assertTrue((copied / 'Current').is_symlink())
            self.assertEqual((copied / 'Current/binary').read_text(), 'signed bytes')

    def test_source_archive_excludes_unlisted_local_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'source/build').mkdir(parents=True)
            (root / 'source/app.swift').write_text('approved source')
            (root / 'source/.env').write_text('not for distribution')
            (root / 'source/build/private-notes.txt').write_text('not for distribution')
            archive = root / 'source.zip'
            release.archive_frozen_source(root, {'app.swift': release.sha(root / 'source/app.swift')}, archive)
            with zipfile.ZipFile(archive) as z:
                self.assertIn('source/app.swift', z.namelist())
                self.assertFalse(any('.env' in n or 'private-notes' in n for n in z.namelist()))

    def test_rebrand_preserves_identities_and_historical_product_names(self):
        current = release.products_for({'brand': 'SideExtend'})
        previous = release.products_for({})
        self.assertEqual([p[1] for p in current], ['SideExtend', 'SideExtend Receiver'])
        self.assertEqual([p[1] for p in previous], ['Duo Display', 'Duo Display Receiver'])
        for new, old in zip(current, previous):
            self.assertEqual(new[0], old[0])
            self.assertEqual(new[2:], old[2:])

    def test_legacy_downloads_keep_exact_signed_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metadata = {'brand': 'SideExtend', 'assets': {}}
            for name in ['SideExtend.dmg', 'SideExtendReceiver.dmg']:
                (root / name).write_bytes(('signed ' + name).encode())
            release.preserve_download_aliases(root, metadata)
            self.assertEqual((root / 'DuoDisplay.dmg').read_bytes(), (root / 'SideExtend.dmg').read_bytes())
            self.assertEqual((root / 'DuoDisplayReceiver.dmg').read_bytes(), (root / 'SideExtendReceiver.dmg').read_bytes())
            self.assertEqual(metadata['assets']['DuoDisplay.dmg'], release.sha(root / 'SideExtend.dmg'))

    def test_build_order_is_numeric_and_normalized(self):
        self.assertGreater(release.build_order('1.10'), release.build_order('1.9'))
        self.assertGreater(release.build_order('2'), release.build_order('1.99'))
        self.assertEqual(release.build_order('1.2'), release.build_order('1.2.0'))

    def test_accepts_correct_signed_asset_and_rejects_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            asset = root / 'DuoDisplay.dmg'
            asset.write_bytes(b'signed fixture')
            feed = root / 'appcast.xml'
            template = '''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>1</sparkle:version><enclosure url="https://github.com/matthewjgl/duo-display/releases/download/v1.0.0/DuoDisplay.dmg" length="14" sparkle:edSignature="fixture"/></item></channel></rss>'''
            feed.write_text(template)
            release.validate_feed(feed, '1.0.0', '1', asset)
            for changed in [template.replace('duo-display/', 'opendisplay/'),
                            template.replace('length="14"', 'length="15"'),
                            template.replace('sparkle:edSignature="fixture"', ''),
                            template.replace('>1</sparkle:version>', '>2</sparkle:version>')]:
                feed.write_text(changed)
                with self.assertRaises(RuntimeError):
                    release.validate_feed(feed, '1.0.0', '1', asset)

if __name__ == '__main__':
    unittest.main()
