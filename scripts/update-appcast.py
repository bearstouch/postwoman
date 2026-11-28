#!/usr/bin/env python3
"""Add one release to the Reqs Sparkle appcast.

Usage: python3 -I scripts/update-appcast.py <appcast.xml> --version 1.0.0-beta.2 --bundle-version 1.0.0.32
         --minimum-macos 14.0 --url <dmg url> --length <bytes> --signature <EdDSA> --notes-url <release page> [--date <RFC 2822>]

The file is created when missing. An item for the same bundle version is replaced, so a re-run is harmless. Items are
ordered newest first by bundle version; pre-releases (X.Y.Z-alpha|beta|rc.N) go on the `beta` channel.

PostWoman (com.bearstouch.postwoman, up to 0.11.0) reads this feed too, through GitHub's redirect from the old repo. Sparkle
won't install an app with another bundle identifier, so every item is informational below FIRST_REQS_VERSION: PostWoman
shows "Reqs is available" with a link to the release page instead of downloading an update it can't install.
"""
import argparse
import email.utils
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION = re.compile(r"\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.[1-9]\d?)?")
BUNDLE_VERSION = re.compile(r"\d+(?:\.\d+){1,3}")
FIRST_REQS_VERSION = "0.11.1"
ET.register_namespace("sparkle", SPARKLE)


def tag(name):
    return f"{{{SPARKLE}}}{name}"


def numbers(version):
    return tuple(int(part) for part in version.split("."))


def bundle_key(item):
    text = item.findtext(tag("version")) or "0"
    return tuple(int(part) for part in text.split(".")) if BUNDLE_VERSION.fullmatch(text) else (0,)


CHANNEL = {"title": "Reqs", "link": "https://github.com/bearstouch/reqs", "description": "Reqs updates", "language": "en"}


def load(path):
    if not os.path.exists(path):
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        for name, text in CHANNEL.items():
            ET.SubElement(channel, name).text = text
        return ET.ElementTree(rss)
    tree = ET.parse(path)
    channel = tree.getroot().find("channel")
    if tree.getroot().tag != "rss" or channel is None:
        raise SystemExit(f"{path} is not an RSS appcast; refusing to overwrite it.")
    # The feed began as PostWoman's: retitle it, and keep its items for the PostWoman versions that still read it.
    for name, text in CHANNEL.items():
        (channel.find(name) if channel.find(name) is not None else ET.SubElement(channel, name)).text = text
    return tree


def update(tree, args):
    channel = tree.getroot().find("channel")
    for item in channel.findall("item"):
        if item.findtext(tag("version")) == args.bundle_version:
            channel.remove(item)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Reqs {args.version}"
    ET.SubElement(item, "pubDate").text = args.date or email.utils.formatdate(usegmt=True)
    ET.SubElement(item, tag("version")).text = args.bundle_version
    ET.SubElement(item, tag("shortVersionString")).text = args.version
    ET.SubElement(item, tag("minimumSystemVersion")).text = args.minimum_macos
    ET.SubElement(item, tag("fullReleaseNotesLink")).text = args.notes_url
    ET.SubElement(item, "link").text = args.notes_url
    informational = ET.SubElement(item, tag("informationalUpdate"))
    ET.SubElement(informational, tag("belowVersion")).text = FIRST_REQS_VERSION
    if "-" in args.version:
        ET.SubElement(item, tag("channel")).text = "beta"
    ET.SubElement(item, "enclosure", {"url": args.url, "length": str(args.length), "type": "application/octet-stream", tag("edSignature"): args.signature})
    items = sorted(channel.findall("item") + [item], key=bundle_key, reverse=True)
    for old in channel.findall("item"):
        channel.remove(old)
    channel.extend(items)


def save(tree, path):
    ET.indent(tree, space="  ")
    directory = os.path.dirname(os.path.abspath(path))
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".appcast-")
    try:
        with os.fdopen(handle, "wb") as file:
            tree.write(file, encoding="utf-8", xml_declaration=True)
            file.write(b"\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("appcast")
    parser.add_argument("--version", required=True)
    parser.add_argument("--bundle-version", required=True)
    parser.add_argument("--minimum-macos", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True, type=int)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--notes-url", required=True)
    parser.add_argument("--date")
    args = parser.parse_args(argv)
    if not VERSION.fullmatch(args.version):
        parser.error(f"unsupported version {args.version!r}")
    if not BUNDLE_VERSION.fullmatch(args.bundle_version):
        parser.error(f"bundle version {args.bundle_version!r} is not numeric")
    if numbers(args.bundle_version) < numbers(FIRST_REQS_VERSION):
        parser.error(f"bundle version {args.bundle_version} is a PostWoman one; Reqs versions start at {FIRST_REQS_VERSION}")
    if not args.url.startswith("https://") or not args.notes_url.startswith("https://"):
        parser.error("update and release-notes URLs must be HTTPS")
    if args.length <= 0 or not re.fullmatch(r"[A-Za-z0-9+/]{86}==", args.signature):
        parser.error("length must be positive and the signature a base64 Ed25519 signature")
    return args


def main(argv):
    args = parse(argv)
    tree = load(args.appcast)
    update(tree, args)
    save(tree, args.appcast)


if __name__ == "__main__":
    main(sys.argv[1:])
