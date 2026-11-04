# Conclave — Design

Date: 2026-11-04
Status: Approved by Tad 2026-11-04

## Intent

Conclave lets the Claude Code agents running on Tad's laptop take part in Slack channels. In those
channels Tad can direct them, and they can coordinate with each other.

Today Atelier gives every agent a worktree. A coordinating agent doesn't have one, so Atelier has to
fake one for it. That mixes two different roles into one shape. Tad also runs a coordinator for
every effort just in case he wants one later. Agents reach each other through relays and Atelier
"nudges" when direct conversation would work better.

Conclave makes coordination a role that anyone can fill: Tad, a coordinating agent started by
hand, or nobody. Slack becomes the shared room. Tad can message one agent or a group, and agents
can message each other, without anyone relaying.

## Goals

- **Epic channels.** Each Shortcut epic gets a Slack channel. When a story agent for that epic starts,
  it joins the epic's channel automatically. If the channel doesn't exist yet, Conclave creates it
  and invites Tad.
- **Invitations.** Tad can invite any agent into any channel. This covers stories with no epic,
  agents from another epic, and the coordinator. An agent can be in several channels at once.
- **Addressed-only listening.** An agent receives a message only when the message names it
  (`@tad_sc-1234`) or uses `@all`, `@here` or `@channel`. Everything else is invisible to agents, so
  humans can talk freely in the channel.
- **Direct agent-to-agent messaging.** Agents address each other the same way Tad does, in the same
  channels, so Tad can follow the exchange.
- **Ephemeral agents, one Slack app.** One Slack app posts under a different name and avatar for each
  agent (`chat:write.customize`). Agents come and go with no Slack admin work.
- **Tad-only control.** Only Tad can give agents instructions unless he authorizes another person.
  The agents run with permissions bypassed, so this is the security boundary of the whole system.

## Non-goals

- Starting agents from Slack. Tad creates agents on his laptop, through Atelier or by hand.
- Replacing Atelier's task queue, whiteboard or workstream management. Conclave replaces the need
  for nudges and relays between agents that share a channel. Atelier's `send_message` keeps working.
- Hosting anything in the cloud, or serving several people's laptops from one hub. This is one
  person's laptop and one Slack app.
- Real Slack users or real `@`-mentions for agents. Agent names are plain text, with no
  autocomplete. Tad accepted this to avoid creating an app per agent.

## Anti-goals (failure even if it technically works)

- Anyone other than Tad, or someone he authorized, can get an agent to act.
- Agents react to chatter that wasn't addressed to them.
- Agents talk to each other in an unbounded loop and flood a channel.
- Adding or removing an agent requires any Slack admin step: creating apps, adding bot users, or
  rotating tokens.

## Constraints

- **Claude Code channels is a research preview.** A custom channel has to be loaded with
  `--dangerously-load-development-channels server:<name>`, which only works in interactive
  sessions (not `-p`). If Tad's Claude login belongs to a claude.ai Team or Enterprise org, an
  org Owner must enable Channels, or a managed setting must set `channelsEnabled: true`. The flag
  syntax and protocol may change.
  Docs: https://code.claude.com/docs/en/channels.md and
  https://code.claude.com/docs/en/channels-reference.md
- **Channel protocol.** The server declares `capabilities.experimental['claude/channel'] = {}`
  and `capabilities.tools`. It pushes `notifications/claude/channel` with
  `{ content, meta }`, where meta keys may contain only letters, digits and underscores (keys with
  hyphens are silently dropped). Replies go through ordinary MCP tools on the same server.
  Notifications that arrive while the agent is busy are queued and delivered on its next turn.
- **Each Claude session starts its own channel server process.** Slack Socket Mode hands each event
  to only one of the app's open connections, so the channel servers can't each connect to Slack.
  One local hub must hold the only Slack connection and fan messages out to them.
- **Mentions are text.** `@here` and `@channel` are real Slack mentions and also notify the humans in
  the channel. `@all` exists only in Conclave.

## Decided by Tad

- Each Shortcut epic maps to a Slack channel, which the app creates when the first agent for that
  epic joins.
- Story agents for an epic join its channel. A story with no epic joins nothing automatically, but
  Tad can invite it into channels he created.
- An agent's name is the short worktree name, for example `tad_sc-1234`. It is not the full branch
  name.
- Agents ignore any message that doesn't address them. `@here` and `@all` address every agent in the
  channel.
- Agents message each other directly by name.
- There is one Slack app, with no app per agent.
- Agents are created on the laptop, never from Slack.
- Only Tad can instruct agents, unless he **authorizes** a specific person. The word is "authorize",
  not "allow".
- The coordinator is a plain Claude session Tad starts without a worktree, usually from the project
  root.
- Conclave is its own project, at `/Volumes/repos/conclave`.
- Atelier is Tad's app and can change to support this.

## Architecture (Claude's call)

The default language is Ruby, matching `slack-mcp`. The Slack Web API client is copied from
`/Volumes/repos/slack-mcp/main/lib/slack_mcp/client.rb` (plain httpx, no Slack gem) rather than
taken as a dependency. The `mcp` gem (0.13.0) accepts custom `capabilities` and exposes
`transport.send_notification`, which covers the channel protocol. The builder should confirm this
with a spike before going further.

```
 Slack (Socket Mode + Web API)
          │  one connection
          ▼
   ┌──────────────┐   Shortcut API (story → epic)
   │ conclave hub │──────────────────────────────
   └──────────────┘
     │ local Unix socket (~/.conclave/hub.sock), newline-delimited JSON
     ├────────────────┬────────────────┐
     ▼                ▼                ▼
 conclave channel  conclave channel  conclave channel     (stdio MCP server,
 in tad_sc-1234    in tad_sc-5678    in coord              one per Claude session)
```

### Hub (`conclave hub`)

One long-running process per laptop. It is the only part of Conclave that talks to Slack. It:

- Holds the Socket Mode connection and receives message events and the `/conclave` slash command.
- Accepts channel-server connections on the local socket. Each connection registers with an agent
  name.
- On a story agent's first registration, takes the story id from its name (`sc-NNNN`), looks up the
  story's epic in Shortcut, and finds or creates that epic's channel. The channel name is
  `epic-<id>-<slugged epic name>`, truncated to fit Slack's limit. When it creates a channel, it
  invites Tad.
- Persists state in a local SQLite file: channel ↔ epic, agent memberships, authorizations, and the
  last-seen message timestamp per channel.
- Routes inbound messages using the rules under Addressing and Authorization.
- Posts outbound messages on agents' behalf with `username` set to the agent name and a stable
  per-agent avatar. The avatar's form is the builder's call.
- Delivers agent-to-agent messages internally when an agent posts. It ignores the echo of its own
  posts that comes back from Slack (`bot_id` equals its own), so nothing is delivered twice.

### Channel server (`conclave channel`)

A stdio MCP server that Claude Code launches inside each session. It gets its agent name from the
`CONCLAVE_AGENT` env var, connects to the hub, and:

- Pushes each message routed to it into the session as a channel notification. Content is the
  message text. Meta includes `channel`, `channel_id`, `thread_ts`, `ts`, `sender`,
  `sender_role` (`owner`, `authorized` or `agent`) and `authority` (see Authorization).
- Exposes these tools:
  - `send_message(channel, text, thread_ts?)` posts as this agent. Names in the text address
    other agents.
  - `get_thread(channel, thread_ts)` reads recent context.
  - `list_channels()` lists this agent's channels.
  - `list_agents(channel)` lists the agents in a channel and whether each one is online.
- Sends `instructions` telling the agent:
  - Messages arrive only when it is addressed.
  - Reply in the same thread.
  - Post when it is blocked, when it finishes, or when it needs another agent.
  - Give each message the weight its `sender_role` allows (see Authorization).
- If the hub isn't running, the channel server stays up and its tools return a clear "hub not
  running" error. The agent's normal work isn't affected.

### Addressing

- A message addresses agent X when it contains the token `@X`, matched on word boundaries, anywhere
  in the text. Matching is case-insensitive.
- `@all`, `@here` and `@channel` (Slack's encoded `<!here>` and `<!channel>`) address every agent in
  that channel.
- A message that addresses no agent is dropped and delivered to nobody.
- Threads: when an agent is addressed at the top level of a channel, it replies in that message's
  thread. When it is addressed inside a thread, it replies in that thread. Messages that agents
  start themselves go top-level unless they pass `thread_ts`.

### Authorization

- The hub delivers a message only when its sender is Tad (a Slack user ID in config), an agent
  (an internal post), or a person Tad has authorized for the addressed agent.
- **Grants are explicit and do not pass from agent to agent (Tad's decision).** Every message
  carries an *authority*: the human whose request it ultimately serves. A message Tad sends carries
  Tad. A message Jane sends carries Jane. A message an agent posts carries the authority of the
  message it was handling. The channel server tracks this. The agent's current authority is the
  authority of the most recent delivered message it is responding to. An agent can override this
  only to *lower* the authority, never to raise it. The hub delivers an agent's post to another agent
  only if that post's authority is Tad, or a person explicitly authorized for the receiving agent.
  So Jane, authorized for `tad_sc-1234`, can't reach `tad_sc-5678` by asking `tad_sc-1234` to pass
  her request along. Exactly how authority follows a multi-message turn is the builder's call, but
  when in doubt it should fall back to the most restrictive authority, not Tad.
- `@tad_sc-1234 authorize @jane` and `@tad_sc-1234 deauthorize @jane` are commands that only Tad
  can issue. The hub handles them itself and never passes them to the agent. A grant applies to
  that one agent. `/conclave authorize tad_sc-1234 @jane` does the same thing.
- A dropped message gets no reply in the channel, so outsiders can't probe the agents.
- `@all`, `@here` or `@channel` from an authorized person reaches only the agents that person is
  authorized for. (Claude's call)
- Each delivered message carries `sender_role` in meta: `owner` (Tad), `authorized`, or `agent`.
  The channel server's instructions tell the agent how much weight to give each one. A message from
  `owner` carries the same weight as Tad typing in the terminal. A message from `authorized` is an
  instruction within the scope of that agent's own story. A message from `agent` is a request from
  a peer: the agent should act on it when it fits its own work and push back when it doesn't.
  (Claude's call)
- **Agents never read unauthorized text (Tad's decision).** `get_thread` and every other read goes
  through the hub and returns only messages from Tad, from agents, and from people authorized for
  the reading agent. Other posts are left out. Each left-out post is replaced by a placeholder that
  gives only its timestamp, so the agent knows something was there.
- **Approving a message for one agent (Tad's decision, mechanism is Claude's call).** When Tad sends
  an agent a message that contains Slack message links (permalinks), the hub fetches each linked
  message and delivers its text along with Tad's message. Each one is labeled as shared by Tad, with
  its original author. The approval covers only those linked messages, only for the agents
  addressed in Tad's message, and only that once. It grants no ongoing access to that person or
  thread. Links to channels the bot can't read return a clear error to Tad, not an empty result.

### Membership and lifecycle

- **Online and offline.** An agent is online while its channel server is connected to the hub.
  Membership outlives the session. When Atelier resumes the session, the agent comes back to the
  same channels.
- **Joining.** A story agent joins its epic channel automatically. Any other channel requires an
  invitation: `/conclave invite tad_sc-1234` or `/conclave remove tad_sc-1234`, run in the target
  channel, and only by Tad. In a public channel the bot isn't in yet, the hub joins with
  `conversations.join`. For a private channel, Tad adds the app first, and the hub says so if he
  hasn't.
- **Messages to offline agents.** The hub queues these, with a per-agent cap, and delivers them when
  the agent reconnects. It adds a 💤 reaction so Tad can see the message is waiting.
- **Leaving.** An agent's memberships end when Tad removes it or when its worktree is deleted.
  Atelier tells the hub on purge. Its old messages stay in Slack.
- **Missed events.** Socket Mode doesn't replay events from while the hub was down. Whether to
  backfill from `conversations.history` since the last-seen timestamp is the builder's call, and
  backfilled messages still go through the same addressing and authorization rules.
- **Loop guard.** The hub stops delivering agent-to-agent messages in a thread after N exchanges
  with no message from Tad or an authorized person (N=10 by default, configurable), and posts a note
  asking Tad to step in. Posts from anyone else don't reset the count. (Claude's call)

### Agent names

- **Story agents.** Name = `<owner>_sc-<id>` taken from the worktree or branch name. For example,
  `tad_sc-1234-fix-the-thing` becomes `tad_sc-1234`. If no `sc-NNNN` is found, the full worktree name
  is used.
- **Coordinator.** Started by hand with `CONCLAVE_AGENT=coord` (or any name Tad picks) and the
  launch flag. It has no epic, so it joins channels by invitation like any other agent. A
  `conclave claude <name>` wrapper that sets the env var and flags is suggested but is the
  builder's call.
- **Collisions.** If a second session registers a name that is already online, the hub refuses it
  with a clear error.

### Slack app

- The app is named **Conclave** and lives in the **SixFifty workspace**. Epic channels are
  **public** (Tad's decision). Anyone in the workspace can read agent output. Only Tad and people he
  authorizes can direct the agents, and agents only ever read authorized text. Tad has installed
  an app (Taude) in this workspace before without workspace admin approval.
- The manifest is in `slack/manifest.yml`.
- One app with Socket Mode on. It needs an app-level token (`xapp-`, `connections:write`) and a
  bot token (`xoxb-`).
- Bot scopes: `chat:write`, `chat:write.customize`, `channels:manage`, `channels:join`,
  `channels:read`, `channels:history`, `groups:read`, `groups:history`, `reactions:write`,
  `users:read`, `commands`.
- Events: `message.channels`, `message.groups`. Slash command: `/conclave`.
- Config lives in `~/.conclave/config.yml` (Slack tokens, Tad's Slack user ID, Shortcut token) and is
  never committed. A `config.example.yml` is committed.

## Atelier changes

The code is in `/Volumes/repos/Atelier`. Agent launch is built in
`Sources/Views/TerminalContainerView.swift` `buildClaudeCommand()`, and the per-workstream MCP
config in `Sources/Models/IPC/IPCConfig.swift`.

- Add a Conclave setting, per project or global (the builder's call). When it's on, a story
  workstream's agent launch:
  - adds a `conclave` stdio server to the per-workstream MCP config, with `CONCLAVE_AGENT` set to
    the workstream name
  - adds `--dangerously-load-development-channels server:conclave` to both the `--resume` and the
    fresh command
- When a workstream is purged, notify the hub so that agent's memberships end. This can be a
  `conclave forget <name>` CLI call.
- If the hub isn't installed or running, launch still works.

## Suggested build order

1. **Spike.** A Ruby channel server that pushes a hard-coded notification into an interactive Claude
   session through the development flag. This proves the `mcp` gem handles the experimental
   capability and that Tad's account and org allow channels. If this fails, stop and report.
2. Hub with Socket Mode, the local socket, addressing and authorization, tested against one
   channel Tad creates.
3. Epic channels through Shortcut, invitations, and persistence.
4. Atelier integration.
5. Loop guard, offline queue, and optional backfill.

## Left to the builder

- The websocket client library for Socket Mode, and the hub's concurrency model.
- The exact local socket protocol.
- Avatar generation.
- Backfill after hub downtime.
- How the hub runs as a background service (launchd or a plain command).
- The test approach. Slack and Shortcut are stubbed in unit tests, as in `slack-mcp`.
