#!/usr/bin/env python3
"""Generate human-readable release notes for a full Endfield FineWine release.

Reuses the same LLM backend as the wiki generator (OpenRouter, via the
OPENROUTER_API_KEY repo secret and the `ai.model` set in .git-wiki-builder.yml)
to summarize the commits since the previous release tag.

If the model is unavailable (free-tier models intermittently answer HTTP 200 with
an error body), this falls back to a plain commit list — a flaky model must never
block a release. It never exits non-zero because of an LLM error.

Inputs are read from the environment (NOTES_*), so multi-line commit logs can be
passed through without shell quoting problems. Usage:

    python3 .github/scripts/generate-release-notes.py [OUTPUT_PATH]

Writes the assembled Markdown to OUTPUT_PATH (default: notes.md) and prints it.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

ATTEMPTS = 3
BACKOFF_SECONDS = (5, 15, 30)
DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
DEFAULT_MODEL = "openrouter/free"

SYSTEM_PROMPT = (
    "You write release notes for a macOS application called FineWine Patcher. "
    "Produce concise, factual, human-readable Markdown. Use only the information "
    "given to you — never invent features, versions, file names, or bug numbers. "
    "Prefer describing user-visible effects over internal implementation details. "
    "Output exactly: a 1-3 sentence overview paragraph, then a '### Highlights' "
    "section of short bullets for the notable changes, then an optional "
    "'### Fixes & changes' section of short bullets. Do not add a top-level "
    "heading (the release body supplies one) and do not repeat the asset list."
)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def call_model(*, base_url: str, api_key: str, model: str, user_prompt: str) -> str:
    payload = json.dumps(
        {
            "model": model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.3,
            "max_tokens": 2000,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        base_url.rstrip("/") + "/chat/completions",
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        body = json.loads(response.read().decode("utf-8"))
    # OpenRouter free models can answer 200 with {"error": {...}} and no choices.
    choices = body.get("choices")
    if not choices:
        raise RuntimeError(
            "non-completion response (HTTP 200 with error body): "
            f"{json.dumps(body)[:1500]}"
        )
    content = (choices[0].get("message") or {}).get("content")
    if not content:
        raise RuntimeError("completion had empty content")
    return str(content).strip()


def summarize(*, model: str, base_url: str, api_key: str, prompt: str) -> str | None:
    last_error: Exception | None = None
    for attempt in range(1, ATTEMPTS + 1):
        try:
            return call_model(base_url=base_url, api_key=api_key, model=model,
                              user_prompt=prompt)
        except Exception as error:  # noqa: BLE001 — free models fail in many ways
            last_error = error
            if attempt < ATTEMPTS:
                wait = BACKOFF_SECONDS[attempt - 1]
                print(
                    f"::warning::release-notes LLM attempt {attempt}/{ATTEMPTS} "
                    f"failed, retrying in {wait}s: {str(error)[:400]}",
                    file=sys.stderr,
                )
                time.sleep(wait)
    print(
        f"::warning::release-notes LLM unavailable after {ATTEMPTS} attempts "
        f"({last_error}); falling back to the raw commit list.",
        file=sys.stderr,
    )
    return None


def commit_subjects(commits: str) -> list[str]:
    subjects = []
    for line in commits.splitlines():
        line = line.strip()
        if not line:
            continue
        # Drop a leading short SHA ("abc1234 subject") for a cleaner bullet.
        parts = line.split(" ", 1)
        subjects.append(parts[1].strip() if len(parts) == 2 else line)
    return subjects


def fallback_summary(commits: str) -> str:
    subjects = commit_subjects(commits)
    if not subjects:
        return "No source changes were recorded since the previous release."
    bullets = "\n".join(f"- {subject}" for subject in subjects[:40])
    return f"### Changes\n\n{bullets}"


def build_prompt(*, version: str, previous: str, commits: str, changed: str) -> str:
    since = f"since the previous release {previous}" if previous else "for the initial release"
    parts = [
        f"Project: FineWine Patcher — a macOS app that patches a copy of CrossOver "
        f"(CodeWeavers) so Arknights: Endfield runs on Apple Silicon. It bundles patched "
        f"Wine modules and a patched MoltenVK.",
        f"Write the release notes {since}. New version: {version}.",
        "",
        "Commits:",
        "```text",
        (commits.strip() or "(none)")[:8000],
        "```",
    ]
    if changed.strip():
        parts += ["", "Changed files (diffstat):", "```text", changed.strip()[:6000], "```"]
    return "\n".join(parts)


def compose(
    *,
    summary: str,
    previous: str,
    commits: str,
    cx_ver: str,
    sha: str,
    repo: str,
    run_url: str,
    run_number: str,
) -> str:
    since = f"since {previous}" if previous else "since the initial release"
    out: list[str] = [summary.strip(), ""]

    out += [
        "### What's inside",
        "",
        "| Asset | What it is |",
        "|---|---|",
        f"| `FineWine.Patcher.app.zip` | **FineWine Patcher.app** — patches a copy of your "
        f"CrossOver {cx_ver} with the anti-cheat Wine modules and a patched MoltenVK "
        f"(open it and follow the UI). |",
        f"| `endfield-wine-modules.tar.gz` | The patched Wine modules + MoltenVK, for "
        f"`scripts/apply-modules.sh` / `scripts/swap-into-crossover.sh` users. |",
        "| `SHA256SUMS.txt` | SHA-256 checksums of the assets. |",
        "",
        f"**Requires:** a licensed CrossOver **{cx_ver}** (the Wine ABI must match) · "
        f"Apple Silicon · macOS 15+ · Rosetta 2.",
        "",
    ]

    if commits.strip():
        out += [
            f"<details><summary>Full commit list {since}</summary>",
            "",
            "```text",
            commits.strip(),
            "```",
            "",
            "</details>",
            "",
        ]

    out += [
        "### Provenance & license",
        "",
        f"- Built at `{sha[:12]}` by [run #{run_number}]({run_url}).",
        f"- CrossOver Wine source: "
        f"[`crossover-sources-{cx_ver}.tar.gz`](https://media.codeweavers.com/pub/crossover/"
        f"source/crossover-sources-{cx_ver}.tar.gz) + this repo's "
        f"[`patches/`](https://github.com/{repo}/tree/{sha}/patches).",
        "- The patched Wine modules are **LGPL-2.1-or-later**; the bundled MoltenVK is "
        "**Apache-2.0**. The complete corresponding source is the CrossOver tarball above, "
        "the pinned MoltenVK revision, and this repo's patches.",
        "",
    ]
    return "\n".join(out)


def main() -> int:
    output_path = sys.argv[1] if len(sys.argv) > 1 else "notes.md"

    version = env("NOTES_VERSION")
    previous = env("NOTES_PREVIOUS")
    commits = env("NOTES_COMMITS")
    changed = env("NOTES_CHANGED")
    cx_ver = env("NOTES_CX_VER")
    sha = env("NOTES_SHA")
    repo = env("NOTES_REPO")
    run_url = env("NOTES_RUN_URL")
    run_number = env("NOTES_RUN_NUMBER")
    model = env("NOTES_MODEL") or DEFAULT_MODEL
    base_url = env("NOTES_BASE_URL") or DEFAULT_BASE_URL
    api_key = env("OPENROUTER_API_KEY")

    summary: str | None = None
    if api_key:
        prompt = build_prompt(version=version, previous=previous, commits=commits,
                              changed=changed)
        print(f"[release-notes] asking {model} to summarize changes ...")
        summary = summarize(model=model, base_url=base_url, api_key=api_key, prompt=prompt)
    else:
        print("::warning::OPENROUTER_API_KEY is not set; using the raw commit list.",
              file=sys.stderr)

    if not summary:
        summary = fallback_summary(commits)

    notes = compose(summary=summary, previous=previous, commits=commits, cx_ver=cx_ver,
                    sha=sha, repo=repo, run_url=run_url, run_number=run_number)

    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(notes + "\n")
    print(notes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
