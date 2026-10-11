#!/usr/bin/env python3
"""Choose an open version train without changing local Release settings."""
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.parse
import urllib.request


def version_tuple(value):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError("Expected a numeric X.Y.Z marketing version")
    return tuple(int(part) for part in value.split("."))


def choose_version(source, published, override=None):
    minimum = version_tuple(source)
    if published:
        major, minor, patch = version_tuple(published)
        minimum = max(minimum, (major, minor, patch + 1))
    if override:
        requested = version_tuple(override)
        if requested < minimum:
            raise ValueError("PORTBASE_MARKETING_VERSION is below the open version train")
        minimum = requested
    return ".".join(map(str, minimum))


def main():
    platform = os.environ.get("CI_PRODUCT_PLATFORM")
    targets = {"iOS": ("PortSQL", "software"), "macOS": ("PortbaseMac", "macSoftware")}
    if platform not in targets:
        raise ValueError("Archive platform must be iOS or macOS")
    target_name, entity = targets[platform]
    project = Path("PortSQL.xcodeproj/project.pbxproj")
    parsed = json.loads(subprocess.check_output(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(project)], text=True))
    objects = parsed["objects"]
    target = next(obj for obj in objects.values()
                  if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == target_name)
    configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
    configuration_id = next(key for key in configurations
                            if objects[key]["name"] == "Release-Cloud")
    settings = objects[configuration_id]["buildSettings"]
    if settings.get("CODE_SIGN_STYLE") != "Automatic":
        raise ValueError("The Cloud archive configuration must use automatic signing")

    query = urllib.parse.urlencode({"id": "6762447018", "country": "us", "entity": entity})
    with urllib.request.urlopen("https://itunes.apple.com/lookup?" + query, timeout=30) as response:
        payload = json.load(response)
    kind = "mac-software" if platform == "macOS" else "software"
    matches = [entry for entry in payload.get("results", [])
               if entry.get("bundleId") == "ad.neko.portsql" and entry.get("kind") == kind]
    if len(matches) > 1 or (platform == "iOS" and not matches):
        raise ValueError("Could not uniquely resolve the published platform version")
    # macOS has no published version until its first release is approved.
    published = matches[0]["version"] if matches else None
    chosen = choose_version(settings["MARKETING_VERSION"], published,
                            os.environ.get("PORTBASE_MARKETING_VERSION"))
    source = project.read_text()
    block_pattern = rf"(?m)^\t\t{configuration_id} /\* Release-Cloud \*/ = \{{.*?^\t\t\}};"
    block = re.search(block_pattern, source, re.DOTALL)
    if not block:
        raise ValueError("Cloud build configuration is missing from the project")
    replacement, count = re.subn(r"MARKETING_VERSION = [0-9.]+;",
                                f"MARKETING_VERSION = {chosen};", block.group())
    if count != 1:
        raise ValueError("Cloud build configuration must have one marketing version")
    project.write_text(source[:block.start()] + replacement + source[block.end():])
    print(f"{platform} Cloud archive: {chosen} (published {published or 'not yet released'}).")


if __name__ == "__main__":
    main()
