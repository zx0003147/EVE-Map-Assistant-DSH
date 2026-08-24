#!/usr/bin/env node
/**
 * EVE Map Assistant DSH bundle - installer/verifier YAML helper.
 *
 * This helper is installer/verification tooling ONLY. The production MCP flow
 * never touches it: DSH -> @deepseek-ai/dsh-mcp-client -> STDIO ->
 * eve-map-mcp.exe. It exists so install.ps1 / verify.ps1 can edit and inspect
 * DSH patch files safely (the profile's cordis.patch.yml and `dsh
 * --dump-config` output) with the same YAML dialect dsh itself uses.
 *
 * Modes (first CLI argument):
 *   detect         <patchFile> [--id <rowId>]
 *                  Parse a patch file and report whether an `insert` entry
 *                  contains a row with the given id (default: mcp-eve-map).
 *   remove         <patchFile> <rowId>
 *                  Remove every row with the given id from `insert` entries
 *                  (dropping an entry whose insert list becomes empty),
 *                  preserve the leading comment block, write UTF-8 (no BOM).
 *   validate-patch <patchFile>
 *                  Parse a patch file and report its structure.
 *   dump-parse     <dumpFile>
 *                  Parse `dsh --profile <name> --dump-config` output: split on
 *                  "# == <layer label>" separators, parse each chunk, and
 *                  report [{ label, rows }] so verification can attribute
 *                  composed rows to their source layer.
 *
 * All modes print one JSON object on stdout and exit 0 on success, 1 on error
 * (the error is in the JSON `error` field and also on stderr).
 *
 * js-yaml resolution: pass `--jsyaml <packageDir>`. When omitted, the helper
 * probes <helperDir>/../node_modules/js-yaml. Any DSH installation carries
 * js-yaml (a direct dependency of @deepseek-ai/dsh); install.ps1/verify.ps1
 * resolve it from the DSH launcher's module tree and pass it explicitly.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROW_ID_DEFAULT = 'mcp-eve-map';

function fail(message) {
  process.stderr.write(`patch-file: ${message}\n`);
  process.stdout.write(JSON.stringify({ ok: false, error: message }) + '\n');
  process.exit(1);
}

function parseArgs(argv) {
  const out = { mode: argv[0], positionals: [], options: {} };
  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--jsyaml') {
      out.options.jsyaml = argv[++i];
      if (out.options.jsyaml === undefined) fail('--jsyaml needs a path');
    } else if (arg === '--id') {
      out.options.id = argv[++i];
      if (out.options.id === undefined) fail('--id needs a value');
    } else {
      out.positionals.push(arg);
    }
  }
  return out;
}

async function loadJsYaml(jsyamlDir) {
  const candidates = [jsyamlDir, join(HERE, '..', 'node_modules', 'js-yaml')].filter(Boolean);
  for (const dir of candidates) {
    try {
      const entry = join(dir, 'index.js');
      const mod = await import(pathToFileURL(entry).href);
      return mod.default ?? mod;
    } catch {
      /* try next candidate */
    }
  }
  fail('js-yaml not found; pass --jsyaml <js-yaml package dir> (DSH installs always contain js-yaml)');
}

function makeSchema(yaml) {
  // Mirror @deepseek-ai/dsh-app-boot's entryListSchema: JSON_SCHEMA plus the
  // `!!js` scalar tag dsh patch files use for live expressions, so we parse
  // (and round-trip) exactly the dialect dsh itself accepts.
  const JsExpr = new yaml.Type('tag:yaml.org,2002:js', {
    kind: 'scalar',
    resolve: (data) => typeof data === 'string',
    construct: (data) => ({ __jsExpr: data }),
  });
  return yaml.JSON_SCHEMA.extend(JsExpr);
}

function readText(path) {
  try {
    return readFileSync(path, 'utf8');
  } catch (error) {
    fail(`cannot read ${path}: ${error.message}`);
  }
}

function writeUtf8NoBom(path, text) {
  try {
    writeFileSync(path, text, 'utf8');
  } catch (error) {
    fail(`cannot write ${path}: ${error.message}`);
  }
}

/** Everything before the first non-comment, non-blank line (header comments). */
function leadingCommentPrefix(text) {
  const lines = text.split(/\r?\n/);
  const prefix = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) prefix.push(line);
    else break;
  }
  return prefix.join('\n') + (prefix.length > 0 ? '\n' : '');
}

function parsePatch(yaml, schema, text, path) {
  let parsed;
  try {
    parsed = yaml.load(text, { schema });
  } catch (error) {
    fail(`failed to parse patch file ${path}: ${error.message}`);
  }
  if (!Array.isArray(parsed)) fail(`patch file ${path} must be a top-level YAML array of loader patch entries`);
  return parsed;
}

function collectInsertRows(patch, rowId) {
  const hits = [];
  for (let entryIndex = 0; entryIndex < patch.length; entryIndex += 1) {
    const entry = patch[entryIndex];
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) continue;
    const insert = entry.insert;
    if (!Array.isArray(insert)) continue;
    for (let rowIndex = 0; rowIndex < insert.length; rowIndex += 1) {
      const row = insert[rowIndex];
      if (row !== null && typeof row === 'object' && !Array.isArray(row) && row.id === rowId) {
        hits.push({ entryIndex, rowIndex, row });
      }
    }
  }
  return hits;
}

async function main() {
  const { mode, positionals, options } = parseArgs(process.argv.slice(2));
  const yaml = await loadJsYaml(options.jsyaml);
  const schema = makeSchema(yaml);
  const rowId = options.id ?? ROW_ID_DEFAULT;

  if (mode === 'detect') {
    const [file] = positionals;
    if (!file) fail('detect needs <patchFile>');
    const text = readText(file);
    const patch = parsePatch(yaml, schema, text, file);
    const hits = collectInsertRows(patch, rowId);
    const result = {
      ok: true,
      file,
      id: rowId,
      found: hits.length > 0,
      viaInsert: hits.length > 0,
      insertEntries: patch.filter((e) => e && typeof e === 'object' && !Array.isArray(e) && Array.isArray(e.insert)).length,
      patchEntries: patch.length,
      matchingRows: hits.length,
    };
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
    return;
  }

  if (mode === 'remove') {
    const [file] = positionals;
    if (!file) fail('remove needs <patchFile> and <rowId>');
    const text = readText(file);
    const patch = parsePatch(yaml, schema, text, file);
    const hits = collectInsertRows(patch, rowId);
    const removedRows = hits.length;
    let removedEntries = 0;
    for (const { entryIndex, rowIndex } of hits.slice().reverse()) {
      const entry = patch[entryIndex];
      entry.insert.splice(rowIndex, 1);
      if (entry.insert.length === 0) {
        patch.splice(entryIndex, 1);
        removedEntries += 1;
      }
    }
    const prefix = leadingCommentPrefix(text);
    const dumped = yaml.dump(patch, { schema, noRefs: true, lineWidth: -1 });
    const body = dumped.trimEnd();
    const next = prefix + (body === '[]' || body === '' ? '[]' : body) + '\n';
    if (removedRows > 0 || text !== next) writeUtf8NoBom(file, next);
    const result = {
      ok: true,
      file,
      id: rowId,
      removedRows,
      removedEntries,
      wrote: text !== next,
      entriesAfter: patch.length,
    };
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
    return;
  }

  if (mode === 'validate-patch') {
    const [file] = positionals;
    if (!file) fail('validate-patch needs <patchFile>');
    const text = readText(file);
    const patch = parsePatch(yaml, schema, text, file);
    const rows = [];
    for (const entry of patch) {
      if (entry && typeof entry === 'object' && !Array.isArray(entry)) {
        if (Array.isArray(entry.insert)) rows.push(...entry.insert);
        else if (typeof entry.id === 'string') rows.push(entry);
      }
    }
    process.stdout.write(JSON.stringify({
      ok: true,
      file,
      patchEntries: patch.length,
      rows,
    }, null, 2) + '\n');
    return;
  }

  if (mode === 'dump-parse') {
    const [file] = positionals;
    if (!file) fail('dump-parse needs <dumpFile>');
    const text = readText(file);
    const lines = text.split(/\r?\n/);
    const groups = [];
    let current = null;
    const buffer = [];
    const flush = () => {
      if (current === null) return;
      const chunk = buffer.join('\n').trim();
      let rows = [];
      if (chunk !== '') {
        try {
          const parsed = yaml.load(chunk, { schema });
          rows = Array.isArray(parsed) ? parsed : [];
        } catch (error) {
          fail(`failed to parse dump chunk for layer ${JSON.stringify(current)}: ${error.message}`);
        }
      }
      groups.push({ label: current, rows });
      buffer.length = 0;
    };
    for (const line of lines) {
      const match = /^# == (.*)$/.exec(line);
      if (match) {
        flush();
        current = match[1];
      } else {
        buffer.push(line);
      }
    }
    flush();
    process.stdout.write(JSON.stringify({ ok: true, file, groups }, null, 2) + '\n');
    return;
  }

  fail(`unknown mode ${JSON.stringify(mode)} (detect | remove | validate-patch | dump-parse)`);
}

main().catch((error) => fail(error?.stack ?? String(error)));
