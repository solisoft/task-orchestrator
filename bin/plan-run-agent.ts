#!/usr/bin/env bun
//
// plan-run-agent <flags>
//
// SDK-driven planning runner for the "Plan it" flow on the new-task form.
// Routes AskUserQuestion / ExitPlanMode through canUseTool so the user
// can answer interactively from the form.
//
// Question/answer state is persisted on the plan's solidb document
// (`pending_question` column) so the controller can render the question
// card and the form's POST handler can deliver the answer:
//   - Agent writes:   { id, tool, tool_use_id, input, asked_at }
//   - Controller writes (on user submit):   { id, value }
//   - Agent clears to null after consuming the answer.
//
// Flags:
//   --plan-id <id>       Plan id (e.g. "plan-1778347304").
//   --notes-path <path>  Path to the user's rough notes.
//   --model <id>         Optional Claude model id (e.g. "claude-opus-4-7").
//                        When omitted, the SDK's default applies.
//   --project-dir <dir>  Project root the plan is about. The agent reads
//                        *that* CLAUDE.md and globs *that* tree, not
//                        the orchestrator's own. When omitted, falls
//                        back to process.cwd() (the orchestrator dir).
//   --state-dir <path>   Vestigial, accepted for backwards compat. No
//                        files are written under it anymore.

import { query, type CanUseTool, type Options } from "@anthropic-ai/claude-agent-sdk";

function flag(name: string): string | undefined {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const planId     = flag("plan-id");
const notesPath  = flag("notes-path");
const model      = flag("model");
const projectDir = flag("project-dir");

if (!planId || !notesPath) {
  console.error("usage: plan-run-agent --plan-id ID --notes-path PATH [--model M] [--project-dir D]");
  process.exit(64);
}

// solidb access for question/answer round-trips. Keep these on
// process.env (NOT childEnv) so the SDK subprocess doesn't inherit
// production credentials.
const SOLIDB_HOST = process.env.SOLIDB_HOST     ?? "http://localhost:6745";
const SOLIDB_DB   = process.env.SOLIDB_DATABASE ?? "tasks";
const SOLIDB_USER = process.env.SOLIDB_USERNAME ?? "admin";
const SOLIDB_PASS = process.env.SOLIDB_PASSWORD ?? "admin";
const AUTH_HEADER = "Basic " + Buffer.from(`${SOLIDB_USER}:${SOLIDB_PASS}`).toString("base64");

async function dbUpdatePendingQuestion(value: unknown): Promise<void> {
  try {
    await fetch(`${SOLIDB_HOST}/_api/database/${SOLIDB_DB}/cursor`, {
      method: "POST",
      headers: { "content-type": "application/json", "authorization": AUTH_HEADER },
      body: JSON.stringify({
        query: "UPDATE @plan_id WITH @patch IN plans",
        bindVars: { plan_id: planId, patch: { pending_question: value } },
      }),
    });
  } catch (err) {
    process.stderr.write(`dbUpdatePendingQuestion failed: ${(err as Error).message}\n`);
  }
}

async function dbReadPendingQuestion(): Promise<unknown> {
  try {
    const r = await fetch(
      `${SOLIDB_HOST}/_api/database/${SOLIDB_DB}/document/plans/${planId}`,
      { headers: { "authorization": AUTH_HEADER } },
    );
    if (!r.ok) return null;
    const doc = await r.json() as { pending_question?: unknown };
    return doc.pending_question ?? null;
  } catch {
    return null;
  }
}

function writeQuestion(record: unknown): Promise<void> {
  return dbUpdatePendingQuestion(record);
}

function clearQA(): Promise<void> {
  return dbUpdatePendingQuestion(null);
}

async function pollAnswer(qid: string, signal: AbortSignal): Promise<string> {
  while (!signal.aborted) {
    const pq = await dbReadPendingQuestion() as
      { id?: string; value?: string } | null;
    if (pq && pq.id === qid && typeof pq.value === "string") {
      await clearQA();
      return pq.value;
    }
    await new Promise((r) => setTimeout(r, 1500));
  }
  throw new Error("aborted");
}

const HUMAN_TOOLS = new Set(["AskUserQuestion", "ExitPlanMode"]);

const canUseTool: CanUseTool = async (toolName, input, opts) => {
  if (!HUMAN_TOOLS.has(toolName)) {
    // The SDK's runtime Zod schema requires `updatedInput` even though
    // the .d.ts marks it optional — pass the input back unchanged.
    return { behavior: "allow", updatedInput: input };
  }

  const qid = globalThis.crypto?.randomUUID?.()
    ?? `q-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  await writeQuestion({
    id: qid,
    tool: toolName,
    tool_use_id: opts.toolUseID,
    input,
    asked_at: new Date().toISOString(),
  });

  let answer: string;
  try {
    answer = await pollAnswer(qid, opts.signal);
  } catch (err) {
    return { behavior: "deny", message: `interrupted: ${(err as Error).message}` };
  }
  return { behavior: "deny", message: answer };
};

// The SDK ships a vendored claude-code binary per platform but our install
// only pulls the JS package. Point it at the system claude.
const claudePath = process.env.CLAUDE_CODE_EXECUTABLE
  ?? Bun.which("claude")
  ?? "claude";

// Scrub SOLIDB_* / TASK_ORCH_* from the env we hand to the agent — any
// `soli test` / `soli serve` it runs would otherwise inherit the
// orchestrator's production DB credentials.
const childEnv: Record<string, string> = {};
for (const [k, v] of Object.entries(process.env)) {
  if (v === undefined) continue;
  if (k.startsWith("SOLIDB_")) continue;
  if (k.startsWith("TASK_ORCH_")) continue;
  childEnv[k] = v;
}

const options: Options = {
  // Keep cwd at the orchestrator's project root so the agent finds
  // `/plan-task` in .claude/skills/. The target project path is passed
  // *inside* the prompt instead — the skill uses it for grounding
  // (CLAUDE.md, Glob, Read).
  cwd: process.cwd(),
  permissionMode: "default",
  canUseTool,
  pathToClaudeCodeExecutable: claudePath,
  env: childEnv,
  ...(model ? { model } : {}),
};

let exitCode = 0;
const promptArgs = projectDir
  ? `${notesPath} ${projectDir}`
  : notesPath;
try {
  for await (const msg of query({ prompt: `/plan-task ${promptArgs}`, options })) {
    process.stdout.write(JSON.stringify(msg) + "\n");
    if (msg.type === "result" && msg.subtype !== "success") {
      exitCode = 1;
    }
  }
} catch (err) {
  process.stderr.write(`plan-run-agent: ${(err as Error).stack ?? err}\n`);
  exitCode = 1;
}

process.exit(exitCode);
