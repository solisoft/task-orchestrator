#!/usr/bin/env bun
//
// plan-run-agent <flags>
//
// SDK-driven planning runner for the "Plan it" flow on the new-task form.
// Routes AskUserQuestion / ExitPlanMode through canUseTool so the user
// can answer interactively from the form.
//
// State lives in $TASK_ORCH_STATE/_plans/<plan_id>/:
//   pending_question.json — { id, tool, input, asked_at }
//   pending_answer.json   — { id, value }
//   body                  — final spec (written when the agent exits cleanly)
//
// Flags:
//   --plan-id <id>       Plan id (e.g. "plan-1778347304").
//   --state-dir <path>   $TASK_ORCH_STATE/_plans/<id>.
//   --notes-path <path>  Path to the user's rough notes.
//   --model <id>         Optional Claude model id (e.g. "claude-opus-4-7").
//                        When omitted, the SDK's default applies.
//   --project-dir <dir>  Project root the plan is about. The agent reads
//                        *that* CLAUDE.md and globs *that* tree, not
//                        the orchestrator's own. When omitted, falls
//                        back to process.cwd() (the orchestrator dir).

import { query, type CanUseTool, type Options } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, readFileSync, writeFileSync, unlinkSync, mkdirSync } from "node:fs";
import { join } from "node:path";

function flag(name: string): string | undefined {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const planId     = flag("plan-id");
const stateDir   = flag("state-dir");
const notesPath  = flag("notes-path");
const model      = flag("model");
const projectDir = flag("project-dir");

if (!planId || !stateDir || !notesPath) {
  console.error("usage: plan-run-agent --plan-id ID --state-dir DIR --notes-path PATH");
  process.exit(64);
}

mkdirSync(stateDir, { recursive: true });

const QUESTION_FILE = join(stateDir, "pending_question.json");
const ANSWER_FILE   = join(stateDir, "pending_answer.json");
const BODY_FILE     = join(stateDir, "body");

function writeQuestion(record: unknown): void {
  writeFileSync(QUESTION_FILE, JSON.stringify(record));
}

function clearQA(): void {
  for (const f of [QUESTION_FILE, ANSWER_FILE]) {
    try { unlinkSync(f); } catch { /* ignore */ }
  }
}

async function pollAnswer(qid: string, signal: AbortSignal): Promise<string> {
  while (!signal.aborted) {
    if (existsSync(ANSWER_FILE)) {
      try {
        const a = JSON.parse(readFileSync(ANSWER_FILE, "utf8")) as {
          id?: string; value?: string;
        };
        if (a.id === qid && typeof a.value === "string") {
          clearQA();
          return a.value;
        }
      } catch {
        // Partial write or stale file — keep polling.
      }
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
  writeQuestion({
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
const transcript: any[] = [];
const promptArgs = projectDir
  ? `${notesPath} ${projectDir}`
  : notesPath;
try {
  for await (const msg of query({ prompt: `/plan-task ${promptArgs}`, options })) {
    process.stdout.write(JSON.stringify(msg) + "\n");
    transcript.push(msg);
    if (msg.type === "result" && msg.subtype !== "success") {
      exitCode = 1;
    }
  }
} catch (err) {
  process.stderr.write(`plan-run-agent: ${(err as Error).stack ?? err}\n`);
  exitCode = 1;
}

if (exitCode === 0) {
  const lastAssistant = [...transcript].reverse().find(
    (m) => m.type === "assistant",
  ) as { message?: { content?: Array<{ type: string; text?: string }> } } | undefined;
  const body = (lastAssistant?.message?.content ?? [])
    .filter((c) => c.type === "text")
    .map((c) => c.text ?? "")
    .join("");
  if (body.trim().length > 0) {
    writeFileSync(BODY_FILE, body);
  } else {
    process.stderr.write("plan-run-agent: no assistant text captured\n");
    exitCode = 1;
  }
}

process.exit(exitCode);
