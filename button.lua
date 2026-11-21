local api = require("api")

-- A row of start/stop buttons in one draggable window, one per recorder:
--   raid      red record (record.png) / green save (save.png)
--   instance  party (party.png) / party with a floppy (party_save.png)
-- The first image shows while not recording (click to start), the second while recording
-- (click to stop and save). Hover for the run so far, drag any of them to move them all.
local button = {}

local IMAGE_DIR = api.baseDir .. "/RaidsDB/images/"
local POSITION_PATH = "RaidsDB/ui.dat"
local DOT_SIZE = 24
local BUTTON_GAP = 4
local DEFAULT_X = 420
local DEFAULT_Y = 440
local TOOLTIP_REFRESH_MS = 1000

local window = nil
-- id -> { image, idle, recording }
local slots = {}
-- bumped on every hover change; a refresh loop from an earlier hover sees a newer id and stops
local hoverId = 0

local function loadPosition()
	local saved = api.File:Read(POSITION_PATH)
	if type(saved) == "table" then
		local x, y = tonumber(saved.x), tonumber(saved.y)
		if x ~= nil and y ~= nil then
			return x, y
		end
	end
	return DEFAULT_X, DEFAULT_Y
end

local function savePosition()
	local x, y = window:GetEffectiveOffset()
	if x == nil or y == nil then
		return
	end
	api.File:Write(POSITION_PATH, {
		x = string.format("%.0f", x),
		y = string.format("%.0f", y),
	})
end

local function tooltipText(statusFn)
	if statusFn == nil then
		return "Raid drops"
	end
	local ok, text = pcall(statusFn)
	if ok and type(text) == "string" then
		return text
	end
	return "Raid drops"
end

local function showTooltip(widget, statusFn)
	local x, y = widget:GetEffectiveOffset()
	-- clear first so the client redraws the text instead of keeping the old tooltip
	api.Interface:SetTooltipOnPos("", widget, 0, 0)
	api.Interface:SetTooltipOnPos(tooltipText(statusFn), widget, x + widget:GetWidth(), y)
end

-- keeps the counts and times current while the mouse stays on the button
local function refreshTooltip(widget, statusFn, id)
	api:DoIn(TOOLTIP_REFRESH_MS, function()
		if id ~= hoverId or window == nil then
			return -- mouse left or unloaded
		end
		pcall(showTooltip, widget, statusFn)
		refreshTooltip(widget, statusFn, id)
	end)
end

local function attachDrag(widget)
	function widget:OnDragStart()
		window:StartMoving()
		api.Cursor:ClearCursor()
		api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
	end
	widget:SetHandler("OnDragStart", widget.OnDragStart)
	function widget:OnDragStop()
		window:StopMovingOrSizing()
		api.Cursor:ClearCursor()
		savePosition()
	end
	widget:SetHandler("OnDragStop", widget.OnDragStop)
	if widget.RegisterForDrag ~= nil then
		widget:RegisterForDrag("LeftButton")
	end
	widget:EnableDrag(true)
end

-- image plus an invisible button over it, for the hover tooltip and click to start/stop
local function createSlot(index, spec)
	local offsetX = (index - 1) * (DOT_SIZE + BUTTON_GAP)
	local image = window:CreateImageDrawable("RaidsDBButtonImage_" .. spec.id, "artwork")
	image:AddAnchor("TOPLEFT", window, offsetX, 0)
	image:SetExtent(DOT_SIZE, DOT_SIZE)
	image:SetTexture(IMAGE_DIR .. spec.idle)
	image:Show(true)

	local hover = window:CreateChildWidget("button", "RaidsDBButtonHover_" .. spec.id, 0, true)
	hover:AddAnchor("TOPLEFT", window, offsetX, 0)
	hover:SetExtent(DOT_SIZE, DOT_SIZE)
	function hover:OnEnter()
		hoverId = hoverId + 1
		showTooltip(hover, spec.status)
		refreshTooltip(hover, spec.status, hoverId)
	end
	hover:SetHandler("OnEnter", hover.OnEnter)
	function hover:OnLeave()
		hoverId = hoverId + 1
		api.Interface:SetTooltipOnPos("", hover, 0, 0)
	end
	hover:SetHandler("OnLeave", hover.OnLeave)
	function hover:OnClick()
		if spec.onClick ~= nil then
			spec.onClick()
		end
		pcall(showTooltip, hover, spec.status)
	end
	hover:SetHandler("OnClick", hover.OnClick)
	attachDrag(hover)
	hover:Show(true)

	slots[spec.id] = { image = image, idle = spec.idle, recording = spec.recording }
end

-- specs is a list, left to right, of
--   { id, idle = "<image>", recording = "<image>", onClick = fn, status = fn -> tooltip text }
function button.Create(specs)
	if window ~= nil then
		return
	end
	local x, y = loadPosition()
	window = api.Interface:CreateEmptyWindow("RaidsDBButton")
	window:AddAnchor("TOPLEFT", "UIParent", x, y)
	window:SetExtent(#specs * DOT_SIZE + (#specs - 1) * BUTTON_GAP, DOT_SIZE)
	window:SetCloseOnEscape(false)
	for index, spec in ipairs(specs) do
		createSlot(index, spec)
	end
	attachDrag(window)
	window:Show(true)
end

function button.SetRecording(id, recording)
	local slot = slots[id]
	if slot ~= nil then
		slot.image:SetTexture(IMAGE_DIR .. (recording and slot.recording or slot.idle))
	end
end

function button.Free()
	if window == nil then
		return
	end
	api.Interface:Free(window)
	window = nil
	slots = {}
end

return button
