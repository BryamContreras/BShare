#!/usr/bin/env python3
"""Resolve one validated version/build number for every CI installer."""

import argparse
import json
import re
from pathlib import Path


def metadata(pubspec: Path, run_number: int) -> dict[str, str]:
    match = re.search(
        r"^version:\s*['\"]?(\d+\.\d+\.\d+)(?:\+(\d+))?['\"]?\s*$",
        pubspec.read_text(),
        re.MULTILINE,
    )
    if not match:
        raise ValueError("pubspec.yaml must contain a numeric version and build")
    version = match.group(1)
    build = int(match.group(2) or "0") + run_number
    if run_number < 0 or not 1 <= build <= 65535:
        raise ValueError("The shared Windows/Android build number must be 1..65535")
    if any(int(part) > 65535 for part in version.split(".")):
        raise ValueError("Version components must fit Windows version metadata")
    return {"version": version, "build-number": str(build)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    parser.add_argument("--run-number", type=int, default=0)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--tag", default="")
    args = parser.parse_args()
    values = metadata(args.pubspec, args.run_number)
    if args.tag and args.tag != "v" + values["version"]:
        raise ValueError("Release tag must match the version in pubspec.yaml")
    if args.github_output:
        with args.github_output.open("a") as output:
            for key, value in values.items():
                output.write(f"{key}={value}\n")
    print(json.dumps(values))


if __name__ == "__main__":
    main()
