// Tests for the opencode plugin (.opencode/plugin/powerhouse.js and .opencode/lib/powerhouse-core.js).
// Run with: bun test tests/plugin.test.js   (tests/run.sh runs it when bun is installed)
import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { spawnSync } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import * as pluginModule from "../.opencode/plugin/powerhouse.js"
import {
  createGuards, createLimiter, maxSubagents, readSettings, runHook, taskResult, writesToFile,
} from "../.opencode/lib/powerhouse-core.js"

const sh = (cwd, ...args) => spawnSync(args[0], args.slice(1), { cwd, encoding: "utf8" })
let work, proj

beforeAll(() => {
  work = mkdtempSync(path.join(tmpdir(), "powerhouse-plugin-"))
  proj = path.join(work, "proj")
  mkdirSync(path.join(proj, ".opencode", "references"), { recursive: true })
  sh(proj, "git", "init", "-q")
  sh(proj, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
  writeFileSync(path.join(proj, ".opencode", "references", "approved-modules.txt"), "terraform-aws-modules/vpc/aws\n")
  writeFileSync(path.join(proj, "main.tf"), "")
  writeFileSync(path.join(proj, ".env"), "SECRET=1\n")
  process.env.AWS_READONLY_PROFILE = "ro"
  process.env.AWS_PROFILE = "ro"
  delete process.env.AWS_ACCESS_KEY_ID
  delete process.env.AWS_SECRET_ACCESS_KEY
  delete process.env.AWS_SESSION_TOKEN
  delete process.env.POWERHOUSE_SKIP_REVIEW_GATE
})
afterAll(() => rmSync(work, { recursive: true, force: true }))

const tf = (src) => `module "m" {\n  source  = "${src}"\n  version = "1.0.0"\n}\n`

// guards(agent) -> call(tool, args) resolving to "allow" or the block message
function guards(agent, settings = { pushGate: true, moduleGate: true }) {
  const g = createGuards({ directory: proj, settings })
  if (agent) g.agents.set("s1", agent)
  return async (tool, args) => {
    try {
      await g.before({ tool, sessionID: "s1", callID: "c1" }, { args })
      return "allow"
    } catch (e) {
      return `blocked: ${e.message}`
    }
  }
}

describe("writesToFile", () => {
  const cases = {
    "git diff > /tmp/x": true, "git diff >> x": true, "echo a>b": true, "git diff | tee x": true,
    "cmd &> out": true, "x 2>&1 >out": true, "git diff >": true,
    "git diff 2>/dev/null": false, "git diff 2>&1 | head": false, "git diff &>/dev/null": false,
    'grep ">" x': false, 'echo "a > b"': false, "git diff >/dev/null 2>&1": false, "git log -n 5": false,
  }
  for (const [cmd, want] of Object.entries(cases)) test(`${want ? "writes" : "doesn't write"}: ${cmd}`, () => expect(writesToFile(cmd)).toBe(want))
})

describe("guards for every agent", () => {
  test("push gate blocks an unreviewed git push", async () => {
    expect(await guards("build")("bash", { command: "git push origin main" })).toMatch(/review gate/)
  })
  test("push gate ignores other commands", async () => {
    expect(await guards("build")("bash", { command: "git status" })).toBe("allow")
  })
  test("push gate follows the bash workdir", async () => {
    expect(await guards("build")("bash", { command: "git push", workdir: "/nonexistent-dir" })).toMatch(/review gate/)
  })
  test("push gate off via settings", async () => {
    expect(await guards("build", { pushGate: false, moduleGate: true })("bash", { command: "git push" })).toBe("allow")
  })
  test("module gate blocks write of an unapproved source", async () => {
    expect(await guards("build")("write", { filePath: path.join(proj, "main.tf"), content: tf("cloudposse/vpc/aws") })).toMatch(/not on the approved list/)
  })
  test("module gate allows an approved source", async () => {
    expect(await guards("build")("write", { filePath: path.join(proj, "main.tf"), content: tf("terraform-aws-modules/vpc/aws") })).toBe("allow")
  })
  test("module gate checks edit newString", async () => {
    expect(await guards("implementer")("edit", { filePath: "main.tf", oldString: "", newString: tf("evil/x/aws") })).toMatch(/not on the approved list/)
  })
  test("module gate checks apply_patch", async () => {
    const patchText = `*** Begin Patch\n*** Add File: net.tf\n+module "m" {\n+  source = "evil/x/aws"\n+}\n*** End Patch`
    expect(await guards("build")("apply_patch", { patchText })).toMatch(/not on the approved list/)
  })
  test("module gate off via settings", async () => {
    expect(await guards("build", { pushGate: true, moduleGate: false })("write", { filePath: "main.tf", content: tf("evil/x/aws") })).toBe("allow")
  })
  test("unknown agent blocks", async () => {
    expect(await guards(undefined)("read", { filePath: "README.md" })).toMatch(/could not tell which agent/)
  })
  test("agent looked up through the client when not seen yet", async () => {
    const g = createGuards({ directory: proj, lookupAgent: async () => "iam-tightener" })
    await expect(g.before({ tool: "edit", sessionID: "new", callID: "c" }, { args: {} })).rejects.toThrow(/may not use the edit tool/)
  })
  test("a missing hook script blocks (fail closed)", () => {
    expect(() => runHook("no-such-hook.sh", [], {}, proj)).toThrow(/not found/)
  })
})

describe("read-only subagents", () => {
  test("a reviewer can't redirect into files", async () => {
    expect(await guards("security-reviewer")("bash", { command: "git diff > /tmp/x" })).toMatch(/read-only/)
  })
  test("a reviewer can pipe and discard stderr", async () => {
    expect(await guards("security-reviewer")("bash", { command: "git diff --merge-base main 2>/dev/null | head -n 200" })).toBe("allow")
  })
  test("implementer and test-runner may redirect", async () => {
    expect(await guards("implementer")("bash", { command: "echo x > notes.txt" })).toBe("allow")
    expect(await guards("test-runner")("bash", { command: "pytest > out.txt" })).toBe("allow")
  })
  test("the primary agent may redirect", async () => {
    expect(await guards("build")("bash", { command: "echo x > notes.txt" })).toBe("allow")
  })
})

describe("AWS agents", () => {
  test("iam-tightener: its read-only aws calls pass", async () => {
    expect(await guards("iam-tightener")("bash", { command: "aws iam get-role --role-name x" })).toBe("allow")
  })
  test("iam-tightener: cost calls are out of scope", async () => {
    expect(await guards("iam-tightener")("bash", { command: "aws ce get-cost-and-usage" })).toMatch(/aws-readonly-guard/)
  })
  test("cost-analyst: writes blocked", async () => {
    expect(await guards("cost-analyst")("bash", { command: "aws iam delete-role --role-name x" })).toMatch(/aws-readonly-guard/)
  })
  test("cost-analyst: edit and webfetch blocked", async () => {
    expect(await guards("cost-analyst")("edit", { filePath: "main.tf" })).toMatch(/may not use the edit tool/)
    expect(await guards("cost-analyst")("webfetch", { url: "https://x" })).toMatch(/may not use the webfetch tool/)
  })
  test("reads: project files yes, .env and outside no", async () => {
    const g = guards("iam-tightener")
    expect(await g("read", { filePath: path.join(proj, "main.tf") })).toBe("allow")
    expect(await g("read", { filePath: path.join(proj, ".env") })).toMatch(/secrets/)
    expect(await g("read", { filePath: "/etc/passwd" })).toMatch(/outside the project/)
  })
  test("grep across a directory needs a safe include", async () => {
    const g = guards("cost-analyst")
    expect(await g("grep", { pattern: "x", path: proj })).toMatch(/safe file filter/)
    expect(await g("grep", { pattern: "x", path: proj, include: "*.tf" })).toBe("allow")
  })
  test("glob outside the project blocked", async () => {
    expect(await guards("cost-analyst")("glob", { pattern: "~/.aws/*" })).toMatch(/outside the project/)
  })
  test("list stays in the project", async () => {
    expect(await guards("cost-analyst")("list", { path: "/root" })).toMatch(/outside the project/)
  })
  test("aws-researcher: docs MCP tools yes, shell no", async () => {
    const g = guards("aws-researcher")
    expect(await g("aws-docs_search_documentation", { search_phrase: "eks" })).toBe("allow")
    expect(await g("bash", { command: "ls" })).toMatch(/may not use the bash tool/)
  })
})

describe("security-remediator", () => {
  const g = () => guards("security-remediator")
  test("terraform apply blocked", async () => expect(await g()("bash", { command: "terraform apply -auto-approve" })).toMatch(/remediator guard: .* is not allowed/))
  test("local checks allowed", async () => expect(await g()("bash", { command: "terraform fmt -check" })).toBe("allow"))
  test("edits to guardrails blocked", async () => {
    expect(await g()("edit", { filePath: path.join(proj, ".opencode", "plugin", "powerhouse.js"), oldString: "a", newString: "b" })).toMatch(/guardrail/)
    expect(await g()("write", { filePath: path.join(proj, "opencode.json"), content: "{}" })).toMatch(/guardrail/)
    expect(await g()("write", { filePath: path.join(proj, "AGENTS.md"), content: "x" })).toMatch(/guardrail/)
  })
  test("edits to code allowed", async () => expect(await g()("edit", { filePath: path.join(proj, "main.tf"), oldString: "", newString: "# x" })).toBe("allow"))
  test("reading .env blocked", async () => expect(await g()("read", { filePath: path.join(proj, ".env") })).toMatch(/secrets/))
  test("other tools blocked", async () => expect(await g()("apply_patch", { patchText: "" })).toMatch(/may not use/))
  test("keeps the module gate when it's off for everyone else", async () => {
    const off = guards("security-remediator", { pushGate: true, moduleGate: false })
    expect(await off("write", { filePath: path.join(proj, "main.tf"), content: tf("evil/x/aws") })).toMatch(/not on the approved list/)
  })
})

describe("subagent limiter", () => {
  test("max 1 runs task calls one at a time", async () => {
    const lim = createLimiter({ max: 1 })
    const order = []
    const run = async (id) => {
      await lim.acquire(id, "parent")
      order.push(`start ${id}`)
      await new Promise((r) => setTimeout(r, 20))
      order.push(`end ${id}`)
      lim.release(id)
    }
    await Promise.all([run("a"), run("b"), run("c")])
    expect(order).toEqual(["start a", "end a", "start b", "end b", "start c", "end c"])
  })
  test("max 2 overlaps two", async () => {
    const lim = createLimiter({ max: 2 })
    await lim.acquire("a", "p")
    await lim.acquire("b", "p")
    let third = false
    const p = lim.acquire("c", "p").then(() => { third = true })
    await new Promise((r) => setTimeout(r, 10))
    expect(third).toBe(false)
    lim.release("a")
    await p
    expect(third).toBe(true)
  })
  test("the parent going idle releases its permits", async () => {
    const lim = createLimiter({ max: 1 })
    await lim.acquire("a", "p1")
    lim.sessionDone("p1")
    await lim.acquire("b", "p2")
    expect([...lim.held.keys()]).toEqual(["b"])
  })
  test("a waiter is cancelled when its session goes idle", async () => {
    const lim = createLimiter({ max: 1 })
    await lim.acquire("a", "other")
    const waiting = lim.acquire("b", "p")
    await new Promise((r) => setTimeout(r, 5))
    lim.sessionDone("p")
    await expect(waiting).rejects.toThrow(/cancelled/)
  })
  test("a stale permit expires", async () => {
    let t = 0
    const lim = createLimiter({ max: 1, staleMs: 100, now: () => t })
    await lim.acquire("a", "p")
    t = 1000
    await lim.acquire("b", "p")
    expect([...lim.held.keys()]).toEqual(["b"])
  })
  test("POWERHOUSE_MAX_SUBAGENTS is clamped to 1..2", () => {
    expect(maxSubagents({})).toBe(1)
    expect(maxSubagents({ POWERHOUSE_MAX_SUBAGENTS: "2" })).toBe(2)
    expect(maxSubagents({ POWERHOUSE_MAX_SUBAGENTS: "8" })).toBe(2)
    expect(maxSubagents({ POWERHOUSE_MAX_SUBAGENTS: "0" })).toBe(1)
    expect(maxSubagents({ POWERHOUSE_MAX_SUBAGENTS: "x" })).toBe(1)
  })
})

describe("helpers", () => {
  test("taskResult unwraps opencode's task output", () => {
    expect(taskResult('<task id="s" state="completed">\n<task_result>\nNo findings.\n</task_result>\n</task>')).toBe("No findings.")
    expect(taskResult("plain")).toBe("plain")
  })
  test("readSettings defaults both gates on", () => {
    expect(readSettings(path.join(work, "missing.json"))).toEqual({ pushGate: true, moduleGate: true })
    writeFileSync(path.join(work, "s.json"), '{"pushGate": false}')
    expect(readSettings(path.join(work, "s.json"))).toEqual({ pushGate: false, moduleGate: true })
    writeFileSync(path.join(work, "bad.json"), "{nope")
    expect(readSettings(path.join(work, "bad.json"))).toEqual({ pushGate: true, moduleGate: true })
  })
})

describe("plugin entry point", () => {
  test("exports only the plugin (opencode calls every export)", () => {
    expect(Object.keys(pluginModule)).toEqual(["PowerhousePlugin"])
  })
  test("tracks agents, caps task calls and saves reviewer results", async () => {
    const hooks = await pluginModule.PowerhousePlugin({ directory: proj, worktree: proj, client: { session: { messages: async () => ({ data: [] }) } } })
    for (const k of ["chat.params", "tool.execute.before", "tool.execute.after", "shell.env", "event"]) expect(typeof hooks[k]).toBe("function")
    await hooks["chat.params"]({ sessionID: "main", agent: "build" })
    const args = { subagent_type: "security-reviewer", prompt: "x", description: "y", background: true }
    await hooks["tool.execute.before"]({ tool: "task", sessionID: "main", callID: "t1" }, { args })
    expect(args.background).toBe(false)
    await hooks["tool.execute.after"]({ tool: "task", sessionID: "main", callID: "t1", args },
      { title: "", metadata: {}, output: '<task id="s" state="completed">\n<task_result>\nNo findings.\n</task_result>\n</task>' })
    expect(readFileSync(path.join(proj, ".opencode", ".review", "security-reviewer.md"), "utf8")).toBe("No findings.\n")
    await hooks["chat.params"]({ sessionID: "aws", agent: "cost-analyst" })
    const env = {}
    await hooks["shell.env"]({ cwd: proj, sessionID: "aws" }, { env })
    expect(env).toEqual({ AWS_PAGER: "", AWS_PROFILE: "ro" })
    const env2 = {}
    await hooks["shell.env"]({ cwd: proj, sessionID: "main" }, { env: env2 })
    expect(env2).toEqual({})
  })
  test("a non-reviewer task result isn't saved", async () => {
    const hooks = await pluginModule.PowerhousePlugin({ directory: proj, worktree: proj, client: { session: { messages: async () => ({ data: [] }) } } })
    await hooks["chat.params"]({ sessionID: "m", agent: "build" })
    const args = { subagent_type: "planner" }
    await hooks["tool.execute.before"]({ tool: "task", sessionID: "m", callID: "t2" }, { args })
    await hooks["tool.execute.after"]({ tool: "task", sessionID: "m", callID: "t2", args }, { output: "plan" })
    expect(existsSync(path.join(proj, ".opencode", ".review", "planner.md"))).toBe(false)
  })
})
