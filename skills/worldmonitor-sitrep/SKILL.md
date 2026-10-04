---
name: worldmonitor-sitrep
description: Produce a situation report from the World Monitor MCP tools and keep the previous run's snapshot so "what changed" is a real diff, not a guess.
version: 1.0.0
metadata:
  openclaw:
    emoji: "🌍"
    requires:
      mcp:
        - worldmonitor
---

# World Monitor SITREP

## When to use this skill

- When a scheduled job or a user asks for a situation report, SITREP, "what changed",
  or an hourly/daily summary from World Monitor.
- When asked whether a theater, chokepoint, or country advisory has *changed* — a
  question that needs the previous state, not just the current one.

## The snapshot file

The previous run's state lives at `sitrep/last-snapshot.json` in the workspace.
It is a single JSON object:

```json
{
  "capturedAt": "2026-10-04T16:25:00Z",
  "theaters":   { "IRAN": "NORM", "BALTIC": "ELEV" },
  "chokepoints":{ "Strait of Hormuz": "elevated" },
  "advisories": { "IQ": "do-not-travel", "UA": "do-not-travel" },
  "focalPoints":["Russia", "Iran"]
}
```

## Rules

1. **Read the snapshot FIRST.** If the file is missing, this is the first run: say so
   in one line, report the current state without claiming anything changed, and
   write the snapshot. Do not invent a previous state.
2. Gather current values with the `worldmonitor` tools. Normalize them into the same
   shape as the snapshot (theater → posture, chokepoint name → status, ISO2 → level,
   focal point names).
3. **Diff mechanically**: a change is a key whose value differs, a key that is new, or
   a key that disappeared. Report only those. Never describe a change the diff did
   not show.
4. **Write the new snapshot** to `sitrep/last-snapshot.json` (overwrite) before
   replying — including on a NO_REPLY run, so the baseline keeps moving forward.
5. If a tool call fails, say which one and report the rest; do not treat a missing
   value as a change.
6. Cite the World Monitor data timestamp, not the wall clock, so a stale seed is
   visible to the reader.
