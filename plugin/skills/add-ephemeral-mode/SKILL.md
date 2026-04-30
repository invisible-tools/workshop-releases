---
name: add-ephemeral-mode
description: Wire up an "ephemeral mode" in the user's agent so its tool calls and side effects can be safely simulated during local replay. Then verify it actually holds. Use this before `/workshop:create-agent-replay` whenever the agent has any tool that writes to a real system (DB, email, payments, queues, third-party APIs).
---

The user wants to replay prod traces locally to debug their agent. Without an ephemeral mode, replay either runs the real tools (and writes to prod) or runs no tools at all (and the replay is a fiction). This skill builds the missing third option: the agent runs end-to-end with realistic-looking results, but nothing escapes the run.

You're running **in the user's agent repo**, not Workshop's. All edits go into the user's codebase.

## What "ephemeral mode" means

A run is *ephemeral* if no effect of that run persists outside it: no DB writes, no emails, no queue publishes, no third-party API mutations, no log entries to shared observability. The agent's reasoning, the LLM calls, and any in-memory state are unaffected — just the side effects are.

Three behaviors per side-effecting call site, picked deliberately:

- **`fail`** — when ephemeral mode is on, the call throws an `EphemeralViolation`. The agent sees the error like any other tool failure. Use this when the call is "important to know happened" — `send_email`, `create_invoice`, `publish_to_queue`. A failure here is a useful signal, not a bug.
- **`stub`** — when ephemeral mode is on, the call returns a synthetic value of the right shape. Use this when the agent's downstream reasoning depends on getting *something* back — `find_or_create_user` returning an id, `enqueue_job` returning a job handle. Pick stub values that look real but are obviously synthetic on inspection (`stub-<hash>`, dates of `1970-01-01`).
- **`real`** — when ephemeral mode is on, the call runs unchanged. Use this for genuinely read-only operations the agent depends on (`search_docs`, `get_user_profile`, `list_recent_orders`).

There is no global default. Every side-effecting site is explicitly classified — that's what makes the mode defensible.

## Prerequisites

1. **Workshop is running.** If `get_active_run` errors with "Workshop backend unreachable," tell the user to run `/workshop:setup` first.
2. **The user's cwd is the agent's repo.** Confirm by checking that the repo has either `package.json`, `pyproject.toml`, or another language manifest, and that imports like `@raindrop-ai/ai-sdk`, `ai`, or `openai` appear somewhere in the source. If not, ask them to re-invoke from the right directory.
3. **The agent has a clear tool surface** — calls to `tool({...})` (AI SDK), explicit tool registration, or named functions wired into an LLM. If the agent's tools are scattered across ad-hoc inline functions, walk the user through extracting them first; the mode only works when there's a finite, enumerable list of side-effect points.

## Steps

### 1. Map the side-effect surface

Grep the repo for the patterns that typically house side effects. Don't trust filenames — trust the operations.

Patterns to scan, in priority order:

| Surface | What to grep |
|---|---|
| Tool definitions | `tool\(\s*\{`, `defineTool\(`, `registerTool\(`, `\.tools\s*=` |
| ORM mutations | `\.create\(`, `\.update\(`, `\.delete\(`, `\.upsert\(`, `\.insert\(`, `\.save\(`, `prisma\.[a-z]+\.(create|update|delete|upsert)` |
| HTTP write verbs | `method:\s*['"](POST\|PUT\|PATCH\|DELETE)['"]`, `axios\.(post\|put\|patch\|delete)`, `fetch\([^,]+,\s*\{[^}]*method` |
| External SaaS clients | `nodemailer`, `sendgrid`, `mailgun`, `twilio`, `slack-web-api`, `stripe`, `intercom`, common queue libs (`bullmq`, `kafkajs`, `sqs`, `pubsub`) |
| File writes / stateful caches | `fs\.(writeFile\|appendFile\|rm\|unlink)`, redis `\.set\(`, `\.del\(`, `\.flushdb` |

For each match, decide whether it's an actual side effect (it leaves something behind that another system can see) or just internal state. Internal state never needs the mode; external state always does.

Build the list as a markdown table the user can review before any code is written:

```markdown
| File:line | Operation | Default classification |
|---|---|---|
| src/tools/email.ts:14 | sendgrid.send(...) | fail |
| src/tools/users.ts:22 | findOrCreateUser(email) | stub |
| src/tools/search.ts:8 | searchIndex.query(...) | real |
```

### 2. Confirm classification with the user

Use `AskUserQuestion` per call site, with the heuristic-derived default pre-selected. Don't free-text. The classification is the load-bearing decision; making it click-through keeps the user in the loop without making them type.

For each site:

> `src/tools/email.ts:14 — sendgrid.send(...)` is a pure write to a third-party that costs money and reaches a real user.
> Classification:
> - **fail (recommended)** — the agent throws when this is called in replay
> - **stub** — return a synthetic `{ id: "stub-<hash>", status: "queued" }`
> - **real** — let it actually send the email

If the user picks `stub`, ask one follow-up: what shape should the stub return? Provide a default sketch based on what they actually use downstream (grep for `sendEmail(...)` callers and look at what they read off the result) — don't ask the user to author a stub blind.

### 3. Add the runtime helper

Create a small module that the rest of the codebase will import. Default location: `src/ephemeral.ts` (or wherever the user's `src/` lives — match their pattern).

```typescript
// src/ephemeral.ts
//
// Ephemeral mode is enabled per-run by setting RAINDROP_EPHEMERAL=1 in the
// process environment. The replay HTTP server (set up by
// /workshop:create-agent-replay) sets this before invoking the agent.
//
// Per-call-site behavior is wired at the call site itself — see
// src/tools/*.ts for the interceptions.

export const isEphemeral = (): boolean =>
  process.env.RAINDROP_EPHEMERAL === "1";

export class EphemeralViolation extends Error {
  constructor(operation: string) {
    super(
      `Ephemeral mode is on; refusing to perform side-effecting operation: ${operation}. ` +
        `If this should be allowed during replay, classify it as "real" or "stub" in src/ephemeral.ts.`,
    );
    this.name = "EphemeralViolation";
  }
}

/**
 * Classification registry. The skill keeps this as documentation —
 * the actual interception lives at each call site so the wiring is
 * visible where it matters.
 */
export const EPHEMERAL_CLASSIFICATIONS = {
  // Filled in by /workshop:add-ephemeral-mode
} as const;
```

The classification registry is intentionally documentation-only in v1 — the actual `isEphemeral()` checks live at each call site. (The registry exists so that a future Raindrop SDK primitive can read it; for v1, it's a single source of truth for what was decided.)

### 4. Apply the per-site interceptions

For each `fail` site: wrap the call so it throws `EphemeralViolation` first.

```typescript
// src/tools/email.ts (before)
async function sendEmail({ to, subject, body }: EmailInput) {
  return await sendgrid.send({ to, subject, body });
}

// src/tools/email.ts (after)
import { isEphemeral, EphemeralViolation } from "../ephemeral";

async function sendEmail({ to, subject, body }: EmailInput) {
  if (isEphemeral()) throw new EphemeralViolation("send_email");
  return await sendgrid.send({ to, subject, body });
}
```

For each `stub` site: branch to a synthetic return.

```typescript
// src/tools/users.ts
import { isEphemeral } from "../ephemeral";

async function findOrCreateUser({ email }: { email: string }) {
  if (isEphemeral()) {
    return {
      id: `stub-${hash(email).slice(0, 12)}`,
      email,
      createdAt: new Date(0),
      _ephemeral: true,
    };
  }
  return await db.user.upsert({ where: { email }, create: { email }, update: {} });
}
```

For each `real` site: no change. Add a comment noting it's been classified `real`, so the next person reading the code knows it was a deliberate choice, not an oversight.

```typescript
// src/tools/search.ts
// Ephemeral classification: real — read-only Algolia query, no side effects.
async function searchDocs({ query }: { query: string }) {
  return await algolia.search(query);
}
```

Update `EPHEMERAL_CLASSIFICATIONS` in `src/ephemeral.ts` with the final map:

```typescript
export const EPHEMERAL_CLASSIFICATIONS = {
  send_email: "fail",
  find_or_create_user: "stub",
  search_docs: "real",
  // …
} as const;
```

### 5. Add a verification harness

This is the load-bearing step. A test file that exercises every classified site under ephemeral mode and asserts the right thing happens.

Default location: `tests/ephemeral.test.ts` (or whatever testing convention the repo uses — match it).

Pattern:

```typescript
import { describe, it, expect, beforeAll, afterAll } from "vitest"; // or whatever the repo uses
import { EphemeralViolation } from "../src/ephemeral";
import { sendEmail } from "../src/tools/email";
import { findOrCreateUser } from "../src/tools/users";
import { searchDocs } from "../src/tools/search";

describe("ephemeral mode", () => {
  beforeAll(() => { process.env.RAINDROP_EPHEMERAL = "1"; });
  afterAll(() => { delete process.env.RAINDROP_EPHEMERAL; });

  describe("fail sites", () => {
    it("send_email throws EphemeralViolation", async () => {
      await expect(sendEmail({ to: "x@y.z", subject: "x", body: "x" }))
        .rejects.toBeInstanceOf(EphemeralViolation);
    });
  });

  describe("stub sites", () => {
    it("find_or_create_user returns synthetic shape", async () => {
      const user = await findOrCreateUser({ email: "x@y.z" });
      expect(user.id).toMatch(/^stub-/);
      expect(user.email).toBe("x@y.z");
      expect(user._ephemeral).toBe(true);
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

The test isn't proving an absolute guarantee (a malicious or buggy `real` tool can still leak). It's proving the *intended* classification — every site we said was `fail` fails, every site we said was `stub` returns a stub, every site we said was `real` is reachable. Combined with the explicit registry in `src/ephemeral.ts`, that's enough to make the mode auditable.

### 6. Run verification, report

Run the test suite. If anything fails, surface the failure clearly and fix it before declaring done. Common breakages:

- A `fail` site forgot the `if (isEphemeral())` guard — test catches it.
- A `stub` site returns a shape the downstream caller doesn't expect — test catches it if the test exercises a downstream path; otherwise you'll only learn at first replay.
- A `real` site has its own internal `fail`-classified sub-call (an audit logger that writes to a remote DB) — test surfaces this when run under ephemeral mode.

Report to the user:

> Ephemeral mode wired. Classifications:
>
> | Site | Mode |
> |---|---|
> | `send_email` | fail |
> | `find_or_create_user` | stub |
> | `search_docs` | real |
>
> Verification: 3 tests passing under `RAINDROP_EPHEMERAL=1`. Source of truth: `src/ephemeral.ts`.
>
> Next: run `/workshop:create-agent-replay` to wire the HTTP replay endpoint that uses this mode.

## Heuristics — when to default to which classification

Use these as starting positions when proposing classification options to the user. They are not rules; the user always overrides per their domain knowledge.

| Pattern | Default | Reasoning |
|---|---|---|
| Pure write to a third party (`send_email`, `create_invoice`, `publish_to_queue`) | `fail` | Encountering it during replay is the signal something needs fixing; loud failure beats silent stub. The agent's response to the failure is itself diagnostic. |
| Read-then-write that downstream depends on (`find_or_create_user`, `upsert_doc`) | `stub` | Replay paths often need a plausible read; the write half is genuinely safe to drop. Stub the read shape, no-op the write. |
| Idempotent low-stakes writes (analytics events, structured logs to a shared sink) | `stub` returning `{ ok: true }` | Doubling up analytics during replay isn't catastrophic but noisy; default to no-op. |
| Read-only externals (`search_docs`, `get_status`, `list_recent_orders`) | `real` | Safe to run; the agent's behavior should match prod as closely as possible for these. |
| External APIs that bill or notify a real user (Stripe charge, Twilio SMS, push notifications) | `fail` | Treat as if accidental firing is "the worst day of your week." |
| Internal-network mutations of dev-only resources (test DB, sandbox account) | `stub` or `real` per the user's preference | Dev-DB writes during replay can pollute future replays' state; default to `stub` unless the user says they're fine with it. |
| Audit log writes that are required for compliance | `real` if the audit destination has a sandbox/dev mode; `stub` otherwise | Compliance teams don't want replay audit entries showing up in prod records. |

If a site doesn't match any heuristic, ask the user with `AskUserQuestion` and capture the reasoning in a code comment near the interception so the next maintainer doesn't have to re-derive it.

## What this skill does NOT do

- **Does not enforce ephemeral mode at the network layer.** A future skill (or a Workshop sandbox layer) might add an outbound-host allowlist for belt-and-suspenders safety. v1 trusts the in-code classification; the verification test is the only gate.
- **Does not wire the replay HTTP endpoint.** That's `/workshop:create-agent-replay`, which should be run after this skill so the endpoint enables ephemeral mode automatically.
- **Does not classify code paths the agent doesn't actually use.** If a tool exists in the repo but isn't registered with the LLM, leave it alone. The classification is for what the agent can call during a replay; dead code stays dead.
- **Does not generate stubs you couldn't write yourself.** When picking stub return shapes, base them on actual downstream usage (grep callers); don't invent fields the consumer doesn't read.
- **Does not retroactively scrub prior writes.** The mode prevents future writes from a replayed run; it does nothing about anything that ran before the mode was wired.

## When to re-run

- After adding a new tool that has side effects.
- After a refactor that moves an interception out of place.
- If the verification test starts failing — re-running this skill walks the diff and re-classifies anything that changed.
