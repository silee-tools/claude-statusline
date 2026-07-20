// 독립 프로세스로 실행: ccusage → 캐시 파일 갱신
// hook-handler에서 detached로 spawn됨
// 락 파일(O_EXCL)로 시스템 전체에서 ccusage 단일 실행 보장

import { closeSync, constants, existsSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "fs";
import { dirname, join } from "path";

const CACHE_TTL_MS = 300_000; // 5분
const LOCK_STALE_MS = 120_000; // 2분 (ccusage timeout 60s + 여유)

interface CostData {
  weeklyCost: number;
  monthlyCost: number;
  dailyModels?: { opus: number; sonnet: number; haiku: number };
  available: boolean;
  cachedAt: string;
}

const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT ?? import.meta.dir.replace("/scripts", "");
const cachePath = join(pluginRoot, "data", "cost-cache.json");
const lockPath = join(pluginRoot, "data", "cost-refresh.lock");

// --- 락 관리 ---

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function tryAcquireLock(): boolean {
  const dataDir = dirname(lockPath);
  if (!existsSync(dataDir)) mkdirSync(dataDir, { recursive: true });

  // stale 락 체크
  if (existsSync(lockPath)) {
    try {
      const lock = JSON.parse(readFileSync(lockPath, "utf-8"));
      const age = Date.now() - new Date(lock.startedAt).getTime();
      if (isProcessAlive(lock.pid) && age < LOCK_STALE_MS) {
        return false; // 유효한 락 존재 → 다른 프로세스가 갱신 중
      }
      unlinkSync(lockPath); // stale 락 제거
    } catch {
      try { unlinkSync(lockPath); } catch { /* 이미 없음 */ }
    }
  }

  // O_EXCL로 atomic 생성 (파일이 이미 있으면 EEXIST로 실패)
  try {
    const fd = openSync(lockPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o644);
    writeFileSync(fd, JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }));
    closeSync(fd);
    return true;
  } catch {
    return false;
  }
}

function releaseLock(): void {
  try {
    if (existsSync(lockPath)) {
      const lock = JSON.parse(readFileSync(lockPath, "utf-8"));
      if (lock.pid === process.pid) unlinkSync(lockPath);
    }
  } catch { /* 무시 */ }
}

// --- 캐시 TTL 체크 ---

function isCacheValid(): boolean {
  if (!existsSync(cachePath)) return false;
  try {
    const data = JSON.parse(readFileSync(cachePath, "utf-8"));
    return !!(data.cachedAt && Date.now() - new Date(data.cachedAt).getTime() < CACHE_TTL_MS);
  } catch {
    return false;
  }
}

// --- 메인 ---

// 1. 캐시가 유효하면 종료
if (isCacheValid()) process.exit(0);

// 2. 락 획득 시도
if (!tryAcquireLock()) process.exit(0); // 다른 프로세스가 갱신 중

try {
  // 3. Double-check: 락 획득 사이에 다른 프로세스가 캐시를 갱신했을 수 있음
  if (isCacheValid()) {
    releaseLock();
    process.exit(0);
  }

  // 4. ccusage 실행
  const result = Bun.spawnSync({
    cmd: ["ccusage", "--json"],
    timeout: 60_000,
    stderr: "ignore",
  });

  if (result.exitCode !== 0) {
    console.error(`[claude-statusline:refresh-cost] ccusage exit ${result.exitCode}`);
    releaseLock();
    process.exit(1);
  }

  const json = JSON.parse(result.stdout.toString());
  const today = new Date().toISOString().slice(0, 10);
  const weekStart = (() => { const d = new Date(); d.setDate(d.getDate() - d.getDay()); return d.toISOString().slice(0, 10); })();
  const month = today.slice(0, 7);

  const todayData = json.daily?.find((d: { date: string }) => d.date === today);

  const dailyModels = { opus: 0, sonnet: 0, haiku: 0 };
  if (todayData?.modelBreakdowns) {
    for (const m of todayData.modelBreakdowns) {
      const name = (m.modelName as string).toLowerCase();
      if (name.includes("opus")) dailyModels.opus += m.cost;
      else if (name.includes("sonnet")) dailyModels.sonnet += m.cost;
      else if (name.includes("haiku")) dailyModels.haiku += m.cost;
    }
  }

  const weeklyCost = (json.daily ?? [])
    .filter((d: { date: string }) => d.date >= weekStart)
    .reduce((sum: number, d: { totalCost: number }) => sum + d.totalCost, 0);

  const monthlyCost = (json.daily ?? [])
    .filter((d: { date: string }) => d.date.startsWith(month))
    .reduce((sum: number, d: { totalCost: number }) => sum + d.totalCost, 0);

  const data: CostData = {
    weeklyCost, monthlyCost, dailyModels,
    available: true,
    cachedAt: new Date().toISOString(),
  };

  const dir = dirname(cachePath);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const tmp = `${cachePath}.tmp`;
  writeFileSync(tmp, JSON.stringify(data));
  renameSync(tmp, cachePath);
} catch (err) {
  console.error(`[claude-statusline:refresh-cost] failed: ${(err as Error).message}`);
}
releaseLock();
