# eve-map-assistant-dsh

A **DeepSeek Harness (DSH) profile bundle** for the **EVE Static Map Planner**
MCP bridge, compatible with **EVE Map Assistant Plugin 0.6.0** and
**EVE Static Map Planner 1.1.0+**.

It is a pure patch-layer package: installing it adds **one** streamable-http
MCP client (`id: mcp-eve-map`) to a DSH profile, pointing at the planner's
fixed localhost endpoint `http://127.0.0.1:27892/mcp`, and surfaces map tools
to the model as `mcp__eve-static-map__*` (30 tools: system search/info,
normal/capital routes, temporary Wormholes, Views, temporary AI Missions, and
permission-gated Saved Markers).

```
DSH
→ @deepseek-ai/dsh-mcp-client   (the row this bundle inserts)
→ streamable-http (http://127.0.0.1:27892/mcp)
→ EVE Static Map Planner 1.1.0+ (AI Control enabled)
```

## Why this version (0.3.0)

Plugin **0.6.0** adds **Wormhole assistant workflows**: the planner now serves
`list_wormholes` and `create_wormhole`, and both normal-route tools accept
`useWormholes` (returning `wormholeJumps`). Views and AI Missions are
session-only in planner 1.1.0. This bundle needs no config change — the
planner serves its full 30-tool catalog over the same HTTP endpoint and the
MCP client discovers it automatically — but the bundled skill is updated so
agents follow the new rules (list/create only, never remove Wormholes, route
edge options only on explicit request). Version 0.2.0 was the HTTP-transport
migration that replaced the legacy STDIO bridge (`eve-map-mcp.exe`, which the
planner MSI no longer installs).

## Install

### Quick install from GitHub (one command)

```powershell
dsh plugin --profile web add git+https://github.com/zx0003147/EVE-Map-Assistant-DSH.git
```

DSH forwards this to pnpm, which clones the repo and installs the bundle
through the official plugin mechanism — no packing, no manual PATH or MCP
configuration. Optionally copy the skill so every session knows how to use the
tools:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.dsh\skills\eve-map-assistant" | Out-Null
Copy-Item .dsh\skills\eve-map-assistant\SKILL.md "$env:USERPROFILE\.dsh\skills\eve-map-assistant\SKILL.md"
```

(If you work with this repository as your DSH workspace, the project-level
skill at `.dsh/skills/` is discovered automatically — no copy needed.)

Then **restart DSH** and open a **new conversation**.

### Install from a local checkout

```powershell
.\install.ps1 -Profile web               # installs from GitHub
.\install.ps1 -Profile web -FromCheckout # packs this checkout into a tarball first
```

`install.ps1` installs the bundle, copies the skill into the DSH home, and
runs `verify.ps1`. Pass `-DryRun` to check everything without changing
anything.

### Prerequisites

- **EVE Static Map Planner 1.1.0 or later**, running with
  **Preferences > AI Control** enabled. Saved Marker reads/creates
  additionally need **Preferences > AI Control > Saved Marker Access**.
- A working DSH installation (>= 0.1.1-rc.2) with a profile (default `web`).
- `pnpm` and `git` available on PATH (used by `dsh plugin add` and the
  installer), plus Node.js.

## Verify

```powershell
.\verify.ps1 -Profile web
```

Non-destructive. Confirms the bundle is installed, the profile composes one
`mcp-eve-map` row with `serverName = eve-static-map`,
`transport = streamable-http`, `url = http://127.0.0.1:27892/mcp`, and no
absolute paths or credentials anywhere in the configuration.

## Upgrade / Uninstall

- **Upgrade**: run the quick-install command again
  (`dsh plugin --profile web add git+https://github.com/zx0003147/EVE-Map-Assistant-DSH.git`,
  or `.\install.ps1 -Profile web`) after a new release, then restart DSH.
- **Uninstall**: `dsh plugin --profile web remove eve-map-assistant-dsh`
  (or `.\uninstall.ps1 -Profile web`). It touches only this bundle.

## Using the tools

1. Start EVE Static Map Planner 1.1.0+ and enable **AI Control**.
2. Install this bundle, **restart DSH**, open a **new conversation**.
3. Use the `mcp__eve-static-map__*` tools — exactly the planner's 30-tool
   catalog; this bundle adds none.

Ask naturally: `Jita 在哪？`, `Jita 到 Amarr 怎么走？`, `把 1DQ1-A 标成红色危险`,
`现在有哪些虫洞？`, `加一条 1DQ1-A 到 NOL-M9 的虫洞`.

Wormhole AI access is intentionally limited (list + create only; removal is a
manual action in Wormhole Manager or the system right-click menu), and
`useWormholes`/`useAnsiblex` route options apply only when the user asks for
that edge type.

### When the planner is not running

The MCP client registers no tools and retries with backoff while the planner
is offline; the moment the planner starts with AI Control, tools appear.
Actual map-changing calls against a disconnected planner return
`APP_DISCONNECTED` — start the map and enable AI Control instead of working
around it.

## License

MIT — see [LICENSE](./LICENSE).
