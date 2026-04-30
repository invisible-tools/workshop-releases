---
name: setup
description: Install (if needed) and start Workshop on the user's machine. Idempotent — safe to re-run.
---

Get Workshop running on the user's machine. Once it's up, the plugin is already connected via MCP — the user can start debugging traces immediately with `/workshop:debug`.

The flow is: probe → install if missing → start daemon → open the UI.

## Steps

**1. Probe.** Run `curl -sf http://localhost:5899/health` via Bash. If it exits 0, Workshop is already running — skip to step 4.

**2. Install if missing.** Check whether the binary is installed:

```bash
test -x "$HOME/.workshop/bin/workshop"
```

If the binary doesn't exist, run the official installer:

```bash
curl -fsSL https://raw.githubusercontent.com/invisible-tools/workshop-releases/main/install.sh | bash
```

The installer is idempotent — re-running on a current install just no-ops with a "already up to date" message. It downloads the latest binary for the user's platform, sha256-verifies it, and atomically installs to `$HOME/.workshop/bin/workshop`.

If the install script exits non-zero, stop and report the error to the user verbatim — don't loop. Common failure modes: no internet, GitHub rate-limited, unsupported platform (Windows isn't supported yet).

**3. Start the daemon.**

```bash
"$HOME/.workshop/bin/workshop" start
```

This spawns Workshop detached, writes a pid file at `~/.workshop/workshop.pid`, tails logs to `~/.workshop/workshop.log`, and waits up to 5s for `/health` before reporting ready. It's idempotent — re-running on an already-healthy port just prints "already running."

If `workshop start` exits non-zero, stop and tell the user what to check (port 5899 already in use, conflicting daemon, etc.) — don't loop.

**4. Open the UI.** Platform-detect:

- macOS: `open http://localhost:5899`
- Linux: `xdg-open http://localhost:5899`
- Windows: `start http://localhost:5899`

A failure here isn't fatal; just print the URL instead.

**5. Print the success message.** Tell the user exactly this:

> Workshop is running at http://localhost:5899. The plugin is already connected — point an instrumented agent at `http://localhost:5899/v1/` (via `RAINDROP_LOCAL_DEBUGGER`), then run `/workshop:debug` on a trace.

## Optional: bidirectional chat (channels)

The Workshop UI has a message pane that can send text back to Claude Code. It's off by default — the MCP plugin is fully usable without it. Enable only if the user asks, and only if their Claude Code session is authenticated via a claude.ai account (API-key auth can't use channels — this is a Claude Code policy, not a Workshop limitation).

If the user wants it, tell them:

> The message pane on the right of the UI can talk back to Claude Code, but only if you start Claude Code with a flag and you're signed into a claude.ai account.
>
> In a **new terminal** (this session is already attached to one stdio, it can't also be the channel), run:
>
> ```
> claude --dangerously-load-development-channels plugin:workshop@raindrop
> ```
>
> If that errors with "plugin not found," use the bare-server form:
>
> ```
> claude --dangerously-load-development-channels server:workshop
> ```
>
> The connection indicator in the UI turns green when the channel connects.

**Why `--dangerously-load-development-channels`?** During the Claude Code channels research preview, only the Anthropic-curated plugins (telegram, discord, imessage, fakechat) are on the `--channels` allowlist. Every other channel plugin must use the dev flag to load. This only affects which channels register at launch; it doesn't change how the plugin or its MCP tools work.

## Notes

- Re-running this skill is safe. The probe in step 1 short-circuits if Workshop is already up.
- The installer URL is treated as a stable customer-facing API — if the user has seen it elsewhere (README, docs), it's the same URL.
- Do not try to spawn `claude --channels …` yourself — it has to run in a terminal the user controls.
