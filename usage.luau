--!strict
-- provider-quota model: normalize `omp usage --json` (quotas, disabled
-- credentials, no-usage accounts) and `omp models --json` (every configured
-- provider's model catalog), merge them into one provider inventory, count
-- states, format durations. Pure functions of their input (no tern global,
-- no clock, no I/O).
--
-- Rules:
--   * normalize() rejects (error names the field path) a payload that is not
--     an object, lacks a numeric generatedAt, or lacks a reports array.
--   * normalizeModels() is lenient: anything that is not a catalog yields an
--     empty list, so a catalog failure can never lose quota data.
--   * merge() unions four sources into providers: quota reports ("reported"),
--     no-usage accounts ("no-usage"), the model catalog ("catalog"), plus the
--     disabled-credentials list rendered separately. A missing amount is
--     never 0 — remainingFraction stays nil and renders "未上报".
--   * Counts classify PROVIDERS (ok/low/exhausted/unknown, by a provider's worst
--     window); disabled credentials are counted separately.

local M = {}

export type Limit = {
	key: string,
	label: string,
	windowLabel: string?,
	-- 0..1, nil when the provider did not report it.
	remainingFraction: number?,
	remaining: number?,
	unit: string?,
	resetsAt: number?,
	-- As reported: "ok" | "warning" | "exhausted" | …
	status: string,
	-- Balance rows (direct provider-API adapters): preformatted money text.
	amountText: string?,
	isBalance: boolean?,
}

-- state: "reported" (quota rows below) | "no-usage" (configured, no usage
-- endpoint) | "catalog" (configured, only the model catalog knows it).
export type Provider = {
	key: string,
	name: string,
	state: string,
	plan: string?,
	models: number?,
	-- Why direct quota lookup failed, when an adapter tried and got an
	-- explicit upstream error (e.g. "api_key_expired").
	note: string?,
	fetchedAt: number?,
	limits: { Limit },
}

export type Disabled = { key: string, id: string, provider: string, cause: string, at: number?, models: number? }
export type NoUsage = { key: string, id: string, provider: string, kind: string? }
export type CatalogEntry = { key: string, models: number }

export type Counts = {
	providers: number,
	reported: number,
	noQuota: number,
	limits: number,
	ok: number,
	low: number,
	exhausted: number,
	unknown: number,
	disabled: number,
	noUsage: number,
}

export type Snapshot = {
	generatedAt: number,
	providers: { Provider },
	disabled: { Disabled },
	noUsage: { NoUsage },
	counts: Counts,
}

-- What the host publishes to kv and windows read for the status line.
export type Record = {
	snapshot: Snapshot?,
	error: string?,
	lastSuccess: number?,
	heartbeat: number,
	refreshing: boolean,
	text: string,
	tone: string?,
	segments: { { text: string, tone: string? } },
}

export type Segment = { text: string, tone: string? }
export type Summary = { text: string, tone: string?, segments: { Segment } }

-- A limit with less remaining than this is "low".
M.LOW_LEFT = 0.15
-- A report older than this renders a stale badge.
M.STALE_MS = 10 * 60 * 1000

local PROVIDER_NAMES: { [string]: string } = {
	anthropic = "Anthropic",
	openai = "OpenAI",
	["openai-codex"] = "OpenAI Codex",
	["google-gemini-cli"] = "Gemini CLI",
	["google-antigravity"] = "Google Antigravity",
	["github-copilot"] = "GitHub Copilot",
	zai = "Z.AI",
	["kimi-code"] = "Kimi",
	kimi = "Kimi",
	moonshot = "Kimi Code",
	deepseek = "DeepSeek",
	minimax = "MiniMax",
	["minimax-code-cn"] = "MiniMax CN",
	["minimax-cn"] = "MiniMax CN",
	["opencode-go"] = "OpenCode",
}

local EMPTY: { [string]: any } = {}

----------------------------------------------------------------------------
-- small helpers

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isArray(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	local n = 0
	for k in v do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			return false
		end
		n += 1
	end
	return n == #v
end

local function fail(path: string, why: string): never
	error("usage: invalid payload at " .. path .. ": " .. why, 0)
end

local function optString(t: { [string]: any }, field: string, path: string): string?
	local v = t[field]
	if v == nil then
		return nil
	end
	if type(v) ~= "string" then
		fail(path .. "." .. field, "must be a string")
	end
	return v
end

local function optNumber(t: { [string]: any }, field: string, path: string): number?
	local v = t[field]
	if v == nil then
		return nil
	end
	if not isFinite(v) then
		fail(path .. "." .. field, "must be a finite number")
	end
	return v
end

local function optTable(t: { [string]: any }, field: string, path: string): { [string]: any }?
	local v = t[field]
	if v == nil then
		return nil
	end
	if type(v) ~= "table" then
		fail(path .. "." .. field, "must be an object")
	end
	return v
end

-- One printable line, at most max characters; invalid UTF-8 becomes "?".
local function clean(s: string, max: number): string
	local out = (s:gsub("%c", " ")):gsub("%s+", " ")
	if utf8.len(out) == nil then
		out = (out:gsub("[\128-\255]", "?")) :: string
	end
	out = (out:match("^%s*(.-)%s*$") or "") :: string
	local len = utf8.len(out)
	if len ~= nil and len > max then
		local cut = utf8.offset(out, max)
		if cut ~= nil then
			out = out:sub(1, cut - 1) .. "…"
		end
	end
	return out
end

local function providerName(id: string): string
	return PROVIDER_NAMES[id] or (id:sub(1, 1):upper() .. id:sub(2):gsub("-", " "))
end

----------------------------------------------------------------------------
-- duration and severity

-- "due" for <= 0, otherwise at most two units: 2d 3h / 5h 12m / 4m / 30s.
function M.duration(ms: number): string
	if not isFinite(ms) then
		return "?"
	end
	if ms <= 0 then
		return "due"
	end
	local secs = math.ceil(ms / 1000)
	local d = math.floor(secs / 86400)
	local h = math.floor((secs % 86400) / 3600)
	local m = math.floor((secs % 3600) / 60)
	local s = secs % 60
	if d > 0 then
		return if h > 0 then string.format("%dd %dh", d, h) else string.format("%dd", d)
	elseif h > 0 then
		return if m > 0 then string.format("%dh %02dm", h, m) else string.format("%dh", h)
	elseif m > 0 then
		return string.format("%dm", m)
	end
	return string.format("%ds", s)
end

function M.ago(nowMs: number, at: number): string
	local d = nowMs - at
	if d < 1000 then
		return "刚刚"
	end
	return M.duration(d) .. "前"
end

-- "exhausted" | "low" | "ok" | "unknown"
function M.severity(l: Limit): string
	if l.isBalance then
		return "ok"
	end
	local st = string.lower(l.status or "")
	if st:find("exhaust", 1, true) or st:find("exceed", 1, true) then
		return "exhausted"
	end
	local rem = l.remainingFraction
	if rem ~= nil then
		if rem <= 0 then
			return "exhausted"
		elseif rem < M.LOW_LEFT then
			return "low"
		end
		return "ok"
	end
	if st:find("warn", 1, true) or st:find("low", 1, true) then
		return "low"
	end
	return "unknown"
end

M.SEVERITY_RANK = { exhausted = 0, low = 1, unknown = 2, ok = 3 }

function M.remainingFill(l: Limit): number?
	local rem = l.remainingFraction
	if rem ~= nil then
		return math.clamp(rem, 0, 1)
	end
	return nil
end

----------------------------------------------------------------------------
-- normalize: usage payload

local function normalizeUsage(payload: any): Snapshot
	if type(payload) ~= "table" then
		fail("payload", "must be an object")
	end
	local p = payload :: { [string]: any }
	local generatedAt = optNumber(p, "generatedAt", "payload")
	if generatedAt == nil then
		fail("payload.generatedAt", "must be a number")
	end
	local reports = p.reports
	if reports == nil then
		fail("payload.reports", "must be an array")
	end
	if not isArray(reports) then
		fail("payload.reports", "must be an array")
	end

	local byKey: { [string]: Provider } = {}
	local providers: { Provider } = {}

	for i, r in reports :: { any } do
		local path = "payload.reports[" .. i .. "]"
		if type(r) ~= "table" then
			fail(path, "must be an object")
		end
		local rep = r :: { [string]: any }
		local pid = optString(rep, "provider", path)
		if pid == nil or pid == "" then
			fail(path .. ".provider", "must be a non-empty string")
		end
		local fetchedAt = optNumber(rep, "fetchedAt", path)
		local meta = optTable(rep, "metadata", path .. ".metadata")
		local plan = if meta ~= nil then optString(meta, "planType", path .. ".metadata") else nil

		local limitsIn = rep.limits
		if limitsIn == nil then
			limitsIn = EMPTY
		end
		if not isArray(limitsIn) then
			fail(path .. ".limits", "must be an array")
		end

		local prov = byKey[pid]
		if prov == nil then
			prov = {
				key = pid,
				name = providerName(pid),
				state = "reported",
				plan = nil,
				models = nil,
				fetchedAt = nil,
				limits = {},
			} :: Provider
			byKey[pid] = prov
			table.insert(providers, prov)
		end
		if plan ~= nil and prov.plan == nil then
			prov.plan = clean(plan, 24)
		end
		if fetchedAt ~= nil and (prov.fetchedAt == nil or fetchedAt > (prov.fetchedAt :: number)) then
			prov.fetchedAt = fetchedAt
		end

		for j, l in limitsIn :: { any } do
			local lpath = path .. ".limits[" .. j .. "]"
			if type(l) ~= "table" then
				fail(lpath, "must be an object")
			end
			local raw = l :: { [string]: any }
			local id = optString(raw, "id", lpath)
			local label = optString(raw, "label", lpath)
				or (if id ~= nil then clean(id, 48) else "额度")
			local win = optTable(raw, "window", lpath .. ".window")
			local amount = optTable(raw, "amount", lpath .. ".amount")

			local windowLabel: string? = nil
			local resetsAt: number? = nil
			if win ~= nil then
				windowLabel = optString(win, "label", lpath .. ".window")
				resetsAt = optNumber(win, "resetsAt", lpath .. ".window")
			end

			local remainingFraction: number? = nil
			local remaining: number? = nil
			local unit: string? = nil
			if amount ~= nil then
				remainingFraction = optNumber(amount, "remainingFraction", lpath .. ".amount")
				remaining = optNumber(amount, "remaining", lpath .. ".amount")
				unit = optString(amount, "unit", lpath .. ".amount")
			end

			table.insert(prov.limits, {
				key = pid .. ":" .. (id or j),
				label = clean(label, 64),
				windowLabel = if windowLabel ~= nil then clean(windowLabel, 32) else nil,
				remainingFraction = remainingFraction,
				remaining = remaining,
				unit = unit,
				resetsAt = resetsAt,
				status = optString(raw, "status", lpath) or "",
			} :: Limit)
		end
	end

	local disabled: { Disabled } = {}
	local dc = p.disabledCredentials
	if dc ~= nil then
		if not isArray(dc) then
			fail("payload.disabledCredentials", "must be an array")
		end
		for i, d in dc :: { any } do
			local path = "payload.disabledCredentials[" .. i .. "]"
			if type(d) ~= "table" then
				fail(path, "must be an object")
			end
			local raw = d :: { [string]: any }
			local pid = optString(raw, "provider", path) or "?"
			local cause = optString(raw, "cause", path) or "登录已失效"
			table.insert(disabled, {
				key = "d:" .. i .. ":" .. pid,
				id = pid,
				provider = providerName(pid),
				cause = clean(cause, 200),
				at = optNumber(raw, "disabledAtMs", path),
				models = nil,
			} :: Disabled)
		end
	end

	local noUsage: { NoUsage } = {}
	local nuIds: { [string]: boolean } = {}
	local nu = p.accountsWithoutUsage
	if nu ~= nil then
		if not isArray(nu) then
			fail("payload.accountsWithoutUsage", "must be an array")
		end
		for i, a in nu :: { any } do
			local path = "payload.accountsWithoutUsage[" .. i .. "]"
			if type(a) ~= "table" then
				fail(path, "must be an object")
			end
			local raw = a :: { [string]: any }
			local pid = optString(raw, "provider", path) or "?"
			nuIds[pid] = true
			table.insert(noUsage, {
				key = "n:" .. i .. ":" .. pid,
				id = pid,
				provider = providerName(pid),
				kind = optString(raw, "type", path),
			} :: NoUsage)
		end
	end

	-- Providers that only appear as no-usage accounts are inventory too, so
	-- they show in the configured list instead of vanishing. Disabled-only
	-- credentials stay in their own card (no duplicate rows).
	for _, a in noUsage do
		if byKey[a.id] == nil then
			local prov: Provider = {
				key = a.id,
				name = a.provider,
				state = "no-usage",
				models = nil,
				limits = {},
			} :: Provider
			byKey[a.id] = prov
			table.insert(providers, prov)
		end
	end

	local snap: Snapshot = {
		generatedAt = generatedAt,
		providers = providers,
		disabled = disabled,
		noUsage = noUsage,
		counts = {
			providers = #providers,
			reported = 0,
			noQuota = 0,
			limits = 0,
			ok = 0,
			low = 0,
			exhausted = 0,
			unknown = 0,
			disabled = #disabled,
			noUsage = #noUsage,
		},
	}
	M.recount(snap)
	return snap
end

-- Leniently read `omp models --json`: anything malformed yields an empty
-- catalog so a catalog failure can never lose quota data.
function M.normalizeModels(payload: any): { CatalogEntry }
	local out: { CatalogEntry } = {}
	if type(payload) ~= "table" then
		return out
	end
	local p = payload :: { [string]: any }
	local models = p.models
	if type(models) ~= "table" or not isArray(models) then
		return out
	end
	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, m in models :: { any } do
		if type(m) == "table" then
			local pid = (m :: { [string]: any }).provider
			if type(pid) == "string" and pid ~= "" then
				if counts[pid] == nil then
					counts[pid] = 0
					table.insert(order, pid)
				end
				counts[pid] += 1
			end
		end
	end
	table.sort(order)
	for _, pid in order do
		table.insert(out, { key = pid, models = counts[pid] } :: CatalogEntry)
	end
	return out
end

-- Union the model catalog into the snapshot: attach model counts to known
-- providers, and append catalog-only providers the usage report never named.
function M.merge(snap: Snapshot, catalog: { CatalogEntry }): Snapshot
	local byKey: { [string]: Provider } = {}
	for _, p in snap.providers do
		byKey[p.key] = p
	end
	local disabledIds: { [string]: boolean } = {}
	for _, d in snap.disabled do
		disabledIds[d.id] = true
	end

	for _, c in catalog do
		local prov = byKey[c.key]
		if prov ~= nil then
			prov.models = c.models
		elseif disabledIds[c.key] then
			for _, d in snap.disabled do
				if d.id == c.key then
					d.models = c.models
				end
			end
		else
			local fresh: Provider = {
				key = c.key,
				name = providerName(c.key),
				state = "catalog",
				models = c.models,
				limits = {},
			} :: Provider
			byKey[c.key] = fresh
			table.insert(snap.providers, fresh)
		end
	end

	-- Mark usage-less providers from the report on their inventory rows.
	local nuById: { [string]: boolean } = {}
	for _, a in snap.noUsage do
		nuById[a.id] = true
	end
	for _, p in snap.providers do
		if nuById[p.key] then
			p.state = "no-usage"
		end
	end

	M.recount(snap)
	return snap
end

function M.recount(snap: Snapshot)
	local c = snap.counts
	c.providers = #snap.providers
	c.reported = 0
	c.noQuota = 0
	c.limits = 0
	c.ok = 0
	c.low = 0
	c.exhausted = 0
	c.unknown = 0
	for _, prov in snap.providers do
		if #prov.limits > 0 then
			c.reported += 1
		else
			c.noQuota += 1
		end
		c.limits += #prov.limits
		-- States count PROVIDERS, not windows: a provider lands in one bucket
		-- by its worst window, so the totals match the configured count.
		if #prov.limits > 0 then
			local sev = M.providerWorst(prov)
			if sev == "ok" then
				c.ok += 1
			elseif sev == "low" then
				c.low += 1
			elseif sev == "exhausted" then
				c.exhausted += 1
			else
				c.unknown += 1
			end
		end
	end
	c.disabled = #snap.disabled
	c.noUsage = #snap.noUsage
end

----------------------------------------------------------------------------
-- severity helpers over providers

function M.providerWorst(prov: Provider): string
	local worst = "ok"
	for _, l in prov.limits do
		local sev = M.severity(l)
		if M.SEVERITY_RANK[sev] < M.SEVERITY_RANK[worst] then
			worst = sev
		end
	end
	return worst
end

-- Best remaining fraction of a provider, nil when nothing is reported.
function M.providerBest(prov: Provider): number?
	local best: number? = nil
	for _, l in prov.limits do
		local f = M.remainingFill(l)
		if f ~= nil and (best == nil or f > (best :: number)) then
			best = f
		end
	end
	return best
end

----------------------------------------------------------------------------
-- duration / percent formatting and status-line summary

-- "due" for <= 0, otherwise at most two units: 2d 3h / 5h 12m / 4m / 30s.
function M.percent(remainingFraction: number): string
	local p = math.floor(remainingFraction * 100 + 0.5)
	if remainingFraction > 0 and p == 0 then
		return "<1%"
	end
	if p >= 100 and remainingFraction < 1 then
		p = 99
	end
	return p .. "%"
end

-- Status segments: at most one limit per provider (its most-consumed window),
-- so two slots never both come from the same provider. Exhausted windows (0%)
-- only take a slot when a provider has nothing else to show — the summary
-- count already reports them, and a stuck 0% until reset is not actionable.
-- Returns { { limit = Limit, provider = Provider } } sorted most-urgent first.
function M.urgentLimits(snap: Snapshot, max: number): { { limit: Limit, provider: Provider } }
	local candidates: { { limit: Limit, provider: Provider, live: boolean } } = {}
	for _, prov in snap.providers do
		local best: Limit? = nil
		local bestFill = math.huge
		local zero: Limit? = nil
		for _, l in prov.limits do
			local f = M.remainingFill(l)
			if f ~= nil then
				if f <= 0 then
					if zero == nil then
						zero = l
					end
				elseif f < bestFill then
					bestFill = f
					best = l
				end
			end
		end
		if best ~= nil then
			table.insert(candidates, { limit = best, provider = prov, live = true })
		elseif zero ~= nil then
			table.insert(candidates, { limit = zero, provider = prov, live = false })
		end
	end
	table.sort(candidates, function(a, b)
		if a.live ~= b.live then
			return a.live -- live windows first: exhausted ones wait in the summary count
		end
		local fa = M.remainingFill(a.limit) :: number
		local fb = M.remainingFill(b.limit) :: number
		if fa ~= fb then
			return fa < fb
		end
		return a.provider.key < b.provider.key
	end)
	local out: { { limit: Limit, provider: Provider } } = {}
	for i = 1, math.min(max, #candidates) do
		table.insert(out, { limit = candidates[i].limit, provider = candidates[i].provider })
	end
	return out
end

-- Short name for tight status segments: "Kimi Code" -> "Kimi",
-- "MiniMax CN" -> "MiniMax", "Z.AI" stays.
function M.shortProviderName(name: string): string
	return (name:gsub(" .*", ""))
end

-- summary(snap, now, opts) -> { text, tone, segments } for the status line
-- and the kv record. opts.error / opts.lastSuccess / opts.refreshing shape it.
function M.summary(snap: Snapshot?, nowMs: number, opts: { error: string?, lastSuccess: number?, refreshing: boolean? }): Summary
	if snap == nil then
		local text = if opts.refreshing then "额度 · 读取中" else "额度 · 暂无数据"
		return { text = text, tone = "muted", segments = { { text = text, tone = "muted" } } }
	end
	local c = snap.counts
	local text: string
	local tone: string?
	if c.limits == 0 then
		text = string.format("%d 家已配置 · 无用量端点", c.providers)
		tone = "muted"
	else
		local worst = "ok"
		for _, prov in snap.providers do
			local sev = M.providerWorst(prov)
			if M.SEVERITY_RANK[sev] < M.SEVERITY_RANK[worst] then
				worst = sev
			end
		end
		if worst == "exhausted" then
			text = string.format("额度 · %d 耗尽", c.exhausted)
			tone = "error"
		elseif worst == "low" then
			text = string.format("额度 · %d 偏低", c.low)
			tone = "warning"
		elseif worst == "unknown" then
			text = "额度 · 部分未上报"
			tone = nil
		else
			text = "额度 · 正常"
			tone = "success"
		end
	end
	if opts.error ~= nil then
		text ..= "（旧）"
		if tone == nil or tone == "success" then
			tone = "warning"
		end
	end

	local segments: { Segment } = { { text = text, tone = tone } }
	for _, pair in M.urgentLimits(snap, 2) do
		local l = pair.limit
		local sev = M.severity(l)
		local fill = M.remainingFill(l) :: number
		local name = l.windowLabel
		if name == nil or name == "" then
			name = l.label
		end
		table.insert(segments, {
			text = string.format(
				"%s %s %s",
				M.shortProviderName(pair.provider.name),
				name,
				M.percent(fill)
			),
			tone = if sev == "exhausted" then "error" elseif sev == "low" then "warning" else nil,
		})
	end
	if c.disabled > 0 then
		table.insert(segments, { text = string.format("%d 需登录", c.disabled), tone = "warning" })
	end
	return { text = text, tone = tone, segments = segments }
end

-- Back-compat alias used by collector deps.
M.normalize = normalizeUsage

return M
