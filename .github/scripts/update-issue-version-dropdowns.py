#!/usr/bin/env python3
"""Refresh issue-form version dropdowns from full, non-nightly published releases.

The release workflow runs this after publishing. Issue-form dropdown options cannot be
supplied dynamically at form-render time, so this commits a generated dropdown to the
default branch; the next time the form loads it offers the refreshed release list.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TEMPLATES = [
    REPO / ".github/ISSUE_TEMPLATE/BUG-REPORT.yml",
    REPO / ".github/ISSUE_TEMPLATE/FEATURE-REQUEST.yml",
]
UNSELECTED = "Unselected — choose your FineWine Patcher version"

# Issue-form dropdown options are line-oriented. Restrict this replacement to the single
# `id: version` dropdown so unrelated dropdowns/options cannot be rewritten.
VERSION_OPTIONS = re.compile(
    r"(?P<prefix>  - type: dropdown\n"
    r"    id: version\n"
    r"    attributes:\n"
    r".*?      options:\n"
    r")"
    r"(?P<options>(?:        - .*\n)+)"
    r"(?P<suffix>      default: 0)",
    re.S,
)


def full_release_tags() -> list[str]:
    # Ask GitHub for actual releases, rather than treating arbitrary semver tags as releases.
    result = subprocess.run(
        ["gh", "release", "list", "--json", "tagName,isDraft,isPrerelease", "--limit", "1000"],
        cwd=REPO,
        check=True,
        text=True,
        capture_output=True,
        env=os.environ,
    )
    releases = json.loads(result.stdout)
    # Strict full releases only: x.y.z and not draft/prerelease. Nightly/snapshot tags never match.
    versions = [
        release["tagName"]
        for release in releases
        if not release["isDraft"]
        and not release["isPrerelease"]
        and re.fullmatch(r"\d+\.\d+\.\d+", release["tagName"])
    ]
    versions.sort(
        key=lambda version: tuple(int(part) for part in version.split(".")),
        reverse=True,
    )
    if not versions:
        raise RuntimeError("no full x.y.z release versions found")
    return versions


def generated_options(versions: list[str]) -> str:
    lines = [f"        - {UNSELECTED}", *[f"        - {version}" for version in versions]]
    return "\n".join(lines) + "\n"


def refresh(path: Path, versions: list[str]) -> bool:
    text = path.read_text(encoding="utf-8")
    match = VERSION_OPTIONS.search(text)
    if not match:
        raise ValueError(f"no required `id: version` dropdown found in {path.relative_to(REPO)}")

    new_block = generated_options(versions)
    if match.group("options") == new_block:
        print(f"unchanged: {path.relative_to(REPO)}")
        return False

    text = VERSION_OPTIONS.sub(lambda m: m.group("prefix") + new_block + m.group("suffix"), text, count=1)
    path.write_text(text, encoding="utf-8")
    print(f"updated:   {path.relative_to(REPO)} ({len(versions)} release options)")
    return True


def validate_yaml(path: Path) -> None:
    try:
        import yaml
    except ImportError:
        print(f"warning: PyYAML unavailable; skipped YAML validation for {path.name}")
        return
    with path.open(encoding="utf-8") as file:
        data = yaml.safe_load(file)
    if not isinstance(data, dict):
        raise ValueError(f"{path} is not a valid issue-form object")


def main() -> int:
    versions = full_release_tags()
    changed = False
    for template in TEMPLATES:
        if refresh(template, versions):
            changed = True
        validate_yaml(template)
    print("available versions:", ", ".join(versions))
    return 0 if changed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
