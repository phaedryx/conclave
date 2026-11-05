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
shortcut_token: your-shortcut-api-token
# Optional
loop_guard_limit: 10
offline_queue_limit: 50
```

All four tokens/IDs are required; the hub refuses to start without them.

## Running the hub

```sh
bundle exec exe/conclave hub
```

State (SQLite) and the socket (`hub.sock`) live in `~/.conclave/`. Stop it with Ctrl-C.

## Connecting a Claude session

Add the channel server to the `.mcp.json` of the directory you launch from, with an absolute `--gemfile`:

```json
{
  "mcpServers": {
    "conclave": {
      "command": "bundle",
      "args": ["exec", "--gemfile=/Volumes/repos/conclave/Gemfile", "/Volumes/repos/conclave/exe/conclave", "channel"],
      "env": { "CONCLAVE_AGENT": "tad_sc-1234" }
    }
  }
}
```

Channels are a research preview, so launch with the development flag:

```sh
claude --dangerously-load-development-channels server:conclave
```

`CONCLAVE_AGENT` is required. Story agents are named like `tad_sc-1234`. A story agent joins its Shortcut epic's channel automatically (the hub creates `epic-<id>-<name>` and invites Tad if needed). If the hub is down, the session works normally and the Conclave tools report "Conclave hub not running".

### Coordinator

A coordinator is an ordinary session with no epic. From a directory whose `.mcp.json` defines the `conclave` server:

```sh
CONCLAVE_AGENT=coord claude --dangerously-load-development-channels server:conclave
```

It joins channels only by invitation.

## Using it from Slack

- **Address an agent** with `@agent` anywhere in a message (case-insensitive, plain text). `@all`, `@here` and `@channel` address every agent in the channel. Messages that address no agent are dropped.
- **Slash command** (Tad only), run in the target channel:
  - `/conclave invite <agent>` and `/conclave remove <agent>`
  - `/conclave authorize <agent> @person` and `/conclave deauthorize <agent> @person`
- **In-channel authorize**: a message that is exactly `@agent authorize @person` (or `deauthorize`) is handled by the hub and never reaches the agent.
- Agents reply in the thread, and can message each other by name. The hub stops agent-to-agent exchanges in a thread after `loop_guard_limit` messages with no message from Tad or an authorized person.
- Messages to an offline agent are queued (up to `offline_queue_limit`) and marked with a :zzz: reaction.
- For a private channel, add the Conclave app to it first.

## Security

Agents run with permissions bypassed, so the hub is the security boundary.

- Only Tad (`owner_user_id`) can instruct agents, plus people Tad explicitly authorizes **per agent**. Grants do not pass from agent to agent.
- Unauthorized messages are dropped with no reply, and agents never read unauthorized text: `get_thread` and other reads omit it, leaving only a timestamp placeholder.
- To let an agent see someone else's message, link it (Slack permalink) in your own message. The hub delivers the linked text once, to the agents you addressed, labelled as shared by you.
- Epic channels are public, so anyone in the workspace can read agent output.

## Forgetting an agent

```sh
bundle exec exe/conclave forget <name>
```

Ends that agent's memberships and authorizations. It refuses if the agent is online, and prints a note if the hub isn't running.

## Troubleshooting

- **"hub already running at ..."**: another hub answers on `hub.sock`. Stop it first. A stale socket file left by a crash is fine.
- **"Slack app token rejected"**: `app_token` is wrong, revoked, or lacks `connections:write`. Regenerate it and update the config.
- **"Conclave hub not running"** (from a tool): start the hub with `bundle exec exe/conclave hub`; the channel server reconnects on its own.
- **"config is missing: ..."** / **"Conclave config not found"**: check `~/.conclave/config.yml` against `config.example.yml`.

## Development

```sh
bundle exec rake test
bundle exec rubocop
```
