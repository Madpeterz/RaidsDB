-- RaidsDB Main Module
local api = require("api")
local raidlog = require("RaidsDB/raidlog")
local button = require("RaidsDB/button")

local RaidsDB = {
	name = "RaidsDB",
	author = "Madpeter",
	version = "1.0.1",
	desc = "Logs raid drops and players"
}

-- loot events, read in raidlog.AddDrop
local DROP_EVENTS = {
	-- everyone in the raid except you
	"ITEM_ACQUISITION_BY_LOOT",
	-- your own items
	"ADDED_ITEM",
}
-- TEAM_MEMBERS_CHANGED fires in bursts (people joining, swapping groups), so wait and scan once
local MEMBER_SCAN_DELAY_MS = 2000

local isDropEvent = {}
for _, name in ipairs(DROP_EVENTS) do
	isDropEvent[name] = true
end

local memberScanPending = false

-- errors never reach chat; they are kept in RaidsDB/errors.dat
local function runSafe(fn)
	local ok, result = pcall(fn)
	if not ok then
		pcall(raidlog.LogError, result)
		return nil
	end
	return result
end

local function queueMemberScan()
	if memberScanPending then
		return
	end
	memberScanPending = true
	api:DoIn(MEMBER_SCAN_DELAY_MS, function()
		memberScanPending = false
		if RaidsDB.eventWindow == nil then
			return -- unloaded meanwhile
		end
		runSafe(raidlog.ScanMembers)
	end)
end

-- the button was clicked: start a new raid, or stop and save the current one
local function toggleRaid()
	if raidlog.IsRecording() then
		local path, totals
		runSafe(function()
			path, totals = raidlog.Finish()
		end)
		if path ~= nil then
			api.Log:Info("[" .. RaidsDB.name .. "] raid saved to " .. path .. " (" .. totals.players
				.. " players, " .. totals.drops .. " drops, " .. totals.duration .. ")")
		end
	else
		runSafe(raidlog.Start)
		api.Log:Info("[" .. RaidsDB.name .. "] new raid started, logging drops and players")
	end
	runSafe(function()
		button.SetRecording(raidlog.IsRecording())
	end)
end

-- Addon initialization
local function OnLoad()
	local resumed = runSafe(raidlog.Resume)
	api.Log:Info("[" .. RaidsDB.name .. "] Starting version " .. RaidsDB.version
		.. (resumed and ", still recording the raid from before the reload" or ""))
	-- hidden window, only used to receive game events
	RaidsDB.eventWindow = api.Interface:CreateEmptyWindow("RaidsDBEvents")
	RaidsDB.eventWindow:Show(false)
	runSafe(function()
		button.Create(toggleRaid, raidlog.StatusText)
		button.SetRecording(raidlog.IsRecording())
	end)
	-- attach events
	function RaidsDB:EventListener(event, ...)
		if not raidlog.IsRecording() then
			return
		end
		if event == "TEAM_MEMBERS_CHANGED" then
			queueMemberScan()
		elseif isDropEvent[event] then
			local a1, a2, a3, a4, a5, a6, a7, a8 = ...
			runSafe(function()
				raidlog.AddDrop(event, a1, a2, a3, a4, a5, a6, a7, a8)
			end)
		end
	end
	RaidsDB.eventWindow:SetHandler("OnEvent", RaidsDB.EventListener)
	RaidsDB.eventWindow:RegisterEvent("TEAM_MEMBERS_CHANGED")
	for _, name in ipairs(DROP_EVENTS) do
		RaidsDB.eventWindow:RegisterEvent(name)
	end
	-- members may have changed while unloaded
	if raidlog.IsRecording() then
		queueMemberScan()
	end
end

-- Addon cleanup; a raid still recording stays in current.dat and resumes on the next load
local function OnUnload()
	-- Unregister events
	if RaidsDB.eventWindow ~= nil then
		RaidsDB.eventWindow:ReleaseHandler("OnEvent")
		api.Interface:Free(RaidsDB.eventWindow)
		RaidsDB.eventWindow = nil
	end
	runSafe(button.Free)
end

RaidsDB.OnSettingToggle = nil

RaidsDB.OnLoad = OnLoad
RaidsDB.OnUnload = OnUnload

return RaidsDB
