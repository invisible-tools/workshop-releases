---
name: setup
description: Run this first after installing the raindrop plugin. Installs the raindrop binary if missing, runs `raindrop workshop init` (which writes RAINDROP_LOCAL_DEBUGGER into the project's ./.env, starts the daemon at http://localhost:5899, and opens the UI), then tells the user what to do next. Idempotent — safe to re-run any time the daemon might be down or to re-bootstrap a project.
---

Get the user from "I just installed the plugin" to "I'm debugging traces in a UI" in one skill. The single command that does the heavy lifting is `raindrop workshop init`; this skill is mostly a wrapper that handles the binary-not-yet-installed case and prints the next-steps message.

The flow is: probe → install binary if missing → run `raindrop workshop init` → print success message.

## Steps

**1. Probe.** Run `curl -sf http://localhost:5899/health` via Bash. If it exits 0, the daemon is already running — skip ahead to step 3 with `raindrop workshop init` so the project's `.env` still gets bootstrapped, and the existing daemon stays untouched.

**2. Install the binary if missing.** Check whether the binary is installed:

```bash
test -x "$HOME/.raindrop/bin/raindrop"
```

If the binary doesn't exist, run the official installer:

```bash
curl -fsSL https://raw.githubusercontent.com/invisible-tools/workshop-releases/main/install.sh | bash
```

The installer is idempotent — re-running on a current install just overwrites with the same version. It downloads the latest binary for the user's platform, sha256-verifies it, and atomically installs to `$HOME/.raindrop/bin/raindrop`.

If the install script exits non-zero, stop and report the error to the user verbatim — don't loop. Common failure modes: no internet, GitHub rate-limited, unsupported platform (Windows isn't supported yet).

**3. Run `raindrop workshop init`.**

```bash
"$HOME/.raindrop/bin/raindrop" workshop init
```

This single command:

- Writes `RAINDROP_LOCAL_DEBUGGER=http://localhost:5899/v1/` into `./.env` (idempotent; will not clobber an existing different value without `--force`).
- Spawns the daemon detached, writes a pid file at `~/.raindrop/raindrop_workshop.pid`, tails logs to `~/.raindrop/raindrop_workshop.log`, and waits up to 5s for `/health` before reporting ready.
- Opens the UI in the user's default browser.

If init exits non-zero, stop and tell the user what to check (port 5899 already in use; an existing `RAINDROP_LOCAL_DEBUGGER` line in `./.env` pointing somewhere else — if that's the case, suggest `raindrop workshop init --force`). Don't loop.

**4. Print the success message.** Tell the user exactly this (verbatim, no paraphrasing — this is also the user's first introduction to what the plugin can do):

> Raindrop Workshop is running at http://localhost:5899 and the plugin is connected.
>
> Your project's `.env` now has `RAINDROP_LOCAL_DEBUGGER=http://localhost:5899/v1/`. Any agent in this project that uses an `@raindrop-ai/*` SDK will stream traces here automatically — just run it.
>
> **What you can do now:**
>
> - **`/raindrop:debug-traces`** — read, reason about, and annotate any trace open in Workshop. The plugin's primary skill.
> - **`/raindrop:add-readonly-replay`** — wire your agent so Workshop's "Local Agent" replay mode can safely run your real agent code against a captured trace.
>
> **Daemon controls** (rarely needed; init handles them):
>
> - `raindrop workshop` — start the daemon if it's down and re-open the UI.
> - `raindrop workshop status` / `stop` — inspect / shut it down.
>
> Re-run `/raindrop:setup` any time you want to bootstrap another project, or after a reboot.

Don't summarize this list, don't drop bullets, don't reword the slash commands. Users discover the rest of the plugin from this message.

## Optional: bidirectional chat (channels)

The Workshop UI has a message pane that can send text back to Claude Code. It's off by default — the MCP plugin is fully usable without it. Enable only if the user asks, and only if their Claude Code session is authenticated via a claude.ai account (API-key auth can't use channels — this is a Claude Code policy, not a product limitation).

If the user wants it, tell them:

> The message pane on the right of the UI can talk back to Claude Code, but only if you start Claude Code with a flag and you're signed into a claude.ai account.
>
> In a **new terminal** (this session is already attached to one stdio, it can't also be the channel), run:
>
> ```
> claude --dangerously-load-development-channels plugin:raindrop@workshop
> ```
>
> If that errors with "plugin not found," use the bare-server form:
>
> ```
> claude --dangerously-load-development-channels server:raindrop
> ```
>
> The connection indicator in the UI turns green when the channel connects.

**Why `--dangerously-load-development-channels`?** During the Claude Code channels research preview, only the Anthropic-curated plugins (telegram, discord, imessage, fakechat) are on the `--channels` allowlist. Every other channel plugin must use the dev flag to load. This only affects which channels register at launch; it doesn't change how the plugin or its MCP tools work.

## Notes

- Re-running this skill is safe. `raindrop workshop init` is idempotent — same line in `.env` is a no-op, daemon-already-running is a no-op.
- The installer URL is treated as a stable customer-facing API — if the user has seen it elsewhere (README, docs), it's the same URL.
- Do not try to spawn `claude --channels …` yourself — it has to run in a terminal the user controls.
