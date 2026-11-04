--!strict
-- provider-quota balance adapters: for providers omp cannot report usage for,
-- query the provider's own documented balance/quota endpoint with the API key
-- omp has stored (`omp token <provider>`).
--
-- Keys live only in host VM memory and in request headers: never kv, never
-- logs, never snapshots. A failing adapter degrades to the plain catalog row.

local M = {}

export type LimitDraft = {
	key: string,
	label: string,
	windowLabel: string?,
	remainingFraction: number?,
	remaining: number?,
	unit: string?,
	resetsAt: number?,
	status: string,
	amountText: string?,
	isBalance: boolean?,
}

export type Adapter = {
	-- Tried in order; first 200 response whose parse returns rows wins.
	urls: { string },
	-- Pure: JSON body -> limit rows, or nil when the shape is unexpected.
	parse: (body: string) -> { LimitDraft }?,
}

local function num(v: any): number?
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
		return v
	end
	if type(v) == "string" then
		local n = tonumber(v)
		if n ~= nil and n == n and n ~= math.huge and n ~= -math.huge then
			return n
		end
	end
	return nil
end

local function get(t: any, field: string): any
	if type(t) ~= "table" then
		return nil
	end
	return (t :: { [string]: any })[field]
end

----------------------------------------------------------------------------
-- DeepSeek: GET /user/balance
-- {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"26.39",…}]}

local function parseDeepSeek(body: string, decode: (string) -> any): { LimitDraft }?
	local ok, data = pcall(function()
		return decode(body)
	end)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local infos = get(data, "balance_infos")
	if type(infos) ~= "table" or #(infos :: any) == 0 then
		return nil
	end
	local first = (infos :: any)[1]
	local total = num(get(first, "total_balance"))
	local currency = get(first, "currency") or "CNY"
	if total == nil then
		return nil
	end
	local symbol = if currency == "CNY" then "¥" elseif currency == "USD" then "$" else (currency .. " ")
	return {
		{
			key = "deepseek:balance",
			label = "余额",
			remainingFraction = nil,
			remaining = total,
			unit = currency,
			resetsAt = nil,
			status = "ok",
			amountText = string.format("%s%.2f", symbol, total),
			isBalance = true,
		} :: LimitDraft,
	}
end

----------------------------------------------------------------------------
-- MiniMax CN: GET /v1/token_plan/remains
-- {"model_remains":[{model_name, current_interval_total_count,
--   current_interval_usage_count, current_interval_remaining_percent?,
--   end_time, current_weekly_total_count, current_weekly_usage_count,
--   current_weekly_remaining_percent?, weekly_end_time, …}],
--  "base_resp":{"status_code":0,…}}
-- China endpoint reports USED counts; percent fields, when present, are
-- authoritative (counts can be 0 while percent is populated).

local MINIMAX_WINDOWS = {
	{
		label = "5 小时",
		percentField = "current_interval_remaining_percent",
		usedField = "current_interval_usage_count",
		totalField = "current_interval_total_count",
		endField = "end_time",
		key = "minimax:5h",
	},
	{
		label = "本周",
		percentField = "current_weekly_remaining_percent",
		usedField = "current_weekly_usage_count",
		totalField = "current_weekly_total_count",
		endField = "weekly_end_time",
		key = "minimax:weekly",
	},
}

local function parseMiniMax(body: string, decode: (string) -> any): { LimitDraft }?
	local ok, data = pcall(function()
		return decode(body)
	end)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local base = get(data, "base_resp")
	if base ~= nil and num(get(base, "status_code")) ~= nil and num(get(base, "status_code")) ~= 0 then
		return nil
	end
	local models = get(data, "model_remains")
	if type(models) ~= "table" or #(models :: any) == 0 then
		return nil
	end

	local out: { LimitDraft } = {}
	for _, w in MINIMAX_WINDOWS do
		local bestPercent: number? = nil
		local bestEnd: number? = nil
		for _, m in models :: { any } do
			if type(m) == "table" and type(get(m, "model_name")) == "string" then
				local pct = num(get(m, w.percentField))
				local endTime = num(get(m, w.endField))
				if pct == nil then
					-- Fallback: china counts are used amounts.
					local used = num(get(m, w.usedField))
					local total = num(get(m, w.totalField))
					if used ~= nil and total ~= nil and total > 0 then
						pct = math.clamp((1 - used / total) * 100, 0, 100)
					end
				end
				if pct ~= nil and (bestPercent == nil or pct < (bestPercent :: number)) then
					bestPercent = pct
					bestEnd = endTime
				end
			end
		end
		if bestPercent ~= nil then
			table.insert(out, {
				key = w.key,
				label = "MiniMax " .. w.label,
				windowLabel = w.label,
				remainingFraction = math.clamp((bestPercent :: number) / 100, 0, 1),
				remaining = nil,
				unit = "requests",
				resetsAt = bestEnd,
				status = "ok",
				amountText = nil,
				isBalance = false,
			} :: LimitDraft)
		end
	end
	if #out == 0 then
		return nil
	end
	return out
end

----------------------------------------------------------------------------
-- OpenCode Go: GET /zen/go/v1/usage (official, PR anomalyco/opencode#16513)
-- {"usage":{"rolling":{"status":"ok","percent":12,"resetsAt":"2026-…T…Z"},
--          "weekly":{…},"monthly":{…}}}
-- percent is plan usage CONSUMED in the window; resetsAt is ISO-8601 UTC.

-- UTC ISO-8601 -> epoch ms, via the standard local/UTC round-trip trick.
local function isoToEpochMs(iso: string): number?
	local y, m, d, h, mi, s = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
	if y == nil then
		return nil
	end
	local t = {
		year = tonumber(y) :: number,
		month = tonumber(m) :: number,
		day = tonumber(d) :: number,
		hour = tonumber(h) :: number,
		min = tonumber(mi) :: number,
		sec = tonumber(s) :: number,
	}
	local localEpoch = os.time(t)
	if localEpoch == nil then
		return nil
	end
	local asUtc = os.time(os.date("!*t", localEpoch) :: any)
	if asUtc == nil then
		return nil
	end
	return (localEpoch - (asUtc - localEpoch)) * 1000
end

local OPENCODE_WINDOWS = {
	{ field = "rolling", label = "5 小时", key = "opencode:5h" },
	{ field = "weekly", label = "本周", key = "opencode:weekly" },
	{ field = "monthly", label = "本月", key = "opencode:monthly" },
}

local function parseOpenCode(body: string, decode: (string) -> any): { LimitDraft }?
	local ok, data = pcall(function()
		return decode(body)
	end)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local usage = get(data, "usage")
	if type(usage) ~= "table" then
		return nil
	end
	local out: { LimitDraft } = {}
	for _, w in OPENCODE_WINDOWS do
		local win = get(usage, w.field)
		if type(win) == "table" then
			local pct = num(get(win, "percent"))
			if pct ~= nil then
				local status = get(win, "status")
				table.insert(out, {
					key = w.key,
					label = "OpenCode " .. w.label,
					windowLabel = w.label,
					remainingFraction = math.clamp(1 - pct / 100, 0, 1),
					remaining = nil,
					unit = "requests",
					resetsAt = if type(get(win, "resetsAt")) == "string"
						then isoToEpochMs(get(win, "resetsAt") :: string)
						else nil,
					status = if type(status) == "string" and (status :: string) ~= "ok"
						then (status :: string)
						else "ok",
					amountText = nil,
					isBalance = false,
				} :: LimitDraft)
			end
		end
	end
	if #out == 0 then
		return nil
	end
	return out
end

----------------------------------------------------------------------------
-- Kimi Code: GET /coding/v1/usages (api.kimi.com 国内 / api.kimi.ai 国际，
-- 旧全球区回退 api.moonshot.ai/v1/usages；与官方 CLI /usage 同源)。
-- 新版: {"usages":{"limit_5h":{"used_ratio":0,"reset_time":"…Z"},
--                  "limit_7d":{…},"limit_month_total":{…}, …}}
-- 旧版: {"usage":{"limit","remaining","resetTime"}} /
--       {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
--                  "detail":{"limit","remaining","resetTime"}}]}

local KIMI_WINDOWS = {
	{ key = "kimi:5h", id = "limit_5h", label = "5 小时" },
	{ key = "kimi:7d", id = "limit_7d", label = "本周" },
	{ key = "kimi:month_total", id = "limit_month_total", label = "本月" },
	{ key = "kimi:month_code", id = "limit_month_code", label = "本月 Code" },
}

-- Legacy limits[] window duration (minutes) -> label.
local function kimiLegacyLabel(minutes: number): string?
	if minutes == 300 then
		return "5 小时"
	elseif minutes == 10080 then
		return "本周"
	elseif minutes == 43200 then
		return "本月"
	end
	return nil
end

local function parseKimi(body: string, decode: (string) -> any): { LimitDraft }?
	local ok, data = pcall(function()
		return decode(body)
	end)
	if not ok or type(data) ~= "table" then
		return nil
	end

	-- New format: ratio pools.
	local pools = get(data, "usages")
	if type(pools) == "table" then
		local out: { LimitDraft } = {}
		for _, w in KIMI_WINDOWS do
			local pool = get(pools, w.id)
			if type(pool) == "table" then
				local ratio = num(get(pool, "used_ratio"))
				if ratio ~= nil then
					table.insert(out, {
						key = w.key,
						label = "Kimi Code " .. w.label,
						windowLabel = w.label,
						remainingFraction = math.clamp(1 - ratio, 0, 1),
						remaining = nil,
						unit = "requests",
						resetsAt = if type(get(pool, "reset_time")) == "string"
							then isoToEpochMs(get(pool, "reset_time") :: string)
							else nil,
						status = "ok",
						amountText = nil,
						isBalance = false,
					} :: LimitDraft)
				end
			end
		end
		if #out > 0 then
			return out
		end
	end

	-- Legacy: top-level usage {limit, remaining, resetTime}.
	local usage = get(data, "usage")
	if type(usage) == "table" then
		local limit = num(get(usage, "limit"))
		local remaining = num(get(usage, "remaining"))
		if limit ~= nil and remaining ~= nil and limit > 0 then
			return {
				{
					key = "kimi:main",
					label = "Kimi Code",
					remainingFraction = math.clamp(remaining / limit, 0, 1),
					remaining = nil,
					unit = "requests",
					resetsAt = if type(get(usage, "resetTime")) == "string"
						then isoToEpochMs(get(usage, "resetTime") :: string)
						else nil,
					status = "ok",
					amountText = nil,
					isBalance = false,
				} :: LimitDraft,
			}
		end
	end

	-- Legacy: limits[] with minute windows.
	local limits = get(data, "limits")
	if type(limits) == "table" then
		local out: { LimitDraft } = {}
		for _, l in limits :: { any } do
			if type(l) == "table" then
				local win = get(l, "window")
				local detail = get(l, "detail")
				local minutes = if type(win) == "table" then num(get(win, "duration")) else nil
				local label = if minutes ~= nil then kimiLegacyLabel(minutes) else nil
				local limit = if type(detail) == "table" then num(get(detail, "limit")) else nil
				local remaining = if type(detail) == "table" then num(get(detail, "remaining")) else nil
				if label ~= nil and limit ~= nil and remaining ~= nil and limit > 0 then
					table.insert(out, {
						key = "kimi:" .. label,
						label = "Kimi Code " .. label,
						windowLabel = label,
						remainingFraction = math.clamp(remaining / limit, 0, 1),
						remaining = nil,
						unit = "requests",
						resetsAt = if type(detail) == "table" and type(get(detail, "resetTime")) == "string"
							then isoToEpochMs(get(detail, "resetTime") :: string)
							else nil,
						status = "ok",
						amountText = nil,
						isBalance = false,
					} :: LimitDraft)
				end
			end
		end
		if #out > 0 then
			return out
		end
	end

	return nil
end

M.adapters = {
	deepseek = {
		urls = { "https://api.deepseek.com/user/balance" },
		parse = parseDeepSeek,
	} :: Adapter,
	moonshot = {
		-- KIMI_API_KEY is a Kimi Code key (api.kimi.com/coding/…): quota pools
		-- per window, same source as the official CLI /usage.
		urls = {
			"https://api.kimi.com/coding/v1/usages",
			"https://api.kimi.ai/coding/v1/usages",
			"https://api.moonshot.ai/v1/usages",
		},
		parse = parseKimi,
	} :: Adapter,
	["minimax-code-cn"] = {
		urls = { "https://api.minimaxi.com/v1/token_plan/remains" },
		parse = parseMiniMax,
	} :: Adapter,
	["opencode-go"] = {
		urls = { "https://opencode.ai/zen/go/v1/usage" },
		parse = parseOpenCode,
	} :: Adapter,
}

-- Parse signature: (body: string, decode: (string) -> any) -> { LimitDraft }?
-- The host passes tern.json.decode so this module never touches the tern global.

return M
