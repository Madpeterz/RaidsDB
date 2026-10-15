local api = require("api")

-- The raid being recorded: who was in it and every item that dropped.
-- While recording, everything is kept in current.dat so a reload or crash resumes the raid;
-- Finish() moves it to Raids/<start date>.dat.
local raidlog = {}

local ADDON_DIR = "RaidsDB/"
local RAIDS_DIR = ADDON_DIR .. "Raids/"
local CURRENT_PATH = ADDON_DIR .. "current.dat"
-- errors go here instead of chat; only the newest are kept
local ERRORS_PATH = ADDON_DIR .. "errors.dat"
local MAX_ERRORS = 20
local MAX_TEAM_MEMBERS = 50
-- ADDED_ITEM's third argument says where the item came from; these are loot
-- (crafting, buying, mail etc. use other codes and are not drops). Turn DEBUG on to see
-- the codes of items that were left out.
local ADDED_ITEM_LOOT = {
	[10] = true,
	[35] = true,
}

-- dev: keep the raw arguments of every loot event (also the ones not saved as drops) and
-- write a copy of the raid with them next to it, as Raids/<start date>.raw
local DEBUG = false
local MAX_RAW_EVENTS = 1000
local RAW_ARG_COUNT = 8

local raid = nil

local function safeCall(fn)
	local ok, result = pcall(fn)
	if not ok then
		return nil
	end
	return result
end

-- File:Write rounds big numbers (8000641 -> 8.00064e+006), so numbers are saved as strings
local function numberToString(value)
	if value == math.floor(value) then
		return string.format("%.0f", value)
	end
	return string.format("%.14g", value)
end

local function count(map)
	local total = 0
	for _ in pairs(map) do
		total = total + 1
	end
	return total
end

-- ---------------------------------------------------------------------------
-- Time
-- api.Time:GetLocalTime() is unix seconds (UTC), but the game's Lua numbers are single
-- precision, so around 1.8e9 it only moves in steps of 128s: good for the date, not for
-- timing. Times within a raid are measured with the UI millisecond clock instead and saved
-- as time since the raid started ("0:12:05").
-- ---------------------------------------------------------------------------

-- how far the UI clock may drift from the coarse wall clock before it is taken as restarted
local CLOCK_TOLERANCE_SECONDS = 300

local function currentTime()
	return tonumber(safeCall(function() return api.Time:GetLocalTime() end))
end

local function uiMsec()
	return tonumber(safeCall(function() return api.Time:GetUiMsec() end))
end

-- Whole seconds since the raid started; never goes backwards.
local function elapsedSeconds()
	local now = uiMsec()
	local base = tonumber(raid.started_msec)
	local last = tonumber(raid.last_elapsed) or 0
	local wall, started = currentTime(), tonumber(raid.started)
	local byWall = (wall ~= nil and started ~= nil) and (wall - started) or nil
	local elapsed
	if now ~= nil and base ~= nil and now >= base
		and (byWall == nil or math.abs((now - base) / 1000 - byWall) < CLOCK_TOLERANCE_SECONDS) then
		elapsed = math.floor((now - base) / 1000)
	else
		-- the client restarted mid raid and the UI clock began again (or this raid was started
		-- by an older version): carry on from the coarse wall clock, exact again from here on
		elapsed = byWall and math.floor(byWall) or last
		if now ~= nil then
			raid.started_msec = numberToString(now - elapsed * 1000)
		end
	end
	elapsed = math.max(elapsed, last)
	raid.last_elapsed = numberToString(elapsed)
	return elapsed
end

-- "1:02:05"
local function elapsedText(seconds)
	return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
end

local function isLeapYear(year)
	return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

-- UTC, for when TimeToDate gives nothing usable
local function utcDate(seconds)
	local days = math.floor(seconds / 86400)
	local rest = seconds - days * 86400
	local year = 1970
	while days >= (isLeapYear(year) and 366 or 365) do
		days = days - (isLeapYear(year) and 366 or 365)
		year = year + 1
	end
	local monthDays = { 31, isLeapYear(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	local month = 1
	while days >= monthDays[month] do
		days = days - monthDays[month]
		month = month + 1
	end
	return year, month, days + 1, math.floor(rest / 3600), math.floor(rest % 3600 / 60), rest % 60
end

local function dateParts(seconds)
	local date = safeCall(function() return api.Time:TimeToDate(seconds) end)
	if type(date) == "table" then
		local year, month, day = tonumber(date.year), tonumber(date.month), tonumber(date.day)
		local hour = tonumber(date.hour)
		local minute = tonumber(date.min or date.minute)
		local second = tonumber(date.sec or date.second)
		if year and month and day and hour and minute and second then
			return year, month, day, hour, minute, second
		end
	end
	return utcDate(math.floor(seconds))
end

-- "2026-10-15 22:40:05"
local function dateText(seconds)
	return string.format("%04d-%02d-%02d %02d:%02d:%02d", dateParts(seconds))
end

-- "2026-10-15_22-40-05", safe as a file name
local function fileDate(seconds)
	return string.format("%04d-%02d-%02d_%02d-%02d-%02d", dateParts(seconds))
end

local function formatDuration(seconds)
	seconds = math.max(0, math.floor(seconds))
	local minutes = math.floor(seconds / 60)
	if minutes < 60 then
		return minutes .. "m"
	end
	return math.floor(minutes / 60) .. "h " .. (minutes % 60) .. "m"
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

-- item links read like "|i<itemType>,...": the item type is the number after "|i"
local function itemTypeFromLink(link)
	return tonumber(string.match(link, "^|i(%d+)"))
end

local function itemName(itemType)
	if itemType == nil then
		return nil
	end
	local info = safeCall(function() return api.Item:GetItemInfoByType(itemType) end)
	if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
		return info.name
	end
	return nil
end

-- strings and numbers as File:Write can keep them, anything else as "<type>"
local function plainArg(value)
	if type(value) == "number" then
		return numberToString(value)
	elseif type(value) == "string" or type(value) == "boolean" then
		return value
	elseif value == nil then
		return "<nil>"
	end
	return "<" .. type(value) .. ">"
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local function saveCurrent()
	api.File:Write(CURRENT_PATH, raid or { recording = false })
end

-- keeps the newest MAX_ERRORS messages in ERRORS_PATH
function raidlog.LogError(message)
	local list = api.File:Read(ERRORS_PATH)
	if type(list) ~= "table" then
		list = {}
	end
	local seen = currentTime()
	list[#list + 1] = {
		time = seen and numberToString(seen) or nil,
		message = tostring(message),
	}
	while #list > MAX_ERRORS do
		table.remove(list, 1)
	end
	api.File:Write(ERRORS_PATH, list)
end

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------

local function recordMember(unit, seen)
	local unitId = safeCall(function() return api.Unit:GetUnitId(unit) end)
	if unitId == nil then
		return false
	end
	local name = safeCall(function() return api.Unit:UnitName(unit) end)
	if type(name) ~= "string" or name == "" then
		name = safeCall(function() return api.Unit:GetUnitNameById(unitId) end)
	end
	if type(name) ~= "string" or name == "" then
		return false
	end
	local member = raid.members[name]
	if member == nil then
		member = { name = name, first_seen = seen }
		raid.members[name] = member
	end
	member.last_seen = seen
	-- out of range members may not give a class yet; a later scan fills it in
	local class = safeCall(function() return api.Ability:GetUnitClassName(unit) end)
	if type(class) == "string" and class ~= "" then
		member.class = class
	end
	return true
end

-- Adds everyone currently in the party/raid (and yourself). Returns how many were seen.
function raidlog.ScanMembers()
	if raid == nil then
		return 0
	end
	local seen = elapsedText(elapsedSeconds())
	local found = 0
	for i = 1, MAX_TEAM_MEMBERS do
		if recordMember("team" .. i, seen) then
			found = found + 1
		end
	end
	recordMember("player", seen)
	saveCurrent()
	return found
end

-- ---------------------------------------------------------------------------
-- Drops
-- ---------------------------------------------------------------------------

-- the same broadcast can arrive twice; an identical drop within the same second is that repeat
local function isDuplicate(entry)
	for i = #raid.drops, 1, -1 do
		local other = raid.drops[i]
		if other.time ~= entry.time then
			return false
		end
		if other.player == entry.player and other.item == entry.item and other.count == entry.count then
			return true
		end
	end
	return false
end

local function ownName()
	local name = safeCall(function() return api.Unit:UnitName("player") end)
	if type(name) == "string" and name ~= "" then
		return name
	end
	return nil
end

local function recordRaw(event, args)
	if raid.raw_events == nil then
		raid.raw_events = {}
	end
	if #raid.raw_events >= MAX_RAW_EVENTS then
		return
	end
	local raw = {}
	for i = 1, RAW_ARG_COUNT do
		raw[i] = plainArg(args[i])
	end
	raid.raw_events[#raid.raw_events + 1] = {
		time = elapsedText(elapsedSeconds()),
		event = event,
		args = raw,
	}
end

-- Records one loot event:
--   ITEM_ACQUISITION_BY_LOOT(player, link, count) everyone in the raid except you
--   ADDED_ITEM(link, count, source, "")          your own items; only kept when looted
-- Returns the saved drop, or nil (not recording, not a drop, or a repeat).
function raidlog.AddDrop(event, a1, a2, a3, a4, a5, a6, a7, a8)
	if raid == nil then
		return nil
	end
	if DEBUG then
		recordRaw(event, { a1, a2, a3, a4, a5, a6, a7, a8 })
		saveCurrent()
	end
	local player, link, amount
	if event == "ADDED_ITEM" then
		if not ADDED_ITEM_LOOT[tonumber(a3)] then
			return nil
		end
		player, link, amount = ownName(), a1, a2
	else
		player, link, amount = a1, a2, a3
	end
	if type(link) ~= "string" then
		return nil
	end

	local entry = {
		time = elapsedText(elapsedSeconds()),
		player = type(player) == "string" and player or "?",
		item = itemName(itemTypeFromLink(link)) or "?",
		count = numberToString(tonumber(amount) or 1),
	}
	if isDuplicate(entry) then
		return nil
	end
	raid.drops[#raid.drops + 1] = entry
	saveCurrent()
	return entry
end

-- ---------------------------------------------------------------------------
-- Raid
-- ---------------------------------------------------------------------------

function raidlog.IsRecording()
	return raid ~= nil
end

-- Picks up a raid that was still recording when the addon was unloaded. Returns true if one was.
function raidlog.Resume()
	local saved = api.File:Read(CURRENT_PATH)
	if type(saved) ~= "table" or saved.recording ~= true or saved.started == nil then
		return false
	end
	raid = saved
	raid.members = type(raid.members) == "table" and raid.members or {}
	raid.drops = type(raid.drops) == "table" and raid.drops or {}
	if not DEBUG then
		raid.raw_events = nil
	end
	return true
end

function raidlog.Start()
	local started = currentTime() or 0
	raid = {
		recording = true,
		started = numberToString(started),
		-- the wall clock is coarse, so this can be up to a minute off
		started_text = dateText(started),
		started_msec = numberToString(uiMsec() or 0),
		members = {},
		drops = {},
	}
	raidlog.ScanMembers()
end

-- Stops recording and writes the raid to Raids/. Returns the file path and the totals.
function raidlog.Finish()
	if raid == nil then
		return nil
	end
	raidlog.ScanMembers()
	local elapsed = elapsedSeconds()
	local ended = currentTime() or 0
	local started = tonumber(raid.started) or ended
	raid.recording = nil
	-- only needed while recording
	raid.started_msec = nil
	raid.last_elapsed = nil
	raid.ended = numberToString(ended)
	raid.ended_text = dateText(ended)
	raid.duration = formatDuration(elapsed)
	raid.player_count = numberToString(count(raid.members))
	raid.drop_count = numberToString(#raid.drops)

	local name = RAIDS_DIR .. fileDate(started)
	local path = name .. ".dat"
	local raw = raid.raw_events
	raid.raw_events = nil
	api.File:Write(path, raid)
	if DEBUG then
		raid.raw_events = raw or {}
		api.File:Write(name .. ".raw", raid)
	end
	local totals = { players = raid.player_count, drops = raid.drop_count, duration = raid.duration }
	raid = nil
	saveCurrent()
	return path, totals
end

-- Text for the button's tooltip.
function raidlog.StatusText()
	if raid == nil then
		return "Raid drops: not recording\nClick to start a new raid"
	end
	local text = "Raid drops: recording\nStarted " .. tostring(raid.started_text)
		.. " (" .. formatDuration(elapsedSeconds()) .. " ago)"
	text = text .. "\nPlayers: " .. count(raid.members) .. ", drops: " .. #raid.drops
	local last = raid.drops[#raid.drops]
	if last ~= nil then
		text = text .. "\nLast: " .. last.player .. " looted " .. last.item
			.. (last.count ~= "1" and (" x" .. last.count) or "")
	end
	return text .. "\nClick to stop and save"
end

return raidlog
