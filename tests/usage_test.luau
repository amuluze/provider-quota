--!strict
-- Regression tests for provider-quota's pure logic (usage.luau).
--
-- Run: luau tests/usage_test.luau
--
-- The Command Code case matters: omp reports its windows with used/limit and
-- no remainingFraction, so a naive read of amount.remainingFraction leaves
-- every row without a meter.

local usage = require("../usage")

local passed = 0
local failed = 0

local function check(name: string, ok: boolean, detail: string?)
	if ok then
		passed += 1
		print("ok   " .. name)
	else
		failed += 1
		print("FAIL " .. name .. (if detail ~= nil then " — " .. detail else ""))
	end
end

local function eq(name: string, got: any, want: any)
	check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

-- A Command Code report as omp emits it: used/limit, no remainingFraction.
local COMMAND_CODE = {
	generatedAt = 1000,
	reports = {
		{
			provider = "commandcode",
			fetchedAt = 900,
			limits = {
				{
					id = "commandcode:5h",
					label = "5-hour limit",
					window = { id = "5h", label = "5-hour", durationMs = 18000000, resetsAt = 2000 },
					amount = { used = 3.5, limit = 14, usedFraction = 0.25, unit = "credits" },
					status = "ok",
				},
				{
					id = "commandcode:7d",
					label = "Weekly limit",
					window = { id = "7d", label = "Weekly", durationMs = 604800000, resetsAt = 9000 },
					amount = { used = 7, limit = 35, usedFraction = 0.2, unit = "credits" },
					status = "ok",
				},
				{
					id = "commandcode:balance",
					label = "Credit balance",
					amount = { remaining = 56.5, unit = "credits" },
					status = "ok",
				},
			},
			metadata = { planType = "pro" },
		},
	},
}

do
	local snap = usage.normalize(COMMAND_CODE)
	local prov = snap.providers[1]
	eq("commandcode: one provider", #snap.providers, 1)
	eq("commandcode: display name", prov and prov.name, "Command Code")
	eq("commandcode: three limits", prov and #prov.limits, 3)

	local fiveHour = prov and prov.limits[1]
	eq("commandcode 5h: remaining fraction derived", fiveHour and fiveHour.remainingFraction, 0.75)
	eq("commandcode 5h: remaining derived", fiveHour and fiveHour.remaining, 10.5)
	eq("commandcode 5h: severity", fiveHour and usage.severity(fiveHour), "ok")

	local weekly = prov and prov.limits[2]
	eq("commandcode 7d: remaining fraction derived", weekly and weekly.remainingFraction, 0.8)
	eq("commandcode 7d: severity", weekly and usage.severity(weekly), "ok")

	local balance = prov and prov.limits[3]
	eq("commandcode balance: is a balance row", balance and balance.isBalance, true)
	eq("commandcode balance: no fraction", balance and balance.remainingFraction, nil)
	eq("commandcode balance: amount text", balance and balance.amountText, "56.50 credits")
	eq("commandcode balance: not a direct query", balance and balance.isDirect, nil)

	eq("commandcode: provider severity", prov and usage.providerWorst(prov), "ok")
	eq("commandcode: counts it as reported", snap.counts.reported, 1)
	eq("commandcode: no unknown providers", snap.counts.unknown, 0)
end

-- A provider that reports a remaining amount but no cap: no share can be
-- claimed, so the row shows the amount without a meter.
do
	local snap = usage.normalize({
		generatedAt = 1000,
		reports = {
			{
				provider = "acme",
				limits = {
					{ id = "acme:1", label = "Tokens", amount = { remaining = 42, unit = "tokens" } },
				},
			},
		},
	})
	local l = snap.providers[1].limits[1]
	eq("no cap: no fraction", l.remainingFraction, nil)
	eq("no cap: remaining kept", l.remaining, 42)
	eq("no cap: renders as an amount row", l.isBalance, true)
	eq("no cap: amount text", l.amountText, "42.00 tokens")
end

-- A provider reporting a fraction is untouched by the derivation.
do
	local snap = usage.normalize({
		generatedAt = 1000,
		reports = {
			{
				provider = "zai",
				limits = {
					{
						id = "zai:tokens:1w",
						label = "ZAI Weekly Token Quota",
						window = { id = "1w", label = "Weekly", resetsAt = 5000 },
						amount = { usedFraction = 0.85, remainingFraction = 0.15, unit = "tokens" },
						status = "ok",
					},
				},
			},
		},
	})
	local l = snap.providers[1].limits[1]
	eq("reported fraction kept", l.remainingFraction, 0.15)
	eq("reported fraction severity", usage.severity(l), "ok")
end

-- An empty balance means the provider is spent, not fine.
do
	local l = { key = "x", label = "余额", status = "", isBalance = true, remaining = 0 } :: usage.Limit
	eq("empty balance: exhausted", usage.severity(l), "exhausted")
	local funded = { key = "y", label = "余额", status = "", isBalance = true, remaining = 5 } :: usage.Limit
	eq("funded balance: ok", usage.severity(funded), "ok")
end

-- Product names that must not be truncated in the status line.
do
	eq("short name: Kimi Code kept whole", usage.shortProviderName("Kimi Code"), "Kimi Code")
	eq("short name: Command Code kept whole", usage.shortProviderName("Command Code"), "Command Code")
	eq("short name: MiniMax CN truncated", usage.shortProviderName("MiniMax CN"), "MiniMax")
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("usage tests failed")
end
