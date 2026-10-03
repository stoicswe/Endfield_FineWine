#!/usr/bin/env python3
"""CI wrapper that runs git-wiki-builder with runtime patches.

git-wiki-builder 0.1.4 has gaps that matter for this repo:

1. The `wiki_structure` key documented for `.git-wiki-builder.yml` is never
   read — `Config.wiki_structure` is a hardcoded default (8 sections, including
   an "API Reference" section that would make the AI invent fake API docs for
   a Wine-patch repo). We replace the property with our structure from the
   config file (+ a safe structure-builder, since the stock customizer does
   `structure["API Reference"].extend(...)` unconditionally).

2. Free OpenRouter models intermittently answer HTTP 200 with a JSON error
   body (rate limit / upstream saturation) instead of a completion. The stock
   client then dies with "'NoneType' object is not subscriptable" on
   `response.choices[0]`. We swap the generation call for one that detects
   that shape, logs the API's error payload, and retries with backoff.

3. Publishing: GitHub's Actions `GITHUB_TOKEN` cannot push to the separate
   `<repo>.wiki.git` repository (platform rule). We use the `WIKI_TOKEN`
   repo secret (a PAT) when present, and replace the stock push logic — which
   silently swallows the first two push attempts and only surfaces a
   misleading "no upstream branch" error — with one that logs every attempt
   and explains the likely fix (enable the wiki + WIKI_TOKEN PAT).

Run instead of the `git-wiki-builder` console script; all CLI flags pass
through unchanged (e.g. `--dry-run`, `--verbose`, `--output-dir`).
"""

import logging
import os
import time
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = REPO_ROOT / ".git-wiki-builder.yml"

log = logging.getLogger("generate-wiki")

# Same system prompt the stock client uses.
SYSTEM_PROMPT = (
    "You are a technical documentation expert. Generate high-quality, "
    "well-structured markdown documentation that follows best practices. "
    "Ensure proper heading hierarchy, clear formatting, and comprehensive "
    "coverage of the requested topic."
)

ATTEMPTS = 3
BACKOFF_SECONDS = (5, 15, 30)


def patch_wiki_structure() -> None:
    """Make Config.wiki_structure return our .git-wiki-builder.yml structure.

    The generator also unconditionally extends `structure["API Reference"]`
    (and "Deployment"/"Development") when it detects API/Docker/test/CI markers
    in the repo — a KeyError for any custom structure that drops those
    sections — so its structure builder is replaced with a safe version too.
    """
    from git_wiki_builder.config import Config
    from git_wiki_builder.generator import WikiGenerator

    custom = {}
    if CONFIG_PATH.exists():
        custom = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8")) or {}

    structure = custom.get("wiki_structure")
    if not structure:
        print("[generate-wiki] no wiki_structure in config; using tool default")
        return

    Config.wiki_structure = property(lambda self: structure)

    def safe_structure(self, project_analysis):
        structure = {k: list(v) for k, v in dict(self.config.wiki_structure).items()}
        if project_analysis.has_api_docs and "API Reference" in structure:
            structure["API Reference"].extend(["sdk_reference", "code_examples"])
        if project_analysis.has_docker and "Deployment" in structure:
            structure["Deployment"].extend(["docker_deployment", "container_management"])
        if project_analysis.has_tests and "Development" in structure:
            structure["Development"].extend(["running_tests", "test_coverage"])
        if project_analysis.has_ci_cd and "Development" in structure:
            structure["Development"].extend(["ci_cd_pipeline", "automated_deployment"])
        return {k: v for k, v in structure.items() if v}

    WikiGenerator._generate_wiki_structure = safe_structure

    pages = sum(len(v) for v in structure.values())
    print(
        f"[generate-wiki] patched wiki_structure: "
        f"{len(structure)} sections / {pages} pages"
    )


def patch_ai_client() -> None:
    """Retry AI calls and surface HTTP-200-with-error-body responses."""
    from git_wiki_builder.ai_client import AIClient

    log = logging.getLogger("generate-wiki")

    def generate_with_retry(self, prompt: str) -> str:
        last_error: Exception = RuntimeError("unreachable")
        for attempt in range(1, ATTEMPTS + 1):
            try:
                response = self.client.chat.completions.create(
                    model=self.config.ai_model,
                    messages=[
                        {"role": "system", "content": SYSTEM_PROMPT},
                        {"role": "user", "content": prompt},
                    ],
                    temperature=0.3,
                    max_tokens=4000,
                )
                # OpenRouter free models can answer 200 with {"error": {...}}
                # and no `choices`; the stock code crashes on choices[0].
                choices = getattr(response, "choices", None)
                if not choices:
                    body = (
                        response.model_dump_json()
                        if hasattr(response, "model_dump_json")
                        else repr(response)
                    )
                    raise RuntimeError(
                        "API returned a non-completion response "
                        f"(HTTP 200 with error body): {body[:2000]}"
                    )
                content = choices[0].message.content
                if not content:
                    raise RuntimeError(
                        "completion had empty content "
                        "(reasoning-only output or truncated response)"
                    )
                return str(content).strip()
            except Exception as error:  # free models fail in many ways; retry all
                last_error = error
                if attempt < ATTEMPTS:
                    wait = BACKOFF_SECONDS[attempt - 1]
                    log.warning(
                        "AI request failed (attempt %d/%d), retrying in %ds: %s",
                        attempt,
                        ATTEMPTS,
                        wait,
                        str(error)[:500],
                    )
                    time.sleep(wait)
        raise last_error

    AIClient._generate_openai_content = generate_with_retry


def patch_wiki_publisher() -> None:
    """Make wiki publishing work and fail honestly.

    - Uses the WIKI_TOKEN repo secret (a PAT) for the clone/push of the
      separate <repo>.wiki.git repo; falls back to GITHUB_TOKEN when unset.
    - Replaces the stock push logic, which swallows the first two push
      attempts and only surfaces a confusing "no upstream branch" error, with
      one that logs each attempt and raises a message naming the actual fixes.
    """
    from git_wiki_builder.publisher import WikiPublisher

    orig_clone = WikiPublisher._clone_wiki_repository

    def clone_with_token(self, wiki_repo_path):
        token = os.environ.get("WIKI_TOKEN") or self.config.github_token
        prev = self.config.github_token
        self.config.github_token = token  # the stock URL builder reads this
        try:
            return orig_clone(self, wiki_repo_path)
        finally:
            self.config.github_token = prev

    def commit_and_push(self, repo, wiki_content):
        repo.git.add(".")
        if not (repo.is_dirty() or repo.untracked_files):
            log.info("no changes to commit")
            return

        message = self._generate_commit_message(wiki_content)
        repo.index.commit(message)
        log.info(f"Committed changes: {message}")

        origin = repo.remote("origin")
        last_error = None
        # GitHub wikis use `master` (legacy) or `main`; try both, logged.
        for branch in ("master", "main"):
            try:
                origin.push(refspec=f"HEAD:refs/heads/{branch}")
                log.info(f"Pushed changes to {branch}")
                return
            except Exception as error:  # noqa: BLE001 — log and try next branch
                last_error = error
                log.warning(f"push to wiki branch `{branch}` failed: {error}")
        raise RuntimeError(
            "Wiki push failed on both `master` and `main`. Likely causes:\n"
            "  1. The Actions GITHUB_TOKEN cannot push to the separate "
            "<repo>.wiki.git repository (GitHub platform rule). Add a repo "
            "secret `WIKI_TOKEN` (classic PAT with `repo` scope, or "
            "fine-grained PAT with Contents: read and write) and expose it to "
            "the job as WIKI_TOKEN (see .github/workflows/update-wiki.yml).\n"
            "  2. The wiki feature is off or the wiki was never initialized: "
            "enable Settings -> General -> Features -> Wikis and create one "
            "stub page on the wiki tab so the .wiki.git repo exists.\n"
            f"  Last git error: {last_error}"
        )

    WikiPublisher._clone_wiki_repository = clone_with_token
    WikiPublisher._commit_and_push_changes = commit_and_push

    token = os.environ.get("WIKI_TOKEN")
    if token:
        print("[generate-wiki] using WIKI_TOKEN (PAT) for wiki publishing")
    else:
        print("[generate-wiki] WIKI_TOKEN unset — using GITHUB_TOKEN for wiki "
              "publishing (may 403; add a PAT secret if the push fails)")


def main() -> None:
    patch_wiki_structure()
    patch_ai_client()
    patch_wiki_publisher()

    from git_wiki_builder.cli import main as cli_main

    cli_main()  # click consumes sys.argv[1:], so flags pass through


if __name__ == "__main__":
    main()