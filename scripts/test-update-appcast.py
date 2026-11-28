#!/usr/bin/env python3
"""Check scripts/update-appcast.py: ordering, channels, idempotency, escaping and refusals.

Usage: python3 -I scripts/test-update-appcast.py
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SCRIPT = Path(__file__).resolve().parent / "update-appcast.py"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIGNATURE = "A" * 86 + "=="


def run(appcast, version, bundle, url=None, check=True):
    url = url or f"https://github.com/bearstouch/reqs/releases/download/v{version}/Reqs-{version}.dmg"
    command = [sys.executable, "-I", str(SCRIPT), str(appcast), "--version", version, "--bundle-version", bundle, "--minimum-macos", "14.0",
               "--url", url, "--length", "1234", "--signature", SIGNATURE,
               "--notes-url", f"https://github.com/bearstouch/reqs/releases/tag/v{version}", "--date", "Sat, 24 Oct 2026 12:00:00 GMT"]
    return subprocess.run(command, capture_output=True, text=True, check=check)


def items(appcast):
    return ET.parse(appcast).getroot().find("channel").findall("item")


def main():
    with tempfile.TemporaryDirectory(prefix="reqs appcast ") as temporary:
        appcast = Path(temporary) / "appcast.xml"
        run(appcast, "1.0.0-beta.2", "1.0.0.32")
        run(appcast, "1.0.0", "1.0.0.100")
        run(appcast, "1.0.0-beta.1", "1.0.0.31")
        versions = [item.findtext(f"{SPARKLE}version") for item in items(appcast)]
        assert versions == ["1.0.0.100", "1.0.0.32", "1.0.0.31"], versions
        channels = {item.findtext(f"{SPARKLE}shortVersionString"): item.findtext(f"{SPARKLE}channel") for item in items(appcast)}
        assert channels == {"1.0.0": None, "1.0.0-beta.2": "beta", "1.0.0-beta.1": "beta"}, channels
        enclosure = items(appcast)[0].find("enclosure")
        assert enclosure.get(f"{SPARKLE}edSignature") == SIGNATURE and enclosure.get("length") == "1234"

        before = appcast.read_bytes()
        run(appcast, "1.0.0", "1.0.0.100")
        assert appcast.read_bytes() == before, "re-running a release must not change the feed"

        run(appcast, "1.0.1", "1.0.1.100", url="https://example.com/Reqs.dmg?a=1&b=<2>")
        assert items(appcast)[0].find("enclosure").get("url") == "https://example.com/Reqs.dmg?a=1&b=<2>", "URLs are escaped, not injected"
        assert len(items(appcast)) == 4

        for bad in (["1.0.2", "1.0.2.100", "http://example.com/x.dmg"], ["1.0", "1.0.0.100", None], ["1.0.3", "1.0.3-beta", None]):
            result = run(appcast, bad[0], bad[1], url=bad[2], check=False)
            assert result.returncode != 0, bad
        assert len(items(appcast)) == 4, "rejected input leaves the feed unchanged"

        other = Path(temporary) / "other.xml"
        other.write_text("<html/>")
        assert run(other, "1.0.0", "1.0.0.100", check=False).returncode != 0 and other.read_text() == "<html/>", "never overwrite a non-appcast"
    print("update-appcast: all checks passed")


if __name__ == "__main__":
    main()
