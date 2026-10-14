#!/usr/bin/env node
import path from "node:path";
import { pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";

function openReadOnly(file) {
  const db = new DatabaseSync(file, { readOnly: true });
  db.exec("PRAGMA query_only=ON; PRAGMA busy_timeout=800");
  return db;
}

function sourceInfo(value, threadSource) {
  let source = value;
  try { source = JSON.parse(value); } catch { /* older plain enum */ }
  const subagent = source && typeof source === "object" ? source.subagent : null;
  const parent = subagent?.thread_spawn?.parent_thread_id || subagent?.threadSpawn?.parentThreadId || subagent?.parent_thread_id || null;
  const isSubagent = Boolean(subagent) || threadSource === "subagent" || threadSource === "agent";
  const allowed = new Set(["cli", "vscode", "appServer", "exec"]);
  return { source_kind: isSubagent ? "subagent" : allowed.has(source) ? source : "unknown", is_subagent: isSubagent, parent_thread_id: typeof parent === "string" ? parent : null };
}

export function readTaskStore(codexHome) {
  let history, state;
  try {
    history = openReadOnly(path.join(codexHome, "thread_history_1.sqlite"));
    state = openReadOnly(path.join(codexHome, "state_5.sqlite"));
    const metadata = new Map(state.prepare("SELECT id, rollout_path, source, thread_source, archived FROM threads").all().map((row) => [row.id, row]));
    const rows = history.prepare(`
      WITH latest AS (
        SELECT thread_id, turn_id, root_turn_id, status, started_at, completed_at,
               ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY started_at DESC, rollout_ordinal DESC) AS position
        FROM thread_turns
      )
      SELECT thread_id, turn_id, root_turn_id, status, started_at, completed_at
      FROM latest WHERE position=1
    `).all();
    const allowedStatus = new Set(["inProgress", "completed", "failed", "interrupted", "cancelled", "canceled"]);
    return {
      available: true,
      observed_at: new Date().toISOString(),
      threads: rows.map((row) => {
        const meta = metadata.get(row.thread_id);
        return { thread_id: row.thread_id, turn_id: row.turn_id, root_turn_id: row.root_turn_id,
          status: allowedStatus.has(row.status) ? row.status : "unknown", started_at: row.started_at,
          completed_at: row.completed_at, archived: meta?.archived === 1,
          rollout_path: typeof meta?.rollout_path === "string" ? meta.rollout_path : null,
          ...sourceInfo(meta?.source, meta?.thread_source) };
      }),
    };
  } catch {
    return { available: false, observed_at: new Date().toISOString(), error: "task_store_unavailable", threads: [] };
  } finally { history?.close(); state?.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const home = process.argv[2] || process.env.CODEX_HOME || path.join(process.env.USERPROFILE || process.env.HOME || "", ".codex");
  const result = readTaskStore(home);
  process.stdout.write(JSON.stringify(result) + "\n");
  if (!result.available) process.exitCode = 1;
}
