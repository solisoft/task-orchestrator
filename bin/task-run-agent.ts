#!/usr/bin/env bun
//
// task-run-agent <flags>
//
// SDK-driven replacement for `claude --dangerously-skip-permissions -p ...`.
// Embeds @anthropic-ai/claude-agent-sdk so we can intercept AskUserQuestion
// and ExitPlanMode tool calls and route them to a human via the orchestrator
// UI (write the question to the tasks row, poll for the answer).
//
// Flags:
//   --project <name>     Repo basename under TASK_ORCH_ROOT (e.g. "lang").
//   --slug <slug>        Task slug (filename without .md).
//   --worktree <path>    Worktree directory the agent runs in (cwd).
//   --prompt <text>      The /do-task or /review-task command to send.
//
// Output:
//   Each SDK message is emitted as one JSON line on stdout — same shape
//   the legacy `claude -p --output-format stream-json` produced, so
//   bin/_stream-format.jq keeps working unchanged.

import { query, type CanUseTool, type Options } from "@anthropic-ai/claude-agent-sdk";

// --- args ---------------------------------------------------------------

function flag(name: string): string | undefined {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const project  = flag("project");
const slug     = flag("slug");
const worktree = flag("worktree");
const prompt   = flag("prompt");

if (!project || !slug || !worktree || !prompt) {
  console.error("usage: task-run-agent --project X --slug Y --worktree DIR --prompt TEXT");
  process.exit(64);
}

const KEY = `${project}--${slug}`;

// --- env ----------------------------------------------------------------

// task-run already source'd .env into our environment, but allow direct
// invocation too — fall back to .env in the orchestrator root.
async function loadDotEnv() {
  const here = new URL(import.meta.url).pathname;
  const orchestratorRoot = here.replace(/\/bin\/[^/]+$/, "");
  const file = `${orchestratorRoot}/.env`;
  if (!(await Bun.file(file).exists())) return;
  for (const line of (await Bun.file(file).text()).split("\n")) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2];
  }
}
await loadDotEnv();

const SOLIDB_HOST = process.env.SOLIDB_HOST     ?? "http://localhost:6745";
const SOLIDB_DB   = process.env.SOLIDB_DATABASE ?? "tasks";
const SOLIDB_USER = process.env.SOLIDB_USERNAME ?? "admin";
const SOLIDB_PASS = process.env.SOLIDB_PASSWORD ?? "admin";
const BASIC = "Basic " + Buffer.from(`${SOLIDB_USER}:${SOLIDB_PASS}`).toString("base64");

// --- DB helpers for the question/answer round-trip ---------------------

async function dbPatch(patch: Record<string, unknown>): Promise<void> {
  const url = `${SOLIDB_HOST}/_api/database/${SOLIDB_DB}/cursor`;
  const body = {
    query: `UPDATE @key WITH @patch IN tasks RETURN NEW`,
    bindVars: { key: KEY, patch },
  };
  const resp = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: BASIC },
    body: JSON.stringify(body),
  });
  if (!resp.ok) {
    throw new Error(`dbPatch HTTP ${resp.status}: ${await resp.text()}`);
  }
}

async function dbReadAnswer(qid: string, signal: AbortSignal): Promise<string> {
  const url = `${SOLIDB_HOST}/_api/database/${SOLIDB_DB}/document/tasks/${KEY}`;
  while (!signal.aborted) {
    const resp = await fetch(url, { headers: { authorization: BASIC }, signal });
    if (resp.ok) {
      const row = await resp.json() as {
        pending_answer?: { id?: string; value?: string };
      };
      const a = row.pending_answer;
      if (a && a.id === qid && typeof a.value === "string") {
        // Clear the pending pair before returning so the next intercept
        // starts from a clean slate.
        await dbPatch({ pending_question: null, pending_answer: null });
        return a.value;
      }
    }
    await new Promise((r) => setTimeout(r, 1500));
  }
  throw new Error("aborted");
}

// --- canUseTool intercept ----------------------------------------------

const HUMAN_TOOLS = new Set(["AskUserQuestion", "ExitPlanMode"]);

const canUseTool: CanUseTool = async (toolName, input, opts) => {
  if (!HUMAN_TOOLS.has(toolName)) {
    return { behavior: "allow" };
  }

  const qid = (globalThis.crypto?.randomUUID?.() ?? `q-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  await dbPatch({
    pending_question: {
      id: qid,
      tool: toolName,
      tool_use_id: opts.toolUseID,
      input,
      asked_at: new Date().toISOString(),
    },
  });

  let answer: string;
  try {
    answer = await dbReadAnswer(qid, opts.signal);
  } catch (err) {
    return { behavior: "deny", message: `interrupted: ${(err as Error).message}` };
  }

  // Synthesize a tool_result the model can act on. AskUserQuestion is
  // normally consumed as text describing the user's selection; ExitPlanMode
  // either approves (let the tool run for real next time) or rejects with
  // a free-form note. We deny+message in both cases so the SDK doesn't try
  // to fulfil the tool itself — `is_error: true` on the tool_result is OK,
  // the model treats it as a tool response either way.
  return { behavior: "deny", message: answer };
};

// --- run ---------------------------------------------------------------

const options: Options = {
  cwd: worktree,
  permissionMode: "default",
  // canUseTool fires for every tool when permissionMode is 'default'.
  // We auto-allow non-human tools, so the agent runs unattended for
  // everything except the two we want a human in the loop for.
  // (We deliberately avoid 'bypassPermissions' here — that mode skips
  // canUseTool entirely, defeating the intercept.)
  canUseTool,
};

let exitCode = 0;
try {
  for await (const msg of query({ prompt, options })) {
    process.stdout.write(JSON.stringify(msg) + "\n");
    if (msg.type === "result" && msg.subtype !== "success") {
      exitCode = 1;
    }
  }
} catch (err) {
  process.stderr.write(`task-run-agent: ${(err as Error).stack ?? err}\n`);
  exitCode = 1;
}
process.exit(exitCode);
