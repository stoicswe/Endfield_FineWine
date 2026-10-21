#!/usr/bin/env python3
"""Post a FineWine release / nightly thread to Bluesky.

The thread's first post is always the same template:

    Type: Release            (or Nightly)
    Version: 1.2.6
    Build time: 1h 12m 4s    (pipeline start -> this step; docs/wiki are separate workflows)

    Download: https://github.com/<owner>/<repo>/releases/tag/<tag>

Every following post carries the run's description: the generated release notes for a full
release, or the commit list for a nightly. Long bodies are split into <=300-character posts.

Configuration (all read from the environment):

    BLUESKY_HANDLE          account handle, e.g. endfield-finewine.bsky.social  [repo variable]
    BLUESKY_APP_PASSWORD    app password from Settings -> App Passwords          [repo secret]
    BLUESKY_PDS             optional PDS base URL (default https://bsky.social) [repo variable]

    THREAD_TYPE             "Release" or "Nightly"
    VERSION                 version string for the first post
    PIPELINE_STARTED_EPOCH  unix seconds when the workflow started (used to compute build time)
    BUILD_TIME              optional pre-formatted build time; overrides PIPELINE_STARTED_EPOCH
    DOWNLOAD_URL            release page URL
    BODY_FILE               file with the description / commit list for the replies
    BLUESKY_MAX_POSTS       maximum thread length including the root post (default 20)
    BLUESKY_DRY_RUN         "1" prints the thread without contacting Bluesky

A Bluesky failure must never turn a successful release red, so this script warns and exits 0 once
the retries are exhausted (matching the Discord announcement's behaviour).
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

POST_LIMIT = 295  # Bluesky's hard limit is 300 graphemes; stay under it
ATTEMPTS = 3
BACKOFF_SECONDS = (5, 15, 30)
DEFAULT_PDS = "https://bsky.social"
POST_COLLECTION = "app.bsky.feed.post"
URL_RE = re.compile(r"https?://[^\s<>\[\]{}]+")


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def build_time() -> str:
    given = env("BUILD_TIME")
    if given:
        return given
    start = env("PIPELINE_STARTED_EPOCH")
    if not start.isdigit():
        return "unknown"
    seconds = max(0, int(time.time()) - int(start))
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return f"{hours}h {minutes}m {secs}s"
    if minutes:
        return f"{minutes}m {secs}s"
    return f"{secs}s"


def root_text() -> str:
    return "\n".join(
        [
            f"Type: {env('THREAD_TYPE') or 'Release'}",
            f"Version: {env('VERSION') or 'unknown'}",
            f"Build time: {build_time()}",
            "",
            f"Download: {env('DOWNLOAD_URL') or ''}".rstrip(),
        ]
    )


def read_body() -> str:
    path = env("BODY_FILE")
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError as error:
        print(f"::warning::could not read {path}: {error}", file=sys.stderr)
        return ""


def facets_for(text: str) -> list[dict]:
    """Link facets so Bluesky renders URLs as clickable links (the API does not auto-link)."""
    facets = []
    for match in URL_RE.finditer(text):
        url = match.group(0).rstrip(".,;:!?)\"'")
        end = match.start() + len(url)
        start_byte = len(text[: match.start()].encode("utf-8"))
        end_byte = len(text[:end].encode("utf-8"))
        facets.append(
            {
                "index": {"byteStart": start_byte, "byteEnd": end_byte},
                "features": [
                    {"$type": "app.bsky.richtext.facet#link", "uri": url}
                ],
            }
        )
    return facets


def chunk_text(text: str, limit: int = POST_LIMIT) -> list[str]:
    """Split Markdown-ish text into posts, preserving paragraph breaks where possible."""
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        return []

    chunks: list[str] = []
    current = ""

    def flush() -> None:
        nonlocal current
        if current.strip():
            chunks.append(current.strip())
        current = ""

    for block in text.split("\n"):
        if len(block) <= limit:
            if not current:
                current = block
            elif len(current) + 1 + len(block) <= limit:
                current += "\n" + block
            else:
                flush()
                current = block
            continue

        # A single long line (e.g. a wrapped commit subject): wrap it on spaces.
        for word in block.split(" "):
            while len(word) > limit:
                flush()
                chunks.append(word[:limit])
                word = word[limit:]
            if not current:
                current = word
            elif len(current) + 1 + len(word) <= limit:
                current += " " + word
            else:
                flush()
                current = word
    flush()
    return chunks


def request_json(url: str, payload: dict | None, token: str | None = None,
                 method: str = "POST") -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)

    last_error: Exception | None = None
    for attempt in range(ATTEMPTS):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.loads(response.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            last_error = RuntimeError(f"HTTP {error.code} from {url}: {detail}")
            # 4xx (bad credentials, invalid record) will not fix itself; retry only 429/5xx.
            if error.code != 429 and error.code < 500:
                break
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = error
        if attempt + 1 < ATTEMPTS:
            time.sleep(BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)])
    raise RuntimeError(f"request to {url} failed: {last_error}")


def create_post(pds: str, token: str, did: str, text: str, reply: dict | None = None) -> dict:
    record: dict = {
        "$type": POST_COLLECTION,
        "text": text,
        "createdAt": now_iso(),
        "langs": ["en"],
    }
    facets = facets_for(text)
    if facets:
        record["facets"] = facets
    if reply:
        record["reply"] = reply
    return request_json(
        f"{pds}/xrpc/com.atproto.repo.createRecord",
        {"repo": did, "collection": POST_COLLECTION, "record": record},
        token=token,
    )


def main() -> int:
    handle = env("BLUESKY_HANDLE").lstrip("@")
    password = env("BLUESKY_APP_PASSWORD")
    pds = (env("BLUESKY_PDS") or DEFAULT_PDS).rstrip("/")
    dry_run = env("BLUESKY_DRY_RUN") == "1"

    root = root_text()
    body = read_body()
    replies = chunk_text(body)
    max_posts = max(1, int(env("BLUESKY_MAX_POSTS") or "20"))
    if len(replies) > max_posts - 1:
        print(
            f"::warning::thread body has {len(replies)} posts; posting the first {max_posts - 1}",
            file=sys.stderr,
        )
        replies = replies[: max_posts - 1]

    if dry_run:
        print("== root ==")
        print(root)
        for index, reply in enumerate(replies, start=1):
            print(f"== reply {index} ==")
            print(reply)
        return 0

    if not handle or not password:
        print("Bluesky is not configured (BLUESKY_HANDLE / BLUESKY_APP_PASSWORD) — skipping.")
        return 0

    try:
        session = request_json(
            f"{pds}/xrpc/com.atproto.server.createSession",
            {"identifier": handle, "password": password},
        )
        token = session["accessJwt"]
        did = session["did"]
        print(f"Bluesky session for {handle} ({did})")

        created = create_post(pds, token, did, root)
        print(f"posted root {created.get('uri')}")
        root_ref = {"uri": created["uri"], "cid": created["cid"]}
        parent_ref = root_ref
        for index, reply in enumerate(replies, start=1):
            created = create_post(
                pds, token, did, reply, reply={"root": root_ref, "parent": parent_ref}
            )
            parent_ref = {"uri": created["uri"], "cid": created["cid"]}
            print(f"posted reply {index} {created.get('uri')}")
    except Exception as error:  # noqa: BLE001 — a notification must not fail the release
        print(f"::warning::Bluesky announcement failed: {error}", file=sys.stderr)
        return 0

    print(f"Bluesky thread published ({1 + len(replies)} posts)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
