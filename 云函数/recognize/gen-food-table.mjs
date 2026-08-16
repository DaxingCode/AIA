#!/usr/bin/env node
// 从 AIA/AIA/NutritionLibrary.swift 解析权威营养表，生成 foodTable.js（云端 queryFood 查表优先用）。
// 保证云端表与 App 本地 NutritionLibrary.rows 零转录误差、完全同源。
// 用法：node gen-food-table.mjs （在 云函数/recognize/ 目录执行）
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC = join(__dirname, '..', '..', 'AIA', 'AIA', 'NutritionLibrary.swift');
const OUT = join(__dirname, 'foodTable.js');
const code = readFileSync(SRC, 'utf8');

// SEED_VERSION
const seedM = code.match(/static let SEED_VERSION\s*=\s*(\d+)/);
const SEED_VERSION = seedM ? Number(seedM[1]) : 0;

// rows 块（private let rows: [...] = [ ... ]，以 ] 收尾）
const rowsM = code.match(/(?:private\s+)?let rows:\s*\[[^\]]*\]\s*=\s*\[([\s\S]*?)\]\s*\n/);
if (!rowsM) { console.error('无法解析 rows 块'); process.exit(1); }
const rowsBlock = rowsM[1];
const rowRe = /^\s*\("([^"]+)"\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\)\s*,?/gm;
const table = {};
let m;
while ((m = rowRe.exec(rowsBlock)) !== null) {
  const name = m[1];
  table[name] = {
    kcal: Number(m[2]), protein: Number(m[3]), carbs: Number(m[4]),
    fat: Number(m[5]), fiber: Number(m[6]), sugar: Number(m[7]), sodium: Number(m[8]),
  };
}

// aliases 块（private let aliases: [String: String] = [ ... ]）
const aliasM = code.match(/(?:private\s+)?let aliases:\s*\[String:\s*String\]\s*=\s*\[([\s\S]*?)\]\s*\n/);
const aliases = {};
if (aliasM) {
  const aliasRe = /^\s*"([^"]+)"\s*:\s*"([^"]+)"\s*,?/gm;
  while ((m = aliasRe.exec(aliasM[1])) !== null) {
    aliases[m[1]] = m[2];
  }
}

// seasoningPrefixes（与 Swift canonicalFoodName 一致的去前缀逻辑）
const seasonM = code.match(/(?:private\s+)?let seasoningPrefixes:\s*(?:Set<)?String(?:>)?\s*=\s*\[([\s\S]*?)\]\s*\n/);
const seasoningPrefixes = [];
if (seasonM) {
  const spRe = /"([^"]+)"/g;
  while ((m = spRe.exec(seasonM[1])) !== null) seasoningPrefixes.push(m[1]);
}

const norm = (s) => (s || '').toLowerCase().replace(/\s+/g, '').replace(/[（(].*?[)）]/g, '');

// 云端查表函数（镜像 Swift NutritionLibrary.match 的语义：去前缀→别名→精确→子串）
function lookupFood(raw) {
  if (!raw) return null;
  let s = String(raw).trim();
  for (const p of seasoningPrefixes) {
    if (s.startsWith(p)) { s = s.slice(p.length); break; }
  }
  if (aliases[s]) s = aliases[s];
  if (!s) return null;
  const key = norm(s);
  if (table[s]) return { name: s, ...table[s] };
  for (const [name, val] of Object.entries(table)) {
    if (norm(name) === norm(s)) return { name, ...val };
  }
  for (const [name, val] of Object.entries(table)) {
    const nk = norm(name);
    if (nk.includes(key) || key.includes(nk)) return { name, ...val };
  }
  for (const [alias, canon] of Object.entries(aliases)) {
    if (norm(alias) === key && table[canon]) return { name: canon, ...table[canon] };
  }
  return null;
}

const out = `// AUTO-GENERATED from AIA/AIA/NutritionLibrary.swift by gen-food-table.mjs — 不要手改。
// 云端 queryFood 查表优先，命中即返确定值，避免对常见食物反复 LLM 估算导致数值漂移。
const SEED_VERSION = ${SEED_VERSION};
const FOOD_TABLE = ${JSON.stringify(table, null, 2)};

const FOOD_ALIASES = ${JSON.stringify(aliases, null, 2)};

const SEASONING_PREFIXES = ${JSON.stringify(seasoningPrefixes)};

function norm(s) { return (s || '').toLowerCase().replace(/\\s+/g, '').replace(/[（(].*?[)）]/g, ''); }

// 镜像 Swift canonicalFoodName + match：去前缀→别名→精确→子串。
function lookupFood(raw) {
  if (!raw) return null;
  let s = String(raw).trim();
  for (const p of SEASONING_PREFIXES) {
    if (s.startsWith(p)) { s = s.slice(p.length); break; }
  }
  if (FOOD_ALIASES[s]) s = FOOD_ALIASES[s];
  if (!s) return null;
  const key = norm(s);
  if (FOOD_TABLE[s]) return { name: s, ...FOOD_TABLE[s] };
  for (const [name, val] of Object.entries(FOOD_TABLE)) {
    if (norm(name) === norm(s)) return { name, ...val };
  }
  for (const [name, val] of Object.entries(FOOD_TABLE)) {
    const nk = norm(name);
    if (nk.includes(key) || key.includes(nk)) return { name, ...val };
  }
  for (const [alias, canon] of Object.entries(FOOD_ALIASES)) {
    if (norm(alias) === key && FOOD_TABLE[canon]) return { name: canon, ...FOOD_TABLE[canon] };
  }
  return null;
}

module.exports = { FOOD_TABLE, FOOD_ALIASES, SEASONING_PREFIXES, lookupFood, SEED_VERSION };
`;

writeFileSync(OUT, out, 'utf8');
console.log(`已生成 ${OUT}：表 ${Object.keys(table).length} 项，别名 ${Object.keys(aliases).length} 条，SEED_VERSION=${SEED_VERSION}`);
