#!/usr/bin/env python3
"""Reject issue-form submissions that still have the default/unselected version.

GitHub issue forms preselect the first dropdown option even when a field is required, so
this post-submission check treats only exact, existing x.y.z full releases as valid. Invalid
issues are labelled and commented, but are not closed automatically.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

BODY = os.environ.get("ISSUE_BODY", "")
ISSUE_NUMBER = os.environ.get("ISSUE_NUMBER", "")
LABEL = "invalid-version"
UNSELECTED = "unselected"


def release_versions() -> set[str]:
    result = subprocess.run(
        ["gh", "release", "list", "--json", "tagName,isDraft,isPrerelease", "--limit", "1000"],
        check=True,
        text=True,
        capture_output=True,
        env=os.environ,
    )
    releases = json.loads(result.stdout)
    return {
        release["tagName"]
        for release in releases
        if not release["isDraft"]
        and not release["isPrerelease"]
        and re.fullmatch(r"\d+\.\d+\.\d+", release["tagName"])
    }


def selected_version(body: str) -> str | None:
    match = re.search(
        r"^### Version\s*$\n\n(?P<value>.*?)(?=^### |\Z)",
        body,
        re.M | re.S,
    )
    if not match:
        return None
    return match.group("value").strip()


def run_gh(*args: str) -> None:
    subprocess.run(["gh", *args], check=True, text=True, capture_output=True)


def ensure_label() -> None:
    try:
        run_gh(
            "label", "create", LABEL,
            "--color", "D93F0B",
            "--description", "No valid Patcher release version was selected",
        )
    except subprocess.CalledProcessError:
        # The label already exists.
        pass


def main() -> int:
    versions = release_versions()
    selected = selected_version(BODY)

    valid = (
        selected is not None
        and UNSELECTED not in selected.lower()
        and selected in versions
    )
    if valid:
        try:
            run_gh("issue", "edit", ISSUE_NUMBER, "--remove-label", LABEL)
        except subprocess.CalledProcessError:
            pass
        print(f"valid version: {selected}")
        return 0

    ensure_label()
    try:
        run_gh("issue", "edit", ISSUE_NUMBER, "--add-label", LABEL)
    except subprocess.CalledProcessError as error:
        print(error.stderr, file=sys.stderr)

    detail = selected or "(version section missing or blank)"
    message = (
        "Please select the exact FineWine Patcher version you are running in the **Version** "
        "dropdown. “Unselected” is not accepted. Nightly builds are not listed here; if this "
        "report is only about a nightly, mention the nightly tag in the report after selecting "
        "the nearest release."
    )
    try:
        run_gh("issue", "comment", ISSUE_NUMBER, "--body", message)
    except subprocess.CalledProcessError as error:
        print(error.stderr, file=sys.stderr)

    print(f"invalid version: {detail}", file=sys.stderr)
    print(f"::error::Issue #{ISSUE_NUMBER} does not select a valid full release version")
    return 1


if __name__ == "__main__":
    sys.exit(main())
