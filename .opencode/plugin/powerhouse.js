// powerhouse plugin for opencode. The logic lives in ../lib/powerhouse-core.js; see that file's
// header for what each guard does. This file must export only the plugin itself.
import { mkdirSync, writeFileSync } from "node:fs"
import path from "node:path"
import { AWS_AGENTS, REVIEWERS, createGuards, createLimiter, maxSubagents, taskResult } from "../lib/powerhouse-core.js"

export const PowerhousePlugin = async ({ directory, worktree, client }) => {
  const project = worktree && worktree !== "/" ? worktree : directory
  const guards = createGuards({
    directory: project,
    lookupAgent: async (sessionID) => {
      const res = await client.session.messages({ path: { id: sessionID } })
      const msgs = res?.data ?? []
      for (let i = msgs.length - 1; i >= 0; i--) {
        const info = msgs[i]?.info
        if (info?.agent || info?.mode) return info.agent ?? info.mode
      }
    },
  })
  const limiter = createLimiter({ max: maxSubagents() })
  const reviewDir = path.join(project, ".opencode", ".review")

  return {
    "chat.params": async (input) => { if (input.agent) guards.agents.set(input.sessionID, input.agent) },
    "chat.message": async (input) => { if (input.agent) guards.agents.set(input.sessionID, input.agent) },

    "tool.execute.before": async (input, output) => {
      await guards.before(input, output)
      if (input.tool === "task") {
        if (output.args && "background" in output.args) output.args.background = false // the cap needs the task to finish in-call
        await limiter.acquire(input.callID, input.sessionID)
      }
    },

    "tool.execute.after": async (input, output) => {
      if (input.tool !== "task") return
      limiter.release(input.callID)
      const agent = input.args?.subagent_type
      if (REVIEWERS.has(agent)) {
        try {
          mkdirSync(reviewDir, { recursive: true })
          writeFileSync(path.join(reviewDir, `${agent}.md`), taskResult(output?.output) + "\n")
        } catch {
          // merge-findings treats a missing result as a failed reviewer, so the review can't pass
        }
      }
    },

    "shell.env": async (input, output) => {
      const agent = input.sessionID ? await guards.agentOf(input.sessionID) : undefined
      if (AWS_AGENTS[agent]) {
        output.env.AWS_PAGER = ""
        if (process.env.AWS_READONLY_PROFILE) output.env.AWS_PROFILE = process.env.AWS_READONLY_PROFILE
      }
    },

    event: async ({ event }) => {
      if (event?.type === "session.idle" || event?.type === "session.error") {
        const id = event.properties?.sessionID
        if (id) limiter.sessionDone(id)
      }
    },
  }
}

