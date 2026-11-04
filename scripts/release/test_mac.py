import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_mac', Path(__file__).with_name('mac.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class FeedChecks(unittest.TestCase):
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
