#!/usr/bin/env python3
"""Build-time privacy guard for the patcher's per-run usage statistics.

This is a static, source-level audit. It complements the UsageTelemetryTests and
checks the product guarantees that are easy to accidentally regress:

* nothing is sent automatically;
* the only send action is the user's explicit choice in the post-patch dialog;
* the dialog shows the exact payload before sending;
* only completed patch runs and allowlisted fields can be reported.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
TELEMETRY = APP / "Sources/FineWinePatcher/UsageTelemetry.swift"
ENGINE = APP / "Sources/FineWinePatcher/PatcherEngine.swift"
SETUP = APP / "Sources/FineWinePatcher/AutomatedSetup.swift"
SETUP_VIEW = APP / "Sources/FineWinePatcher/AutomatedSetupView.swift"
REDACTOR = APP / "Sources/FineWinePatcher/LogRedactor.swift"
CONTENT = APP / "Sources/FineWinePatcher/ContentView.swift"
PROMPT = APP / "Sources/FineWinePatcher/PatchTelemetryPromptView.swift"
THANKYOU = APP / "Sources/FineWinePatcher/TelemetryThankYouView.swift"
README = APP / "README.md"
SOURCES = APP / "Sources/FineWinePatcher"

failures: list[str] = []


def check(condition: bool, description: str) -> None:
    if condition:
        print(f"  PASS  {description}")
    else:
        print(f"  FAIL  {description}", file=sys.stderr)
        failures.append(description)


def block(text: str, start: str, end: str) -> str:
    match = re.search(re.escape(start) + r"(.*?)" + re.escape(end), text, re.S)
    return match.group(1) if match else ""


def swift_strings(value: str) -> set[str]:
    return set(re.findall(r'"([^"]+)"', value))


telemetry = TELEMETRY.read_text(encoding="utf-8")
engine = ENGINE.read_text(encoding="utf-8")
setup = SETUP.read_text(encoding="utf-8")
setup_view = SETUP_VIEW.read_text(encoding="utf-8")
redactor = REDACTOR.read_text(encoding="utf-8")
content = CONTENT.read_text(encoding="utf-8")
prompt = PROMPT.read_text(encoding="utf-8")
thanks = THANKYOU.read_text(encoding="utf-8")
readme = README.read_text(encoding="utf-8")
all_sources = "\n".join(p.read_text(encoding="utf-8") for p in SOURCES.glob("*.swift"))

print("Telemetry privacy audit")

# 1. No persistent toggle and no automatic launch/event recording.
check("finewine.statistics.enabled" not in all_sources, "there is no persistent telemetry toggle")
check("recordAppLaunch" not in all_sources, "there is no automatic app-launch reporting")
check("UsageTelemetry.record(" not in all_sources, "there are no automatic telemetry event calls")
check(
    "Toggle(\"Share anonymous usage statistics" not in content,
    "the main page has no telemetry checkbox",
)

# 2. A prompt is created for both outcomes of a patch run, and only then.
check(
    "makePatchPrompt(\n                    succeeded: true" in engine,
    "successful patch runs create a send prompt",
)
check(
    "makePatchPrompt(\n                    succeeded: false" in engine,
    "failed patch runs create a send prompt",
)
check(engine.count("self.telemetryPrompt = promptToSend") == 2, "both patch outcomes set the prompt")
check(
    "telemetryPrompt = nil" in block(engine, "func reset() {", "\n    }"),
    "starting a new patch clears any stale prompt",
)

# 3. The only network send is the user's explicit choice in the prompt.
send_calls = re.findall(r"UsageTelemetry\.send\(([^)]*)\)", all_sources)
check(
    send_calls == ["prompt", "prompt"],
    "the only send calls are the two user-confirmed Send Statistics actions",
)
check("onSend: { UsageTelemetry.send(prompt) }" in content,
      "the patch prompt's Send Statistics is wired to the dialog choice")
check("onSend: { UsageTelemetry.send(prompt) }" in setup_view,
      "the setup prompt's Send Statistics is wired to the dialog choice")
check("UsageTelemetry.send" not in prompt, "the prompt view itself cannot send before a choice")
check("UsageTelemetry.send" not in engine, "the patch engine never sends automatically")
check("UsageTelemetry.send" not in setup, "the setup engine never sends automatically")

# 4. Endpoint and event/metadata allowlists.
check(
    'URL(string: "https://endfield-fine-wine.lovable.app/api/statistics")!' in telemetry,
    "statistics endpoint uses HTTPS",
)
events_block = re.search(r"allowedEvents: Set<String> = \[(.*?)\]", telemetry, re.S).group(1)
allowed_events = swift_strings(events_block)
check(
    allowed_events == {"patch_succeeded", "patch_failed", "setup_succeeded", "setup_failed"},
    "only completed patch and setup outcomes are allowed",
)
metadata_block = re.search(
    r"allowedMetadataKeys: Set<String> = \[(.*?)\]", telemetry, re.S
).group(1)
allowed_metadata = swift_strings(metadata_block)
check(
    allowed_metadata == {
        "gptk", "duration_seconds", "failed_step", "cross_over_build",
        "setup_backend", "setup_msync", "setup_msync_fallback", "setup_upscaling",
        "installer_status",
    },
    "telemetry metadata allowlist is exact",
)
check(
    "metadata.filter { allowedMetadataKeys.contains($0.key) }" in telemetry,
    "unknown metadata keys are dropped before sending",
)
check(
    "guard allowedEvents.contains(prompt.event) else { return }" in telemetry,
    "unknown event names are rejected before sending",
)

# 5. The event schema must stay deliberately small.
event_struct = block(telemetry, "private struct Event: Encodable {", "\n    }")
event_fields = set(re.findall(r"let\s+([A-Za-z_][A-Za-z0-9_]*)", event_struct))
check(
    event_fields == {"app", "event", "count", "appVersion", "osMajor", "metadata", "logs"},
    "event payload contains only the approved fields",
)
forbidden_terms = {
    "path", "file", "bottle", "user", "username", "email", "host", "hostname",
    "serial", "machine", "token", "password", "secret", "cookie", "ip",
}
check(
    not any(term in event_struct.lower() for term in forbidden_terms),
    "event payload contains no path/account/machine identifier fields",
)

# 6. The dialog must explain the ask, show the exact payload, and default to not sending.
check("Send anonymous statistics for this" in prompt, "dialog title asks about this patch run")
check("This report is optional" in prompt, "dialog explains that the report is optional")
check("Nothing has been sent yet" in prompt, "dialog states nothing was sent automatically")
check("prioritise compatibility and performance fixes" in prompt, "dialog explains how the data helps")
check("Preview — exactly what would be sent" in prompt, "dialog shows the exact payload before sending")
check("prompt.json" in prompt, "dialog preview uses the same payload encoder")
check('Button("Don\'t Send")' in prompt and 'Button("Send Statistics")' in prompt,
      "dialog offers explicit Send and Don't Send choices")
check("No file paths" in prompt, "patch dialog lists what is never sent")
check("automatically redacted" in prompt, "setup dialog says the logs are redacted")
check("review the preview before sending" in prompt, "setup dialog asks the user to review the preview")
check("source IP" in prompt or "your IP address" in prompt, "dialog discloses ordinary network metadata")

# 6b. Automated Setup reports include redacted logs, and only through the same dialog.
check(
    "makeSetupPrompt(\n                    succeeded: !failed" in setup,
    "successful setup runs create a send prompt",
)
check(
    "makeSetupPrompt(\n                    succeeded: false" in setup,
    "failed setup runs create a send prompt",
)
check(setup.count("self.telemetryPrompt = prompt") == 2, "both setup outcomes set the prompt")
check(
    "telemetryPrompt = nil" in block(setup, "func reset() {", "\n    }"),
    "starting a new setup clears any stale prompt",
)
check(
    "if let prompt = setup.telemetryPrompt" in setup_view
    and "PatchTelemetryPromptView(" in setup_view,
    "the setup prompt is the wizard's final screen",
)
check(
    "if let prompt = engine.telemetryPrompt" in content,
    "the patch prompt is presented after the result window",
)
check(
    "reportTelemetry: false" in setup_view,
    "an Automated Setup run asks once at the end instead of prompting twice",
)
check(
    "showPatchTelemetry = true" in content and "engine.telemetryPrompt = nil" in content,
    "the patch report can only be sent from the user-confirmed dialog",
)
check(
    "LogRedactor.live(" in telemetry and "LogRedactor.excerpts(logs: logs, redactor: redactor)" in telemetry,
    "setup logs pass through the redactor before the preview is built",
)
check(
    "logs: excerpts" in telemetry,
    "setup prompts carry only the redacted excerpts",
)
check(
    "logs.isEmpty ? nil : logs" in telemetry,
    "patch prompts never carry a logs field",
)
for marker in [
    "/Users/", "drive_c", "Bearer", "Registered to",
    "[A-Za-z0-9._%+-]+@", "<uuid>", "<hash>", "<ip>", "<mac>",
]:
    check(marker in redactor, f"redactor covers {marker}")

# 7. Sending must lead to a thank-you celebration rather than closing immediately.
check("if sent {" in prompt and "TelemetryThankYouView" in prompt,
      "Send Statistics transitions to the thank-you view")
check("NSPasteboard" not in thanks and "UsageTelemetry.send" not in thanks,
      "thank-you view cannot send data")
check("Thank you!" in thanks, "thank-you dialog thanks the contributor")
check("sincerely appreciate" in thanks, "thank-you dialog expresses appreciation")
check("CelebrationConfetti" in thanks, "thank-you dialog includes confetti")
check("ConfettiPiece.makePieces()" in thanks and ".animation(" in thanks,
      "confetti celebration is animated")

# 8. The user-facing copy and README must describe the per-run prompt.
check("never sent automatically" in content, "footer says statistics are never sent automatically")
check("after each patch or automated setup run" in content.lower(),
      "footer says the prompt follows each patch and setup run")
check("## Per-run anonymous usage statistics" in readme, "README has a per-run privacy section")
check("**Why this helps.**" in readme, "README explains how the data improves compatibility")
check("**What is collected.**" in readme, "README documents the collected fields")
check("**What is never sent.**" in readme, "README documents what is never sent")
check("Preview — exactly what would be sent" in readme, "README explains the in-dialog preview")
check("thank-you dialog" in readme.lower(), "README documents the thank-you celebration")
check("nothing is sent automatically" in " ".join(readme.lower().split()),
      "README says nothing is sent automatically")
check("source IP address" in readme, "README discloses ordinary network metadata")

if failures:
    print(f"\nPrivacy audit failed with {len(failures)} error(s).", file=sys.stderr)
    sys.exit(1)

print("\nPrivacy audit passed: statistics are per-run, previewed, and user-confirmed.")
