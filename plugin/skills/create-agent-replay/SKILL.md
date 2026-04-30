---
name: create-agent-replay
description: Set up a Local Agent replay endpoint for the trace the user is currently viewing in Workshop. Scaffolds the Express server in the agent's repo, registers it in ~/.workshop/agents.json, and makes the UI's "Local Agent" mode live.
---

Wire the agent that produced the currently-viewed trace up for **Local Agent** replay — so clicking Replay → Local Agent in Workshop runs the real agent against the captured inputs, not a tool-mock.

The user triggers this by clicking the greyed-out Local Agent mode in the Replay dropdown and following the tooltip, or by running `/workshop:create-agent-replay` directly. Either way, you're running **in the agent's repo**, not Workshop's — so all file edits go into the user's codebase.

## Prerequisites

1. **Workshop is running.** If `get_viewed_run` errors with "Workshop backend unreachable," stop and tell the user to run `/workshop:setup` first.
2. **A run is open in the UI.** Call `get_viewed_run` — if it returns `{ run_id: null, ... }`, tell the user to select a run in Workshop and re-run the skill.
3. **The user's cwd is the agent's repo.** If the viewed run's event_name doesn't match any code under cwd, ask them to re-invoke from the right directory.

## Steps

### 1. Identify the agent from the viewed run

Call `get_viewed_run` via the `workshop` MCP. From the response:

- **Event name** — `run.event_name`, with any leading `replay:` stripped. This is the key you'll register under in `agents.json` and the handle the rest of the flow uses.
- **Sample spans** — available context fields, model names, tool names. Use these in step 4 so `AskUserQuestion` offers concrete options instead of free-text.

If the event name is empty or `unknown`, tell the user the trace has no event name tag — they need to pass one via `eventMetadata({ eventName: "..." })` in the SDK before this skill can work.

### 2. Locate the agent code

Grep the repo for the event name. Typical hits:

- `eventMetadata({ eventName: "<name>" })` — the source of truth.
- `@raindrop-ai/ai-sdk` / `createRaindropAISDK` imports — tells you how the SDK is wrapped.
- `RAINDROP_LOCAL_DEBUGGER` references.

If nothing matches, the agent is either un-instrumented or lives in a different repo. Tell the user and stop.

### 3. Verify the SDK is producing the fields we need

Look at the `eventMetadata()` call. For replay to reconstruct context, everything in the trace's `properties.*` needs to round-trip.

Cross-reference with the spans you pulled in step 1: if `get_viewed_run` shows fields under `raindrop.properties` (orgId, convoId, etc.) that aren't listed in the source's `eventMetadata({ properties: { ... } })`, they came in from somewhere else — flag that. If the SDK call is missing properties the agent needs at runtime, add them; don't invent new ones.

Fields *not* needed in `properties` (already captured automatically in span attributes):
- Model name, provider
- Token counts, timing

### 4. Ask the user about replay shape

Use `AskUserQuestion` — never free-text prompts. Base the options on what step 1 surfaced.

**Required question: mutating tools.** Scan the agent's tool set. If any tool writes to a DB, sends messages, calls external APIs with side effects, etc., list them and ask:

> "These tools have side effects: [list]. Should the replay endpoint skip/mock them?"
> - Yes, add a `--safe` mode (recommended)
> - No, run real tools every time

**Optional questions** (only ask if applicable):

- If multiple models/providers detected: "Which model should replays default to?"
- If an existing invocation surface exists (tRPC route, CLI, test harness): "Wrap [X] instead of calling the agent function directly?"
- Model override: "Allow the debugger UI to override the model per-replay?" (default yes — Workshop's Replay dropdown already has a model input, just needs the server to honor it)

Do not proceed past this step without answers. The skill's value comes from matching the user's intent.

### 5. Scaffold the replay server

Create `scripts/replay-server.ts` (or similar — follow existing script conventions in the repo) using this shape. **Pick a port by scanning 5860 → 5850** — `curl -sf http://127.0.0.1:<port>/health`; first one that 404s is yours. Avoids colliding with Workshop on :5899 or a parallel agent on an adjacent port.

```typescript
import express from "express";
import crypto from "crypto";
// Import the agent's real entry point — the one the user confirmed in step 4.
import { runAgent } from "<path the user confirmed>";

interface ReplayRequest {
  sourceRunId: string;
  replayRunId: string;
  messages: any[];
  systemPrompt?: string;
  userMessage?: string;
  model?: string;
  providerOptions?: any;
  context?: Record<string, any>;
}

const app = express();
app.use(express.json({ limit: "50mb" }));

const inFlight = new Map<string, AbortController>();

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "<event-name>-replay", inFlight: inFlight.size });
});

app.post("/replay", async (req, res) => {
  const replayId = crypto.randomBytes(8).toString("hex");
  const abort = new AbortController();
  inFlight.set(replayId, abort);
  res.json({ replayId });

  process.env.RAINDROP_LOCAL_DEBUGGER ??= "http://localhost:5899/v1/";

  runAgent({
    // Shape this to match the agent's real signature — use context fields
    // from step 1, userMessage/messages/model from the request body.
    ...(req.body as ReplayRequest).context,
    replayRunId: (req.body as ReplayRequest).replayRunId,
    signal: abort.signal,
  })
    .catch((err) => console.error(`[replay ${replayId}]`, err))
    .finally(() => inFlight.delete(replayId));
});

app.post("/cancel", (req, res) => {
  const abort = inFlight.get(req.body.replayId);
  if (abort) { abort.abort(); inFlight.delete(req.body.replayId); }
  res.json({ ok: true });
});

const PORT = Number(process.env.PORT ?? <chosen-port>);
app.listen(PORT, () => console.log(`[replay-server] listening on :${PORT}`));
```

Non-negotiable contract:
- **`GET /health` returns `{ ok: true }`** — Workshop polls this for the green dot.
- **`RAINDROP_LOCAL_DEBUGGER` must be set** so the agent's SDK ships traces back to Workshop instead of cloud Raindrop.
- **The agent's normal traces should include `replayRunId`** in metadata (the request body passes it through). Workshop uses that to stitch the new trace into the replay run row rather than creating a new row for it — so pass it into whatever `eventMetadata()` call the agent makes during this invocation.
- **If the user picked `--safe` mode in step 4**, stub the side-effecting tools before calling `runAgent`.

### 6. Add the script to package.json

Add `"replay-server": "tsx scripts/replay-server.ts"` under `scripts` in the agent repo's `package.json`. Match the indentation of the existing entries.

### 7. Register in ~/.workshop/agents.json

```bash
mkdir -p ~/.workshop
```

Read the existing file if present; merge rather than overwrite. The entry:

```json
{
  "<event-name>": {
    "url": "http://localhost:<chosen-port>/replay",
    "contextFromTrace": {
      "<context-key>": "properties.<same-key>",
      "<other-key>": "ai.telemetry.metadata.raindrop.<other-key>"
    }
  }
}
```

Build `contextFromTrace` from the properties you found in step 1 — only include fields the agent actually needs at runtime. `properties.*` for `raindrop.properties`, `ai.telemetry.metadata.raindrop.*` for top-level raindrop metadata.

**If the event name is already registered**, use `AskUserQuestion` to confirm overwrite vs. abort. Do not silently replace.

Workshop re-reads `agents.json` on every replay request — no restart needed. The Settings page's live status dot will update on the next mount.

### 8. Verify

Start the server yourself (detached, output to a log file so you can read it):

```bash
nohup pnpm replay-server > /tmp/replay-server-<event-name>.log 2>&1 &
```

Then:

```bash
sleep 1 && curl -sf http://localhost:<chosen-port>/health
```

If health returns `{ ok: true, ... }`, tell the user:

> Replay server is running on :<chosen-port>. In Workshop, click Replay → Local Agent on any run tagged `<event-name>` — the mode should be lit up with a green dot. Logs at `/tmp/replay-server-<event-name>.log`.

If health fails, print the log file contents and stop. Don't retry.

### 9. Document (optional — ask the user)

If the repo already has a `RAINDROP.md` or similar integration doc, append a section; otherwise ask whether to create one. The contents should be *operational* (how to start the server, what port, what agents.json mapping), not tutorial.

## What this skill does NOT do

- **Does not start Workshop.** That's `/workshop:setup`.
- **Does not trigger a replay.** That's the `replay_run` MCP tool or the UI button. This skill just makes those work.
- **Does not instrument an un-instrumented agent.** If the agent isn't already sending traces, tell the user to set up the Raindrop SDK first and stop.
