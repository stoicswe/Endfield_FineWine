#!/usr/bin/env python3
"""Post a published FineWine release to Discord as a role-pinged announcement.

Two transports are supported; the bot is preferred when configured:

  Bot (recommended) — needs both:
    DISCORD_BOT_TOKEN     bot token from the Developer Portal (Bot tab)
    DISCORD_CHANNEL_ID    channel to post in

  Webhook (fallback) — used when the bot pair is not set:
    DISCORD_WEBHOOK_URL   channel webhook URL

Message content (environment):

    DISCORD_ROLE_ID        role to ping, e.g. 123456789012345678 (optional)
    ANNOUNCE_TITLE         release title, e.g. "Endfield FineWine 1.0.1"
    ANNOUNCE_URL           release page URL
    ANNOUNCE_VERSION       version string
    ANNOUNCE_CX_VER        required CrossOver version
    ANNOUNCE_SHA           commit the release was built from
    ANNOUNCE_SUMMARY_PATH  Markdown summary (written by generate-release-notes.py)

With a bot, a message posted to an Announcement channel (type 5) is also
crossposted, so it notifies every channel following it. With a webhook that is
not possible (crossposting requires bot auth).

Role pings: a webhook can only ping a role that has "Allow anyone to @mention
this role" enabled. A bot with the "Mention @everyone, @here, and All Roles"
permission can ping non-mentionable roles. `allowed_mentions` only filters
mentions; it does not grant permission to make them.

A Discord failure must never turn a successful release red, so this script warns
and exits 0 once retries are exhausted.
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
EMBED_DESCRIPTION_LIMIT = 3900  # Discord hard limit is 4096; leave headroom
CONTENT_LIMIT = 1900
COLOR_WINE = 0x7B2D3B
DEFAULT_SUMMARY = "A new Endfield FineWine build is available."
DISCORD_API = "https://discord.com/api/v10"
ANNOUNCEMENT_CHANNEL_TYPE = 5


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def read_summary(path: str) -> str:
    if not path:
        return DEFAULT_SUMMARY
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read().strip()
    except OSError as error:
        print(f"::warning::could not read {path}: {error}", file=sys.stderr)
        return DEFAULT_SUMMARY
    return text or DEFAULT_SUMMARY


def truncate(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def build_payload() -> dict:
    role_id = env("DISCORD_ROLE_ID")
    title = env("ANNOUNCE_TITLE") or "Endfield FineWine"
    url = env("ANNOUNCE_URL")
    version = env("ANNOUNCE_VERSION")
    cx_ver = env("ANNOUNCE_CX_VER")
    sha = env("ANNOUNCE_SHA")

    mention = f"<@&{role_id}> " if role_id else ""
    content = truncate(f"{mention}🍷 **{title}** is out!", CONTENT_LIMIT)

    fields = []
    if version:
        fields.append({"name": "Version", "value": f"`{version}`", "inline": True})
    if cx_ver:
        fields.append(
            {"name": "Requires CrossOver", "value": f"`{cx_ver}`", "inline": True}
        )

    embed = {
        "title": title,
        "description": truncate(read_summary(env("ANNOUNCE_SUMMARY_PATH")),
                                EMBED_DESCRIPTION_LIMIT),
        "color": COLOR_WINE,
        "fields": fields,
    }
    if url:
        embed["url"] = url
    if sha:
        embed["footer"] = {"text": f"Built from {sha[:8]}"}

    return {
        "content": content,
        "embeds": [embed],
        # Explicit allowlist: ping only the release role, never @everyone/@here.
        "allowed_mentions": {"parse": [], "roles": [role_id]} if role_id else {"parse": []},
    }


def request_json(
    method: str,
    url: str,
    *,
    token: str = "",
    payload: dict | None = None,
    timeout: int = 30,
) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "EndfieldFineWine-ReleaseBot/1.0",
    }
    if token:
        headers["Authorization"] = f"Bot {token}"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode("utf-8")
    return json.loads(body) if body else {}


def send_with_bot(*, token: str, channel_id: str, payload: dict) -> dict:
    # Channel type tells us whether the message can/should be crossposted.
    channel = request_json("GET", f"{DISCORD_API}/channels/{channel_id}", token=token)
    message = request_json(
        "POST",
        f"{DISCORD_API}/channels/{channel_id}/messages",
        token=token,
        payload=payload,
    )
    print(f"[discord] posted message {message.get('id', '<unknown>')}")

    if channel.get("type") == ANNOUNCEMENT_CHANNEL_TYPE and message.get("id"):
        try:
            request_json(
                "POST",
                f"{DISCORD_API}/channels/{channel_id}/messages/{message['id']}/crosspost",
                token=token,
                payload={},
            )
            print("[discord] crossposted to channels following this announcement channel")
        except Exception as error:  # noqa: BLE001 — crosspost is best-effort
            print(
                f"::warning::message posted but crosspost failed "
                f"(Manage Messages / Send Messages permission?): {error}",
                file=sys.stderr,
            )
    return message


def send_with_webhook(*, webhook_url: str, payload: dict) -> dict:
    message = request_json(
        "POST",
        webhook_url + "?wait=true",
        payload=payload,
    )
    print(f"[discord] posted message {message.get('id', '<unknown>')}")
    return message


def describe(error: Exception) -> str:
    if isinstance(error, urllib.error.HTTPError):
        code = error.code
        hint = {
            400: "malformed payload (usually a bad role ID or channel ID)",
            401: "invalid bot token",
            403: "the bot cannot post here — grant View Channel, Send Messages, "
                 "Embed Links and (for non-mentionable roles) Mention Everyone",
            404: "unknown channel — check DISCORD_CHANNEL_ID and that the bot is "
                 "in the server",
            429: "rate limited",
        }.get(code, "")
        try:
            detail = error.read().decode("utf-8", "replace")[:600]
        except Exception:  # noqa: BLE001
            detail = ""
        return f"HTTP {code}{f' ({hint})' if hint else ''}: {detail}".strip()
    return str(error)


def post(payload: dict) -> None:
    token = env("DISCORD_BOT_TOKEN")
    channel_id = env("DISCORD_CHANNEL_ID")
    webhook_url = env("DISCORD_WEBHOOK_URL")

    if token and channel_id:
        transport = "bot"
        def send() -> dict:
            return send_with_bot(token=token, channel_id=channel_id, payload=payload)
    elif webhook_url:
        transport = "webhook"
        def send() -> dict:
            return send_with_webhook(webhook_url=webhook_url, payload=payload)
    else:
        print("[discord] no bot token/channel or webhook configured — skipping")
        return

    print(f"[discord] transport: {transport}")

    last_error: Exception | None = None
    for attempt in range(1, ATTEMPTS + 1):
        try:
            send()
            return
        except urllib.error.HTTPError as error:
            last_error = error
            if error.code == 429:
                wait = BACKOFF_SECONDS[attempt - 1]
                try:
                    wait = float(json.loads(error.read().decode("utf-8"))
                                 .get("retry_after", wait))
                except Exception:  # noqa: BLE001
                    pass
                print(
                    f"::warning::discord rate limited, retrying in {wait}s",
                    file=sys.stderr,
                )
                time.sleep(min(wait, 60))
                continue
            if error.code < 500:
                break  # 4xx other than 429 will not succeed on retry
        except Exception as error:  # noqa: BLE001 — network failures vary
            last_error = error

        if attempt < ATTEMPTS:
            wait = BACKOFF_SECONDS[attempt - 1]
            print(
                f"::warning::discord post attempt {attempt}/{ATTEMPTS} failed, "
                f"retrying in {wait}s: {describe(last_error)}",
                file=sys.stderr,
            )
            time.sleep(wait)

    print(
        f"::warning::discord announcement was not posted after {ATTEMPTS} attempts: "
        f"{describe(last_error) if last_error else 'unknown error'}",
        file=sys.stderr,
    )


def main() -> int:
    payload = build_payload()
    print(f"[discord] announcing: {payload['content']}")
    post(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
