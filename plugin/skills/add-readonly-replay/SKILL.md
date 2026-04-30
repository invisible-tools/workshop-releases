---
name: add-readonly-replay
description: Use when the user wants to replay a prod trace locally against their real agent code (not a tool-mock) — typically triggered from Workshop's "Local Agent" replay button or directly via /raindrop:add-readonly-replay. Wires a `RAINDROP_READONLY=1` switch into the user's agent, classifies every side-effecting tool (fail / stub / real), scaffolds an HTTP `/replay` endpoint that flips the switch before invoking the agent, and registers the agent in `~/.raindrop/agents.json` so Workshop knows where to send replay requests. Run once per agent — re-run when the tool surface changes.
---

The user wants to replay prod traces locally to debug their agent. Without readonly mode, replay either runs the real tools (and writes to prod) or runs no tools at all (and the replay is a fiction). This skill builds the missing third option: the agent runs end-to-end with realistic-looking results, but nothing escapes the run — and exposes that as an HTTP endpoint Workshop can call.

You're running **in the user's agent repo**, not Workshop's. All edits go into the user's codebase.

The user triggers this by clicking the greyed-out Local Agent mode in the Replay dropdown, by following its tooltip, or by running `/raindrop:add-readonly-replay` directly.

## What "readonly mode" means

A run is *readonly* if no effect of that run persists outside it: no DB writes, no emails, no queue publishes, no third-party API mutations, no log entries to shared observability. The agent's reasoning, the LLM calls, and any in-memory state are unaffected — just the side effects are.

Three behaviors per side-effecting call site, picked deliberately:

- **`fail`** — when readonly mode is on, the call throws a `ReadonlyViolation`. The agent sees the error like any other tool failure. Use this when the call is "important to know happened" — `send_email`, `create_invoice`, `publish_to_queue`. A loud failure beats a silent stub.
- **`stub`** — when readonly mode is on, the call returns a synthetic value of the right shape. Use this when the agent's downstream reasoning depends on getting *something* back — `find_or_create_user` returning an id, `enqueue_job` returning a job handle. Pick stub values that look real but are obviously synthetic on inspection (`stub-<hash>`, dates of `1970-01-01`).
- **`real`** — when readonly mode is on, the call runs unchanged. Use this for genuinely read-only operations the agent depends on (`search_docs`, `get_user_profile`, `list_recent_orders`).

There is no global default. Every side-effecting site is explicitly classified — that's what makes the mode defensible.

## Prerequisites

1. **The daemon is running.** If `get_viewed_run` errors with "Workshop backend unreachable," stop and tell the user to run `/raindrop:setup` first.
2. **A run is open in the UI.** Call `get_viewed_run` — if it returns `{ run_id: null, ... }`, tell the user to select a run in Workshop and re-run the skill.
3. **The user's cwd is the agent's repo.** If the viewed run's event_name doesn't match any code under cwd, ask them to re-invoke from the right directory.
4. **The agent has a clear tool surface.** Tool calls should be `tool({...})` (AI SDK), `defineTool(...)`, explicit registrations, or named functions wired into an LLM. If the agent's tools are ad-hoc inline functions scattered across files, walk the user through extracting them first; the readonly mode only works when there's a finite, enumerable list of side-effect points.

## Steps

### 1. Identify the agent from the viewed run

Call `get_viewed_run` via the `raindrop` MCP. From the response:

- **Event name** — `run.event_name`, with any leading `replay:` stripped. This is the key you'll register under in `agents.json`.
- **Properties** — what the agent reads from `properties` at runtime (orgId, convoId, userId, etc.).
- **Tool calls** — the actual tool names the agent invoked during this run. Use these as your starting list of "things to classify."

If the event name is empty or `unknown`, tell the user the trace has no event name tag — they need to pass one via `eventMetadata({ eventName: "..." })` in the SDK before this skill can work.

### 2. Locate the agent code

Grep the repo for the event name. Typical hits:

- `eventMetadata({ eventName: "<name>" })` — the source of truth for what entry point produced this trace.
- `@raindrop-ai/ai-sdk` / `createRaindropAISDK` imports — tells you how the SDK is wrapped.
- `RAINDROP_LOCAL_DEBUGGER` references.

If nothing matches, the agent is either un-instrumented or lives in a different repo. Tell the user and stop.

Cross-reference the SDK metadata with the trace properties: if `get_viewed_run` shows fields under `raindrop.properties` that aren't listed in the source's `eventMetadata({ properties: { ... } })`, they came in from somewhere else — flag that. If the SDK call is missing properties the agent needs at runtime, add them; don't invent new ones.

### 3. Map the side-effect surface

Grep the repo for the patterns that typically house side effects. Don't trust filenames — trust the operations.

| Surface | What to grep |
|---|---|
| Tool definitions | `tool\(\s*\{`, `defineTool\(`, `registerTool\(`, `\.tools\s*=` |
| ORM mutations | `\.create\(`, `\.update\(`, `\.delete\(`, `\.upsert\(`, `\.insert\(`, `\.save\(`, `prisma\.[a-z]+\.(create|update|delete|upsert)` |
| HTTP write verbs | `method:\s*['"](POST\|PUT\|PATCH\|DELETE)['"]`, `axios\.(post\|put\|patch\|delete)`, `fetch\([^,]+,\s*\{[^}]*method` |
| External SaaS clients | `nodemailer`, `sendgrid`, `mailgun`, `twilio`, `slack-web-api`, `stripe`, `intercom`, queue libs (`bullmq`, `kafkajs`, `sqs`, `pubsub`) |
| File / cache writes | `fs\.(writeFile\|appendFile\|rm\|unlink)`, redis `\.set\(`, `\.del\(`, `\.flushdb` |

For each match, decide whether it's an actual side effect (it leaves something behind that another system can see) or just internal state. Internal state never needs the mode; external state always does.

Build a markdown table the user can review before any code is written:

```markdown
| File:line | Operation | Default classification |
|---|---|---|
| src/tools/email.ts:14 | sendgrid.send(...) | fail |
| src/tools/users.ts:22 | findOrCreateUser(email) | stub |
| src/tools/search.ts:8 | searchIndex.query(...) | real |
```

**If the table is empty** (the agent has no side-effecting tools), confirm with `AskUserQuestion`:

> "I didn't find any side-effecting calls in this agent."
> - Right, this agent is purely read-only — skip to step 7
> - There are side effects, but I missed them — let's find them together

If the user confirms it's read-only, skip to step 7 and scaffold a replay server that doesn't bother setting `RAINDROP_READONLY` (nothing reads it anyway).

### 4. Confirm classification with the user

Use `AskUserQuestion` per call site, with the heuristic-derived default pre-selected. Don't free-text. The classification is the load-bearing decision; making it click-through keeps the user in the loop without making them type.

For each site:

> `src/tools/email.ts:14 — sendgrid.send(...)` is a pure write to a third-party that costs money and reaches a real user.
> Classification:
> - **fail (recommended)** — the agent throws when this is called in replay
> - **stub** — return a synthetic `{ id: "stub-<hash>", status: "queued" }`
> - **real** — let it actually send the email

If the user picks `stub`, ask one follow-up: what shape should the stub return? Provide a default sketch based on what callers actually read off the result (grep callers and look at field accesses) — don't ask the user to author a stub blind.

Do not proceed past this step without answers. The skill's value comes from matching the user's intent.

### 5. Wire the readonly switch

Create `src/readonly.ts` (or wherever the user's `src/` lives — match their pattern):

```typescript
// src/readonly.ts
//
// Readonly mode is enabled per-run by setting RAINDROP_READONLY=1 in the
// process environment. The replay HTTP server (set up later in this skill)
// sets this before invoking the agent.
//
// Per-call-site behavior is wired at the call site itself — see
// src/tools/*.ts for the interceptions.

export const isReadonly = (): boolean =>
  process.env.RAINDROP_READONLY === "1";

export class ReadonlyViolation extends Error {
  constructor(operation: string) {
    super(
      `Readonly mode is on; refusing to perform side-effecting operation: ${operation}. ` +
        `If this should be allowed during replay, classify it as "real" or "stub" in src/readonly.ts.`,
    );
    this.name = "ReadonlyViolation";
  }
}

/**
 * Classification registry. Documentation-only in v1 — the actual
 * `isReadonly()` checks live at each call site so the wiring is
 * visible where it matters.
 */
export const READONLY_CLASSIFICATIONS = {
  // Filled in below as you wire each site.
} as const;
```

Then apply per-site interceptions.

For each `fail` site, throw before the call:

```typescript
// src/tools/email.ts (after)
import { isReadonly, ReadonlyViolation } from "../readonly";

async function sendEmail({ to, subject, body }: EmailInput) {
  if (isReadonly()) throw new ReadonlyViolation("send_email");
  return await sendgrid.send({ to, subject, body });
}
```

For each `stub` site, branch to a synthetic return:

```typescript
// src/tools/users.ts
import { isReadonly } from "../readonly";

async function findOrCreateUser({ email }: { email: string }) {
  if (isReadonly()) {
    return {
      id: `stub-${hash(email).slice(0, 12)}`,
      email,
      createdAt: new Date(0),
      _readonly: true,
    };
  }
  return await db.user.upsert({ where: { email }, create: { email }, update: {} });
}
```

For each `real` site, no code change. Add a comment so the next reader knows it was deliberate:

```typescript
// src/tools/search.ts
// Readonly classification: real — read-only Algolia query, no side effects.
async function searchDocs({ query }: { query: string }) {
  return await algolia.search(query);
}
```

Update `READONLY_CLASSIFICATIONS` in `src/readonly.ts` with the final map:

```typescript
export const READONLY_CLASSIFICATIONS = {
  send_email: "fail",
  find_or_create_user: "stub",
  search_docs: "real",
  // …
} as const;
```

### 6. Add a verification harness, then run it

This is the load-bearing step. Without it the classifications are just hopeful comments.

Create `tests/readonly.test.ts` (or whatever testing convention the repo uses — match it):

```typescript
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { ReadonlyViolation } from "../src/readonly";
import { sendEmail } from "../src/tools/email";
import { findOrCreateUser } from "../src/tools/users";
import { searchDocs } from "../src/tools/search";

describe("readonly mode", () => {
  beforeAll(() => { process.env.RAINDROP_READONLY = "1"; });
  afterAll(() => { delete process.env.RAINDROP_READONLY; });

  describe("fail sites", () => {
    it("send_email throws ReadonlyViolation", async () => {
      await expect(sendEmail({ to: "x@y.z", subject: "x", body: "x" }))
        .rejects.toBeInstanceOf(ReadonlyViolation);
    });
  });

  describe("stub sites", () => {
    it("find_or_create_user returns synthetic shape", async () => {
      const user = await findOrCreateUser({ email: "x@y.z" });
      expect(user.id).toMatch(/^stub-/);
      expect(user.email).toBe("x@y.z");
      expect(user._readonly).toBe(true);
    });
  });

  describe("real sites", () => {
    // No assertion — these run for real. The point of including them
    // is that if their imports break or they accidentally got wrapped,
    // the test will surface it.
    it("search_docs runs without throwing", async () => {
      await expect(searchDocs({ query: "test" })).resolves.toBeDefined();
    });
  });
});
```

Run the test. If anything fails, fix before moving on. Common breakages:

- A `fail` site forgot the `if (isReadonly())` guard — test catches it.
- A `stub` site returns a shape the downstream caller doesn't expect — test catches it only if the test exercises that path; otherwise you'll learn at first replay.
- A `real` site has its own internal `fail`-classified sub-call (an audit logger that writes remotely) — test surfaces this when run under readonly mode.

The test isn't an absolute guarantee (a buggy `real` tool can still leak). It's proving the *intended* classification — every site we said was `fail` fails, every site we said was `stub` returns a stub, every site we said was `real` is reachable. Combined with the explicit registry in `src/readonly.ts`, that's enough to make the mode auditable.

### 7. Scaffold the replay server

Create `scripts/replay-server.ts` (or follow existing script conventions). **Pick a port by scanning 5860 → 5850** — `curl -sf http://127.0.0.1:<port>/health`; first one that 404s is yours. Avoids colliding with Workshop on :5899 or a parallel agent on an adjacent port.

```typescript
import express from "express";
import crypto from "crypto";
// Import the agent's real entry point — the one you located in step 2.
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

  // Flip the readonly switch the agent was wired to honor in steps 5–6.
  // Skip this line if step 3 confirmed the agent has no side effects.
  process.env.RAINDROP_READONLY = "1";
  process.env.RAINDROP_LOCAL_DEBUGGER ??= "http://localhost:5899/v1/";

  runAgent({
    // Shape this to match the agent's real signature — context fields
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

- **`GET /health` returns `{ ok: true }`** — Workshop polls this for the green dot in the Settings page and the Replay dropdown.
- **`RAINDROP_READONLY=1` is set before invoking the agent** (unless the user confirmed in step 3 that the agent has no side effects).
- **`RAINDROP_LOCAL_DEBUGGER` is set** so the agent's SDK ships traces back to Workshop instead of cloud Raindrop.
- **`replayRunId` flows into the agent's `eventMetadata()`** so Workshop can stitch the new trace into the replay row rather than creating a fresh row for it.

### 8. Wire into package.json + agents.json

Add the script to the agent repo's `package.json` (match existing entry indentation):

```json
"scripts": {
  "replay-server": "tsx scripts/replay-server.ts"
}
```

Then register the agent so Workshop knows where to send replay requests:

```bash
mkdir -p ~/.raindrop
```

Read `~/.raindrop/agents.json` if present; merge rather than overwrite:

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

Build `contextFromTrace` from the properties you found in step 1 — only fields the agent actually needs at runtime. `properties.*` for `raindrop.properties`, `ai.telemetry.metadata.raindrop.*` for top-level raindrop metadata.

**If the event name is already registered**, use `AskUserQuestion` to confirm overwrite vs. abort. Do not silently replace.

Workshop re-reads `agents.json` on every replay request — no Workshop restart needed.

### 9. Verify the endpoint

Start the server detached, output to a log file you can read:

```bash
nohup pnpm replay-server > /tmp/replay-server-<event-name>.log 2>&1 &
sleep 1 && curl -sf http://localhost:<chosen-port>/health
```

If health returns `{ ok: true, ... }`, tell the user:

> Replay server is running on :\<chosen-port>. In Workshop, click Replay → Local Agent on any run tagged `<event-name>` — the mode should be lit up with a green dot. Logs at `/tmp/replay-server-<event-name>.log`.
>
> Side-effecting tools are classified in `src/readonly.ts`; the verification test in `tests/readonly.test.ts` keeps them honest. Re-run `/raindrop:add-readonly-replay` after adding new tools or refactoring how tools are registered.

If health fails, print the log file contents and stop. Don't retry.

### 10. Document (optional — ask the user)

If the repo already has a `RAINDROP.md` or similar integration doc, append a section. Otherwise ask whether to create one. Contents should be *operational* (how to start the server, what port, what `agents.json` mapping, where the readonly classifications live), not tutorial.

## Heuristics — when to default to which classification

Use these as starting positions when proposing classification options to the user. They are not rules; the user always overrides per their domain knowledge.

| Pattern | Default | Reasoning |
|---|---|---|
| Pure write to a third party (`send_email`, `create_invoice`, `publish_to_queue`) | `fail` | Encountering it during replay is the signal something needs fixing; loud failure beats silent stub. |
| Read-then-write that downstream depends on (`find_or_create_user`, `upsert_doc`) | `stub` | Replay paths often need a plausible read; the write half is genuinely safe to drop. Stub the read shape, no-op the write. |
| Idempotent low-stakes writes (analytics events, structured logs to a shared sink) | `stub` returning `{ ok: true }` | Doubling up analytics during replay isn't catastrophic but noisy; default to no-op. |
| Read-only externals (`search_docs`, `get_status`, `list_recent_orders`) | `real` | Safe to run; the agent's behavior should match prod as closely as possible for these. |
| External APIs that bill or notify a real user (Stripe charge, Twilio SMS, push notifications) | `fail` | Treat as if accidental firing is "the worst day of your week." |
| Internal-network mutations of dev-only resources (test DB, sandbox account) | `stub` or `real` per user preference | Dev-DB writes during replay can pollute future replays' state; default to `stub` unless the user says they're fine with it. |
| Audit log writes required for compliance | `real` if the audit destination has a sandbox/dev mode; `stub` otherwise | Compliance teams don't want replay audit entries showing up in prod records. |

If a site doesn't match any heuristic, ask the user with `AskUserQuestion` and capture the reasoning in a code comment near the interception so the next maintainer doesn't have to re-derive it.

## What this skill does NOT do

- **Does not enforce readonly mode at the network layer.** A future skill (or a Workshop sandbox layer) might add an outbound-host allowlist for belt-and-suspenders safety. v1 trusts the in-code classification; the verification test is the only gate.
- **Does not start the daemon.** That's `/raindrop:setup`.
- **Does not trigger a replay.** That's the `replay_run` MCP tool or the UI button. This skill makes those *work*.
- **Does not instrument an un-instrumented agent.** If the agent isn't already sending traces, tell the user to set up the Raindrop SDK first and stop.
- **Does not classify code paths the agent doesn't actually use.** If a tool exists in the repo but isn't registered with the LLM, leave it alone. The classification is for what the agent can call during a replay; dead code stays dead.
- **Does not generate stubs you couldn't write yourself.** When picking stub shapes, base them on actual downstream usage (grep callers); don't invent fields the consumer doesn't read.
- **Does not retroactively scrub prior writes.** The mode prevents future writes from a replayed run; it does nothing about anything that ran before the mode was wired.

## When to re-run

- After adding a new tool that has side effects.
- After a refactor that moves an interception out of place, or changes the agent's entry point.
- If the verification test starts failing — re-running this skill walks the diff and re-classifies anything that changed.
- After changing the event name the agent reports — `agents.json` is keyed by event name, so a rename means a new entry.
