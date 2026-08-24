# eve-map-assistant-dsh

A **DeepSeek Harness (DSH) profile bundle** for the **EVE Static Map Planner**
MCP bridge. It is a pure patch-layer package: installing it adds **one** stdio
MCP client (`id: mcp-eve-map`) to a DSH profile, which spawns
`eve-map-mcp.exe` from the user `PATH` and surfaces map tools to the model as
`mcp__evemap__*`.

It does **not** repackage or embed the MCP server, does **not** copy the map
executable or a Java runtime, does **not** use PowerShell/raw-STDIO helper
scripts as a runtime fallback, and does **not** hardcode absolute paths, user
names, ports, tokens, or control secrets.

```
DSH
→ @deepseek-ai/dsh-mcp-client   (the row this bundle inserts)
→ STDIO
→ eve-map-mcp.exe               (installed on PATH by the EVE Static Map Planner MSI)
→ secure local discovery/control
→ EVE Static Map Planner
```

---

## How it works

The bundle's `package.json` declares a DSH bundle using the mechanism shipped
with DSH `0.1.1-rc.2` (verified against the locally installed CLI):

```json
"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
```

`dsh plugin --profile <name> add <package>` forwards the add to **pnpm** inside
the profile directory and then reconciles the profile's `dsh.profile.bundles`
layer stack: any dependency whose installed manifest declares `dsh.bundle`
joins the layer stack automatically. `cordis.patch.yml` then becomes one
ordered patch layer of the profile, applied **before** the profile's own
`cordis.patch.yml`, so the user always keeps the last say.

The patch layer inserts exactly one row:

```yaml
- insert:
    - id: mcp-eve-map
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: evemap
        transport: stdio
        command: eve-map-mcp.exe
```

No other tools are added, no custom REST API wraps the tools, and the MCP tool
schemas/count are untouched. Tools appear to the model as `mcp__evemap__*`
(the `mcp__<serverName>__<rawName>` naming scheme of `@deepseek-ai/dsh-mcp-client`).

---

## Prerequisites

1. **EVE Static Map Planner 0.2.2 or later** installed via the Windows MSI.
   The MSI registers its installation directory on the current user's `PATH`,
   which is how `eve-map-mcp.exe` is found. **No Java/JDK is required
   separately** and **no manual MCP port/token configuration** is needed.
2. **A working DeepSeek Harness (DSH) installation** with a profile (default
   `web`). Tested with `@deepseek-ai/dsh` **`0.1.1-rc.2`**; other DSH versions
   may work but are not guaranteed. Either launcher form is supported:
   - `dsh` on `PATH`, **or**
   - `npx --yes @deepseek-ai/dsh` (DSH is then supplied by npm's npx cache —
     **no global install of `@deepseek-ai/dsh` is required**).
3. **pnpm available on PATH** — DSH's plugin subsystem invokes `pnpm` inside
   the profile directory. `npm install -g pnpm` if missing. The installer
   never modifies your global Node environment on its own.
4. **Node.js** (DSH itself requires it; the installer uses `node` for safe YAML
   inspection of patch files).

## Install

From this project directory:

```powershell
.\install.ps1 -Profile web
```

The installer:

1. Verifies `eve-map-mcp.exe` resolves from `PATH`.
2. Verifies a DSH launcher (prefers `dsh` on `PATH`, else `npx --yes @deepseek-ai/dsh`).
3. Verifies `pnpm`.
4. Verifies the requested profile exists under `$DSH_HOME/profiles`.
5. Packs the local bundle (`pnpm pack` → `eve-map-assistant-dsh-<version>.tgz`).
6. Installs it through the official mechanism
   (`dsh plugin --profile <profile> add file:<tarball>`).
7. Verifies the bundle was added to the profile and owns exactly one
   `mcp-eve-map` row with the correct portable configuration.

Pass `-DryRun` to run every check and print the plan without changing
anything. `-DshHome` overrides the DSH home (default: `$env:DSH_HOME`, else
`~/.dsh`).

### Migration of an older manual setup (fail-safe)

If a manually inserted `mcp-eve-map` entry exists in the profile's
`cordis.patch.yml` (the pre-bundle way to configure this), or a **legacy EVE
Map Assistant bundle** from an earlier prototype install is present (e.g. a
broken `@eve-map-assistant/dsh-eve-map-bundle` `file:` dependency whose
tarball no longer exists — such an entry would break pnpm inside the profile),
the installer:

1. detects the old configuration,
2. creates timestamped backups
   (`cordis.patch.yml.bak-<timestamp>`, `package.json.bak-<timestamp>`),
3. installs the new bundle,
4. verifies the bundle successfully owns/provides `mcp-eve-map`,
5. **only then** removes the old manual duplicate / legacy entries.

If the bundle installation or verification fails, the backups are restored and
the previously working manual configuration is **never** destroyed. Unrelated
profile settings are never modified.

## Upgrade

Run `install.ps1` again after bumping the bundle version — the new tarball
(`eve-map-assistant-dsh-<new-version>.tgz`) replaces the old dependency
through the same official mechanism, with the same fail-safe backup behavior.

## Uninstall

```powershell
.\uninstall.ps1 -Profile web
```

Uses the official removal mechanism (`dsh plugin --profile <profile> remove
eve-map-assistant-dsh`, i.e. `pnpm remove` + layer-stack reconciliation).
It removes **only** this bundle: EVE Static Map Planner, map data, DSH
sessions, other DSH plugins, and unrelated profile configuration are never
touched. Backups created by the installer are left in place and their
locations are printed, so a previously manual `mcp-eve-map` configuration can
be restored by hand if you want it back.

## Verify

```powershell
.\verify.ps1 -Profile web
```

Non-destructive; never launches GUI automation. Checks that:

- `eve-map-mcp.exe` resolves on `PATH`
- a DSH launcher can be resolved
- `pnpm` is available
- the bundle package is installed and the profile includes it in
  `dsh.profile.bundles`
- the installed bundle patch declares exactly one `mcp-eve-map` row with
  `serverName = evemap`, `transport = stdio`, `command = eve-map-mcp.exe`
- **no absolute path, user name, HTTP URL, or shell wrapper** appears in the
  configuration
- the effective (`dsh --profile <profile> --dump-config`) configuration
  contains `mcp-eve-map` exactly once, owned by this bundle

You can also point it at a previously captured dump without invoking dsh:
`.\verify.ps1 -DumpFile dump.txt`.

---

## Using the tools

1. Install **EVE Static Map Planner 0.2.2+**.
2. **Start the map** (the app must be running with **AI Control enabled** for
   actual map operations).
3. Install the **EVE Map Assistant DSH bundle** (above).
4. **Restart DSH**.
5. Open a **new conversation**.
6. Use the `mcp__evemap__*` tools directly — there are approximately 20 of
   them (exactly the server's allowlisted set; this bundle adds none).

### When the map app is not connected

`eve-map-mcp.exe` can still `initialize` and answer `tools/list` without the
map running. Actual tool calls return **`APP_DISCONNECTED`** when the app is
unavailable. This is expected behavior — do not work around it; start the map
and enable AI Control instead.

## Related projects

- **[EVE Map Assistant Codex Plugin](https://github.com/zx0003147/EVE-Map-Assistant-Plugin)**
  is a **separate adapter** that exposes the same EVE Static Map Planner MCP
  bridge to OpenAI Codex. This repository is the DeepSeek Harness (DSH)
  adapter; the two projects are independent and share only the underlying
  `eve-map-mcp.exe` server supplied by EVE Static Map Planner.

## Development notes

- `tools/dsh-toolkit.ps1` is the shared installer/verifier toolkit dot-sourced
  by `install.ps1`, `uninstall.ps1`, and `verify.ps1`. Its DSH discovery is
  resilient to **both** launcher modes: it locates the real
  `@deepseek-ai/dsh` package directory from a `dsh` shim on `PATH`, or — when
  DSH is npx-only — by scanning npm's npx cache
  (`<npm cache>/_npx/*/node_modules/@deepseek-ai/dsh`, cache located via
  `npm config get cache` / `%LOCALAPPDATA%\npm-cache`, never hardcoded), then
  resolves js-yaml via Node module resolution anchored at that package.json
  (js-yaml is a direct dependency of `@deepseek-ai/dsh` in every layout).
- `tools/patch-file.mjs` is installer/verification tooling only: it safely
  edits/inspects DSH patch files (the profile's `cordis.patch.yml` and
  `dsh --dump-config` output) using the same YAML dialect dsh itself accepts
  (`js-yaml` with the `!!js` tag, resolved from the DSH installation). The
  production MCP flow never touches it.
- `install.ps1` / `uninstall.ps1` / `verify.ps1` are Windows PowerShell 5.1+
  compatible, use safe argument arrays (no command-string concatenation), and
  write UTF-8 without BOM.
- `tests/resolution-tests.ps1` statically verifies DSH/js-yaml discovery for
  both launcher modes (global `dsh` on `PATH`, and npx-only with `dsh` hidden
  from `PATH`); it is read-only and never touches a live profile.

## License

MIT — see [LICENSE](./LICENSE).
