-- RaidsDB Main Module
local api = require("api")
local raidlog = require("RaidsDB/raidlog")
local button = require("RaidsDB/button")

local RaidsDB = {
	name = "RaidsDB",
	author = "Madpeter",
	version = "1.4.0",
	desc = "Logs raid and instance drops and players"
}

-- loot events, read in recorder.AddDrop
local DROP_EVENTS = {
	-- everyone in the raid except you
	"ITEM_ACQUISITION_BY_LOOT",
	-- your own items
	"ADDED_ITEM",
}
-- while recording, the raid members are scanned this often: joins, leaves and anyone who
-- couldn't be read yet are all picked up by the next scan
local MEMBER_SCAN_INTERVAL_MS = 3000

local isDropEvent = {}
for _, name in ipairs(DROP_EVENTS) do
	isDropEvent[name] = true
end

-- one recorder per button; they record independently and can run at the same time
local recorders = {
	{
		id = "raid",
		idle = "record.png",
		recording = "save.png",
		log = raidlog.New({
			dir = "RaidsDB/Raids/",
			currentPath = "RaidsDB/current.dat",
			title = "Raid drops",
			noun = "raid",
			screenshots = true,
		}),
	},
	{
		id = "instance",
		idle = "party.png",
		recording = "party_save.png",
		log = raidlog.New({
			dir = "RaidsDB/Instances/",
			currentPath = "RaidsDB/current_instance.dat",
			title = "Instance drops",
			noun = "instance run",
			instance = true,
		}),
	},
}

-- bumped on load and unload; a scan loop from an earlier load sees a newer id and stops
local loadId = 0

local function say(text)
	api.Log:Info("[" .. RaidsDB.name .. "] " .. text)
end

-- errors never reach chat; they are kept in RaidsDB/errors.dat
local function runSafe(fn)
	local ok, result = pcall(fn)
	if not ok then
		pcall(raidlog.LogError, result)
		return nil
	end
	return result
end

local function scanRegularly(id)
	api:DoIn(MEMBER_SCAN_INTERVAL_MS, function()
		if id ~= loadId then
			return -- unloaded or reloaded meanwhile
		end
		for _, recorder in ipairs(recorders) do
			if recorder.log.IsRecording() then
				runSafe(recorder.log.ScanMembers)
			end
		end
		scanRegularly(id)
	end)
end

-- a button was clicked: start a new run, or stop and save the current one
local function toggle(recorder)
	local log = recorder.log
	if log.IsRecording() then
		local path, totals
		runSafe(function()
			path, totals = log.Finish()
		end)
		if path ~= nil then
			say(path .. " saved (" .. totals.players .. " players, " .. totals.drops .. " drops, "
				.. totals.duration .. ")")
		end
	else
		local ok, message
		runSafe(function()
			ok, message = log.Start()
		end)
		if message ~= nil then
			say(message)
		end
	end
	runSafe(function()
		button.SetRecording(recorder.id, log.IsRecording())
	end)
end

-- Addon initialization
local function OnLoad()
	raidlog.SetAddonVersion(RaidsDB.version)
	local resumed = {}
	for _, recorder in ipairs(recorders) do
		if runSafe(recorder.log.Resume) then
			resumed[#resumed + 1] = recorder.id
		end
	end
	say("Starting version " .. RaidsDB.version
		.. (#resumed > 0 and (", still recording from before the reload: " .. table.concat(resumed, ", ")) or ""))
	-- hidden window, only used to receive game events
	RaidsDB.eventWindow = api.Interface:CreateEmptyWindow("RaidsDBEvents")
	RaidsDB.eventWindow:Show(false)
	runSafe(function()
		local specs = {}
		for _, recorder in ipairs(recorders) do
			specs[#specs + 1] = {
				id = recorder.id,
				idle = recorder.idle,
				recording = recorder.recording,
				onClick = function() toggle(recorder) end,
				status = recorder.log.StatusText,
			}
		end
		button.Create(specs)
		for _, recorder in ipairs(recorders) do
			button.SetRecording(recorder.id, recorder.log.IsRecording())
		end
	end)
	-- attach events
	function RaidsDB:EventListener(event, ...)
		if not isDropEvent[event] then
			return
		end
		local a1, a2, a3, a4, a5, a6, a7, a8 = ...
		for _, recorder in ipairs(recorders) do
			if recorder.log.IsRecording() then
				runSafe(function()
					recorder.log.AddDrop(event, a1, a2, a3, a4, a5, a6, a7, a8)
				end)
			end
		end
	end
	RaidsDB.eventWindow:SetHandler("OnEvent", RaidsDB.EventListener)
	for _, name in ipairs(DROP_EVENTS) do
		RaidsDB.eventWindow:RegisterEvent(name)
	end
	-- members are scanned from the first tick on, also after a reload mid run
	loadId = loadId + 1
	scanRegularly(loadId)
end

-- Addon cleanup; a run still recording stays in its current file and resumes on the next load
local function OnUnload()
	loadId = loadId + 1
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
