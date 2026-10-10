// Core of the powerhouse opencode plugin (plugin/powerhouse.js): the deterministic guardrails
// behind the agent team. Kept outside plugin/ because opencode loads every export there as a plugin.
//
//   push gate      every bash call   -> hooks/require-review-before-push.sh
//   module gate    edit/write/patch  -> hooks/check-module-sources.sh
//   agent guards   iam-tightener, cost-analyst, aws-researcher -> hooks/aws-readonly-guard.py
//                  security-remediator                         -> hooks/remediator-guard.py
//   subagent cap   at most POWERHOUSE_MAX_SUBAGENTS (default 1, max 2) task calls run at once,
//                  so parallel task calls don't load the local model several times over
//   review capture the six reviewers' results are saved to .opencode/.review/<agent>.md for
//                  bin/merge-findings, so PASS/FAIL is computed by a script, not by the model
//
// The hook scripts keep the Claude Code hook contract (JSON on stdin, exit 2 = block with the
// reason on stderr); this file translates opencode tool calls into that shape. Anything that
// can't be checked blocks (fail closed). It is a guardrail against mistakes and prompt
// injection, not a sandbox.
import { spawnSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, "..") // the .opencode (or ~/.config/opencode) directory
const HOOKS = path.join(ROOT, "hooks")

export const REVIEWERS = new Set([
  "security-reviewer", "iac-reviewer", "k8s-reviewer", "war-reviewer", "test-gap-reviewer", "frugal-reviewer",
])
// AWS agents: guard scope passed to aws-readonly-guard.py, and the tools each may use at all.
const AWS_AGENTS = {
  "iam-tightener": { scope: "iam", tools: ["bash", "read", "grep", "glob", "list"] },
  "cost-analyst": { scope: "cost", tools: ["bash", "read", "grep", "glob", "list"] },
  "aws-researcher": { scope: "docs", tools: ["read", "grep", "glob", "list"], mcp: "aws-docs_" },
}
const REMEDIATOR = "security-remediator"
// Agents that may change files. Every other subagent is read-only: on top of its own bash
// allowlist in its frontmatter, its bash calls may not redirect output into files.
const WRITERS = new Set(["implementer", REMEDIATOR, "test-runner"])
const REMEDIATOR_TOOLS = ["bash", "edit", "write", "read", "grep", "glob", "list"]
// opencode's own primary agents, which the user drives directly.
const PRIMARY = new Set(["build", "plan", "general", "explore", "title", "summary", "compaction"])
const FILE_TOOLS = { read: "Read", grep: "Grep", glob: "Glob", list: "Read" }

// Gate switches written by install.sh (--no-hook, --no-module-gate). Missing or unreadable: both on.
export function readSettings(file = path.join(ROOT, "powerhouse.json")) {
  let s = {}
  try { s = JSON.parse(readFileSync(file, "utf8")) } catch { s = {} }
  return { pushGate: s.pushGate !== false, moduleGate: s.moduleGate !== false }
}

export function maxSubagents(env = process.env) {
  const n = Number.parseInt(env.POWERHOUSE_MAX_SUBAGENTS ?? "1", 10)
  return Number.isFinite(n) ? Math.min(Math.max(n, 1), 2) : 1
}

class Blocked extends Error {}

// Runs a hook script with Claude-hook-shaped JSON on stdin. Exit 0 allows; anything else blocks.
export function runHook(script, args, payload, projectDir) {
  const file = path.join(HOOKS, script)
  if (!existsSync(file)) throw new Blocked(`powerhouse: ${script} not found in ${HOOKS}; blocking this tool call`)
  const interpreter = script.endsWith(".py") ? "python3" : "bash"
  const r = spawnSync(interpreter, [file, ...args], {
    input: JSON.stringify(payload),
    encoding: "utf8",
    timeout: 30_000,
    env: { ...process.env, POWERHOUSE_PROJECT_DIR: projectDir },
  })
  if (r.error) throw new Blocked(`powerhouse: could not run ${script} (${r.error.message}); blocking this tool call`)
  if (r.status === 0) return
  const reason = (r.stderr || r.stdout || "").trim()
  throw new Blocked(reason || `powerhouse: ${script} exited ${r.status}; blocking this tool call`)
}

// The files and added text an apply_patch call would write.
function patchFiles(patchText) {
  const files = []
  let current = null
  for (const line of String(patchText ?? "").split("\n")) {
    const m = line.match(/^\*\*\* (?:Add|Update) File: (.+)$/) || line.match(/^\*\*\* Move to: (.+)$/)
    if (m) { current = { file: m[1].trim(), text: [] }; files.push(current); continue }
    if (line.startsWith("*** ")) { current = null; continue }
    if (current && line.startsWith("+")) current.text.push(line.slice(1))
  }
  return files.map((f) => ({ file: f.file, text: f.text.join("\n") }))
}

// Write-like tool calls as [{file_path, text}] in Claude-hook terms.
function writes(tool, args) {
  if (tool === "write") return [{ file_path: args.filePath, content: args.content }]
  if (tool === "edit") return [{ file_path: args.filePath, new_string: args.newString }]
  if (tool === "apply_patch" || tool === "patch") {
    return patchFiles(args.patchText ?? args.patch).map((f) => ({ file_path: f.file, content: f.text }))
  }
  return []
}

// True if a shell command writes output to a file: `>`/`>>` to anything but /dev/null or a
// file descriptor, or `tee`. Quoted text is ignored, so `grep '>' x` is fine.
export function writesToFile(command) {
  const bare = String(command ?? "").replace(/'[^']*'|"(?:\\.|[^"\\])*"/g, "''")
  if (/(^|[\s|;&(])tee(\s|$)/.test(bare)) return true
  for (const m of bare.matchAll(/(\d*)(>>?|&>)(\|?)\s*(&\d|[^\s;&|]*)/g)) {
    const target = m[4]
    if (target === "/dev/null" || /^&\d$/.test(target)) continue
    return true
  }
  return false
}

export function createGuards({ directory, lookupAgent = async () => undefined, settings = readSettings() }) {
  const project = path.resolve(directory)
  const agents = new Map() // sessionID -> agent name
  const isSubagent = (agent) => !PRIMARY.has(agent)
  const cwdOf = (args) => (args?.workdir ? path.resolve(project, args.workdir) : project)

  async function agentOf(sessionID) {
    if (!agents.has(sessionID)) {
      const found = await lookupAgent(sessionID).catch(() => undefined)
      if (found) agents.set(sessionID, found)
    }
    return agents.get(sessionID)
  }

  function fileCheck(scope, tool, args) {
    const input = { read: { file_path: args.filePath }, list: { path: args.path ?? "." },
      glob: { pattern: args.pattern, path: args.path }, grep: { path: args.path, glob: args.include } }[tool]
    for (const k of Object.keys(input)) if (input[k] === undefined) delete input[k]
    runHook("aws-readonly-guard.py", [scope], { tool_name: FILE_TOOLS[tool], tool_input: input, cwd: project }, project)
  }

  async function before(input, output) {
    const { tool, sessionID } = input
    const args = output.args ?? {}

    // 1. Guards that apply to every agent.
    if (tool === "bash" && settings.pushGate) {
      runHook("require-review-before-push.sh", [], { tool_input: { command: args.command }, cwd: cwdOf(args) }, project)
    }
    for (const w of settings.moduleGate ? writes(tool, args) : []) {
      runHook("check-module-sources.sh", [], { tool_input: w, cwd: project }, project)
    }

    // 2. Agent-scoped guards.
    const agent = await agentOf(sessionID)
    if (!agent) throw new Blocked("powerhouse: could not tell which agent made this call; blocking it")
    const aws = AWS_AGENTS[agent]
    if (aws) {
      if (aws.mcp && tool.startsWith(aws.mcp)) return
      if (!aws.tools.includes(tool)) throw new Blocked(`powerhouse: ${agent} may not use the ${tool} tool`)
      if (tool === "bash") {
        runHook("aws-readonly-guard.py", [aws.scope], { tool_name: "Bash", tool_input: { command: args.command }, cwd: cwdOf(args) }, project)
      } else fileCheck(aws.scope, tool, args)
    } else if (agent === REMEDIATOR) {
      if (!REMEDIATOR_TOOLS.includes(tool)) throw new Blocked(`powerhouse: ${REMEDIATOR} may not use the ${tool} tool`)
      if (tool === "bash") {
        runHook("remediator-guard.py", [], { tool_name: "Bash", tool_input: { command: args.command }, cwd: cwdOf(args) }, project)
      } else if (tool === "edit" || tool === "write") {
        runHook("remediator-guard.py", [], { tool_name: tool === "edit" ? "Edit" : "Write", tool_input: { file_path: args.filePath }, cwd: project }, project)
        // The remediator keeps the module gate even when the install turned it off for everyone else.
        if (!settings.moduleGate) for (const w of writes(tool, args)) runHook("check-module-sources.sh", [], { tool_input: w, cwd: project }, project)
      } else fileCheck("", tool, args)
    } else if (tool === "bash" && isSubagent(agent) && !WRITERS.has(agent) && writesToFile(args.command)) {
      throw new Blocked(`powerhouse: ${agent} is read-only; its commands may not redirect output into files (only to /dev/null)`)
    }
  }

  return { agents, agentOf, before }
}

// Counting semaphore for task calls. tool.execute.after isn't called when a tool throws, so
// permits are also released when the calling session goes idle or errors, and after a timeout.
export function createLimiter({ max = 1, staleMs = 30 * 60_000, now = () => Date.now() } = {}) {
  const held = new Map() // callID -> { sessionID, since }
  const idleAt = new Map() // sessionID -> last time the session went idle
  let waiters = []
  const wake = () => { const w = waiters; waiters = []; w.forEach((r) => r()) }

  async function acquire(callID, sessionID) {
    const started = now()
    for (;;) {
      for (const [id, h] of held) if (now() - h.since > staleMs) held.delete(id)
      if ((idleAt.get(sessionID) ?? -1) >= started) throw new Blocked("powerhouse: task cancelled while waiting for a subagent slot")
      if (held.size < max) { held.set(callID, { sessionID, since: now() }); return }
      await new Promise((r) => { waiters.push(r); setTimeout(r, 2_000) })
    }
  }
  function release(callID) { if (held.delete(callID)) wake() }
  function sessionDone(sessionID) {
    idleAt.set(sessionID, now())
    for (const [id, h] of held) if (h.sessionID === sessionID) held.delete(id)
    wake()
  }
  return { acquire, release, sessionDone, held }
}

// Pulls the subagent's answer out of the task tool's output.
export function taskResult(output) {
  const text = String(output ?? "")
  const m = text.match(/<task_result>\s*([\s\S]*?)\s*<\/task_result>/)
  return (m ? m[1] : text).trim()
}

export { Blocked, AWS_AGENTS, WRITERS }
