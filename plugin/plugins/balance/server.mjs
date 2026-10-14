#!/usr/bin/env node
/**
 * balance — Codex plugin MCP server.
 *
 * Exposes live account balances or official Codex quota for the current provider.
 * Speaks newline-delimited JSON-RPC 2.0 over stdio (MCP).
 */
import fs from "node:fs";
import path from "node:path";
import { resolveAccount, readAccountUsage } from "./account.mjs";

const SERVER_INFO = { name: "balance", version: "1.0.0" };
const SUPPORTED_PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"];

const log = (...parts) => process.stderr.write("[balance] " + parts.join(" ") + "\n");

/* ------------------------------------------------------------------ config */

function codexHome() {
  const candidates = [];
  if (process.env.CODEX_HOME) candidates.push(process.env.CODEX_HOME);
  const userHome = process.env.USERPROFILE || process.env.HOME;
  if (userHome) candidates.push(path.join(userHome, ".codex"));
  for (const candidate of candidates) {
    try {
      if (candidate && fs.existsSync(path.join(candidate, "config.toml"))) return candidate;
    } catch {
      /* ignore */
    }
  }
  return candidates.find((candidate) => candidate && fs.existsSync(candidate)) || null;
}

/* ------------------------------------------------------------ alert state */

function alertPath() {
  const home = codexHome();
  return home ? path.join(home, "balance-alert.json") : null;
}

function readAlert() {
  const file = alertPath();
  if (!file) return null;
  try {
    if (!fs.existsSync(file)) return null;
    const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
    if (typeof parsed?.threshold !== "number") return null;
    return {
      threshold: parsed.threshold,
      currency: typeof parsed.currency === "string" ? parsed.currency : "CNY",
      updated_at: parsed.updated_at || null,
    };
  } catch {
    return null;
  }
}

function writeAlert(alert) {
  const file = alertPath();
  if (!file) throw new Error("找不到 ~/.codex 目录，无法保存提醒阈值。");
  if (alert === null) {
    if (fs.existsSync(file)) fs.rmSync(file);
    return;
  }
  fs.writeFileSync(file, JSON.stringify(alert, null, 2) + "\n", "utf8");
}

/* --------------------------------------------------------------- renderer */

const symbol = (currency) => (currency === "CNY" ? "¥" : currency === "USD" ? "$" : currency + " ");

function nowInShanghai() {
  return new Intl.DateTimeFormat("zh-CN", {
    timeZone: "Asia/Shanghai",
    dateStyle: "medium",
    timeStyle: "medium",
    hour12: false,
  }).format(new Date());
}

function formatBalance(data, source, alert) {
  const lines = [];
  lines.push("实时余额（" + nowInShanghai() + "，实时查询，未缓存）");
  lines.push("账户可用：" + (data.is_available ? "是" : "否（余额不足或账户受限）"));

  const infos = Array.isArray(data.balance_infos) ? data.balance_infos : [];
  if (infos.length === 0) lines.push("接口未返回余额明细。");
  for (const info of infos) {
    lines.push(
      info.currency +
        "：总额 " +
        symbol(info.currency) +
        info.total_balance +
        "（充值 " +
        symbol(info.currency) +
        info.topped_up_balance +
        "，赠送 " +
        symbol(info.currency) +
        info.granted_balance +
        "）"
    );
  }

  if (alert) {
    const hit = infos.find((info) => info.currency === alert.currency);
    const value = hit ? Number.parseFloat(hit.total_balance) : NaN;
    if (Number.isFinite(value) && value < alert.threshold) {
      lines.push(
        "⚠️ ALERT：已低于提醒阈值 " +
          symbol(alert.currency) +
          alert.threshold +
          "（当前 " +
          symbol(alert.currency) +
          value.toFixed(2) +
          "），建议及时充值。"
      );
    } else if (Number.isFinite(value)) {
      lines.push("阈值检查：正常（≥ " + symbol(alert.currency) + alert.threshold + "）");
    }
  }

  lines.push("服务商：" + source.provider + "，模型：" + (source.model || "未指定"));
  return lines.join("\n");
}

function formatQuota(data, source) {
  const lines = ["实时额度（" + nowInShanghai() + "，实时查询，未缓存）", "服务商：OpenAI（ChatGPT 账号），模型：" + (source.model || "未指定")];
  const buckets = Object.values(data.rateLimitsByLimitId || {});
  if (!buckets.length && data.rateLimits) buckets.push(data.rateLimits);
  for (const bucket of buckets) {
    for (const [key, label] of [["primary", "主要窗口"], ["secondary", "次要窗口"]]) {
      const window = bucket[key];
      if (!window) continue;
      const duration = window.windowDurationMins;
      const name = duration === 300 ? "5 小时窗口" : duration === 10080 ? "每周窗口" : duration ? duration + " 分钟窗口" : label;
      const reset = window.resetsAt ? new Intl.DateTimeFormat("zh-CN", { timeZone: "Asia/Shanghai", dateStyle: "medium", timeStyle: "medium", hour12: false }).format(new Date(window.resetsAt * 1000)) : "暂未提供";
      lines.push((bucket.limitName || bucket.limitId || "Codex") + " · " + name + "：剩余 " + (100 - window.usedPercent) + "%（已用 " + window.usedPercent + "%，重置：" + reset + "）");
    }
    if (bucket.credits?.unlimited) lines.push("额度点数：不限量");
    else if (bucket.credits?.hasCredits && bucket.credits.balance !== null) lines.push("额度点数：" + bucket.credits.balance);
  }
  return lines.join("\n");
}

/* ------------------------------------------------------------------ tools */

const TOOLS = [
  {
    name: "get_balance",
    description:
      "实时查询当前模型服务商的账户余额或官方 ChatGPT 账号的 Codex 使用额度（每次实时读取，不缓存）。",
    inputSchema: {
      type: "object",
      properties: {
        currency: {
          type: "string",
          description: "只看某一币种时传入，例如 CNY 或 USD；留空则返回全部币种。",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "balance_alert",
    description:
      "查看、设置或清除低余额提醒阈值。阈值保存在 ~/.codex/balance-alert.json，查询余额时会一并报告是否低于阈值。",
    inputSchema: {
      type: "object",
      properties: {
        threshold: {
          type: ["number", "null"],
          description: "提醒阈值，传 null 表示清除；不传则只查看当前设置。",
        },
        currency: {
          type: "string",
          description: "阈值对应币种，默认 CNY。",
        },
      },
      additionalProperties: false,
    },
  },
];

function textResult(text, isError = false, structuredContent) {
  const result = { content: [{ type: "text", text }] };
  if (isError) result.isError = true;
  if (structuredContent) result.structuredContent = structuredContent;
  return result;
}

async function callTool(params) {
  const name = params?.name;
  const args = params?.arguments || {};

  if (name === "get_balance") {
    const result = await readAccountUsage(resolveAccount());
    const data = result.data;
    if (result.kind === "balance" && args.currency) {
      const wanted = String(args.currency).toUpperCase();
      data.balance_infos = (data.balance_infos || []).filter(
        (info) => String(info.currency).toUpperCase() === wanted
      );
    }
    const alert = result.kind === "balance" ? readAlert() : null;
    return textResult(result.kind === "quota" ? formatQuota(data, result) : formatBalance(data, result, alert), false, { ...result, alert });
  }

  if (name === "balance_alert") {
    if (Object.prototype.hasOwnProperty.call(args, "threshold")) {
      if (args.threshold === null) {
        writeAlert(null);
        return textResult("已清除低余额提醒阈值。");
      }
      const threshold = Number(args.threshold);
      if (!Number.isFinite(threshold) || threshold < 0) {
        return textResult("阈值必须是不小于 0 的数字，或 null。", true);
      }
      const currency = String(args.currency || "CNY").toUpperCase();
      writeAlert({ threshold, currency, updated_at: new Date().toISOString() });
      return textResult(
        "已设置提醒阈值：" +
          symbol(currency) +
          threshold +
          "，之后每次查询余额都会报告是否低于该阈值。"
      );
    }
    const current = readAlert();
    return textResult(
      current
        ? "当前提醒阈值：" + symbol(current.currency) + current.threshold + "（" + current.currency + "）"
        : "当前未设置提醒阈值。"
    );
  }

  return null;
}

/* -------------------------------------------------------------- transport */

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

async function handle(message) {
  const { id, method, params } = message;
  const isNotification = id === undefined || id === null;

  switch (method) {
    case "initialize": {
      const wanted = params?.protocolVersion;
      const protocolVersion = SUPPORTED_PROTOCOLS.includes(wanted) ? wanted : SUPPORTED_PROTOCOLS[0];
      return send({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion,
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions:
            "This server exposes the current provider's live account balance or official Codex usage quota. When the user asks about balance or remaining quota, call get_balance and answer from the fresh result, never from memory. Quota credits are not currency balances.",
        },
      });
    }
    case "notifications/initialized":
    case "initialized":
      return;
    case "ping":
      return send({ jsonrpc: "2.0", id, result: {} });
    case "tools/list":
      return send({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
    case "tools/call": {
      try {
        const result = await callTool(params);
        if (!result) {
          return send({
            jsonrpc: "2.0",
            id,
            error: { code: -32602, message: "Unknown tool: " + String(params?.name) },
          });
        }
        return send({ jsonrpc: "2.0", id, result });
      } catch (error) {
        return send({
          jsonrpc: "2.0",
          id,
          result: textResult("查询余额失败：" + (error?.message || String(error)), true),
        });
      }
    }
    case "resources/list":
      return send({ jsonrpc: "2.0", id, result: { resources: [] } });
    case "prompts/list":
      return send({ jsonrpc: "2.0", id, result: { prompts: [] } });
    default:
      if (isNotification) return;
      return send({
        jsonrpc: "2.0",
        id,
        error: { code: -32601, message: "Method not found: " + String(method) },
      });
  }
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      log("ignored malformed line");
      continue;
    }
    handle(message).catch((error) => {
      log("handler error:", error?.message || String(error));
      if (message && message.id !== undefined && message.id !== null) {
        send({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: -32603, message: String(error?.message || error) },
        });
      }
    });
  }
});
process.stdin.on("end", () => process.exit(0));
log("ready");
