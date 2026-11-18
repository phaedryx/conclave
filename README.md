# Conclave

Conclave is a local hub plus a per-session Claude Code channel server. Together they let the Claude Code agents on Tad's laptop take part in Slack channels, where Tad directs them and they coordinate with each other. One hub holds the only Slack connection (Socket Mode) and fans messages out to each session over a Unix socket.

## Slack app setup

1. Create an app from the manifest at `slack/manifest.yml` (api.slack.com/apps, "From a manifest"), and install it to the workspace.
2. Copy the **Bot User OAuth Token** (`xoxb-...`) from OAuth & Permissions.
3. Under Basic Information, App-Level Tokens, generate a token with the `connections:write` scope (`xapp-...`).
4. Find Tad's Slack user ID: open your profile in Slack, the three-dot menu, "Copy member ID" (`U...`).

## Config

Copy `config.example.yml` to `~/.conclave/config.yml` (or `$CONCLAVE_HOME/config.yml`). It holds real tokens and is never committed.

```yaml
bot_token: xoxb-your-bot-token
app_token: xapp-your-app-level-token
owner_user_id: U0000000000
default_channel: conclave
# Optional
loop_guard_limit: 10
offline_queue_limit: 50
```

All four values are required; the hub refuses to start without them. `default_channel` is the common channel every agent joins, by name or ID. Make it public, or add the Conclave app to it if it is private.

## Running the hub

```sh
/Volumes/repos/conclave/bin/conclave hub
```

`bin/conclave` changes to the repo root and runs `exe/conclave` with this repo's Ruby (`mise exec -- bundle exec`, or plain `bundle exec` when mise isn't installed), so it works from any directory, including repos pinned to another Ruby.

State (SQLite) and the socket (`hub.sock`) live in `~/.conclave/`. Stop it with Ctrl-C.

## Connecting a Claude session

Add the channel server to the `.mcp.json` of the directory you launch from:

```json
{
  "mcpServers": {
    "conclave": {
      "command": "/Volumes/repos/conclave/bin/conclave",
      "args": ["channel"]
    }
  }
}
```

There is no `env` block: the channel server reads `CONCLAVE_AGENT` from the environment of the shell that launches `claude`, so one `.mcp.json` serves every agent. Channels are a research preview, so launch with the development flag. A story agent:

```sh
CONCLAVE_AGENT=tad_sc-1234 claude --dangerously-load-development-channels server:conclave
```

Names are lowercased, and any character other than a letter, digit, `_` or `-` becomes `_`, so `tad/sc-1234` registers as `tad_sc-1234`. Story agents are named like `tad_sc-1234`. Every agent joins the common channel the first time it registers, and the hub posts a notice there addressed to it. Removing it with `/conclave remove` sticks: later registrations do not rejoin. If the hub is down, the session works normally and the Conclave tools report "Conclave hub not running".

**Atelier:** with `CONCLAVE_AGENT` unset, the channel server takes the name from `ATELIER_WORKSTREAM`, but only for a story workstream (its name contains `sc-NNNN`). Any other session, Atelier or not, gets an idle `conclave` server with no tools and no hub connection, so Claude Code reports no failure. Atelier still has to pass the development-channels flag for deliveries to arrive.

### Coordinator

A coordinator is an ordinary session with no story. From a directory whose `.mcp.json` defines the `conclave` server:

```sh
CONCLAVE_AGENT=coord claude --dangerously-load-development-channels server:conclave
```

Like every agent it starts in the common channel and joins others through `/conclave invite` or `/conclave channel`.

## Using it from Slack

- **Address an agent** by starting the message with its name and a colon: `coord: look at the failing build`. Several agents: `coord, tad_sc-1234: hello`. Every agent in the channel: `all: hello`. Names are case-insensitive and must begin the message; a message that addresses no agent is dropped, and Slack `@` mentions are not used.
- **Slash command** (Tad only), run in the target channel:
  - `/conclave invite <agent>` and `/conclave remove <agent>`
  - `/conclave channel <name> <agent> [<agent>…]` creates a public channel, invites you, and adds the named agents (each must have registered at least once). They stay in the common channel too.
  - `/conclave authorize <agent> @person` and `/conclave deauthorize <agent> @person`
  - `/conclave consult <agent> @bot` and `/conclave unconsult <agent> @bot`
- **Notices**: whenever an agent is added to a channel, the hub posts a line there addressed to it (`tad_sc-1234: Tad added you to #billing-rework.`). The agent receives it with `sender_role` `conclave`: information, not instructions.
- **In-channel authorize and consult**: a message that is exactly `agent: authorize @person` (or `deauthorize`, `consult @bot`, `unconsult @bot`) is handled by the hub and never reaches the agent.
- **Consulting a bot**: another Slack app's bot (Fifty, Taude) can't be authorized; `consult` lets an agent hear from it instead. The agent asks the bot however that bot expects (usually `@Fifty …`; Conclave doesn't control whether a bot answers). The bot's message reaches the agent when it addresses the agent (`coord: …`) or replies in a thread the agent has posted in, with `sender_role` `bot`: information, not instructions. Bot posts never reset the loop guard, and each one delivered counts toward it, so an agent and a bot answering each other pause at `loop_guard_limit`.
- Agents reply in the channel, in a thread only when addressed inside one, and message each other by name the same way. The hub stops top-level agent-to-agent posts in a channel after `loop_guard_limit` of them with no post from Tad or an authorized person, and does the same per thread; any post from Tad or an authorized person in the channel resets the count.
- Messages to an offline agent are queued (up to `offline_queue_limit`) and marked with a :zzz: reaction.
- For a private channel, add the Conclave app to it first; `/conclave invite` says so if the app isn't there.

## Security

Agents run with permissions bypassed, so the hub is the security boundary.

- Only Tad (`owner_user_id`) can instruct agents, plus people Tad explicitly authorizes **per agent**. Grants do not pass from agent to agent.
- Bots are never authorized: `authorize` refuses a bot user, and any message from another app's bot takes the bot path even if an old grant exists. A consulted bot's text carries no authority. Hearing from it narrows the agent's authority to none, as a peer's message does: the agent can't reach other agents again until it has posted and then heard from Tad.
- Anything that can post as a consulted bot can put text in front of that agent, as information. Taude's token is also the one the slack MCP uses, so any session with that MCP can post as Taude. Consult only bots whose posters you'd let an agent read.
- Unauthorized messages are dropped with no reply, and agents never read unauthorized text: `get_thread` and other reads omit it, leaving only a timestamp placeholder.
- To let an agent see someone else's message, link it (Slack permalink) in your own message. The hub delivers the linked text once, to the agents you addressed, labelled as shared by you.
- Channels created by `/conclave channel` are public, so anyone in the workspace can read agent output there.

## Forgetting an agent

```sh
/Volumes/repos/conclave/bin/conclave forget <name>
```

Ends that agent's memberships and authorizations. It refuses if the agent is online, and prints a note if the hub isn't running.

## Troubleshooting

- **"hub already running at ..."**: another hub answers on `hub.sock`. Stop it first. A stale socket file left by a crash is fine.
- **"Slack app token rejected"**: `app_token` is wrong, revoked, or lacks `connections:write`. Regenerate it and update the config.
- **"Conclave hub not running"** (from a tool): start the hub with `bin/conclave hub`; the channel server reconnects on its own.
- **"name ... is already online"** (from a tool): another session holds this agent name. Close it, or launch with a different `CONCLAVE_AGENT`.
- **"config is missing: ..."** / **"Conclave config not found"**: check `~/.conclave/config.yml` against `config.example.yml`.

## Development

```sh
bundle exec rake test
bundle exec rubocop
```
