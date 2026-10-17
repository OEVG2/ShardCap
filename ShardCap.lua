--[[ ShardCap 2.0 -- keep your Soul Shards at a fixed cap.
     WoW 1.12.1 (Lua 5.0). Based on ShardCap by "The Johnnest of them all" (dogmax),
     with ideas from ShardCapPlus (akzkak/Paduk) and voxan-dev's fork.

     Optional client-mod support (auto-detected, never required):
       ClassicAPI  - exact item IDs/stack counts, locale-free soul bag detection,
                     cursor-free item moves, BAG_UPDATE_DELAYED batching
       Nampower    - exact item IDs/stack counts via GetBagItem
]]

local ADDON   = "ShardCap"
local VERSION = "2.0.0"
local SHARD_ID = 6265

-- Known soul bags (vanilla): Soul Pouch, Felcloth Bag, Core Felcloth Bag,
-- Small Soul Pouch, Box of Souls. Anything else is caught by the subtype check
-- or ClassicAPI; /shardcap soulbag <n> covers whatever slips through.
local SOULBAG_IDS = { [21340]=true, [21341]=true, [21342]=true, [22243]=true, [22244]=true }
local SOULBAG_SUBTYPES = { ["Soul Bag"]=true, ["Seelentasche"]=true }

local DEFAULTS = {
	cap      = 12,     -- shards to keep
	notify   = false,  -- chat output when something is deleted/moved
	sort     = true,   -- move shards from normal bags into free soul bag slots
	combat   = false,  -- also trim while in combat
	soulbags = nil,    -- nil = auto-detect, otherwise { [bagID]=true }
}

local db
local inCombat = false
local api = {}

------------------------------------------------------------------------------
-- Output
------------------------------------------------------------------------------
local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff9482c9ShardCap|r - " .. msg)
end

local function Notify(msg)
	if db and db.notify then Print(msg) end
end

local function Plural(n, word)
	if n == 1 then return n .. " " .. word end
	return n .. " " .. word .. "s"
end

------------------------------------------------------------------------------
-- Client-mod detection
------------------------------------------------------------------------------
local function DetectAPIs()
	api.classic = type(C_Container) == "table"
		and type(C_Container.GetContainerItemInfo) == "function"
	api.classicSwap = api.classic and type(C_Container.SwapItems) == "function"
	api.classicBagType = api.classic and type(C_Container.GetContainerNumFreeSlots) == "function"
	api.nampower = (not api.classic) and type(GetBagItem) == "function"
	api.superwow = SUPERWOW_VERSION ~= nil
	api.unitxp = type(UnitXP) == "function" and pcall(UnitXP, "nop", "nop") or false
end

------------------------------------------------------------------------------
-- Slot reading: returns itemID, stackCount, locked (or nil for empty)
------------------------------------------------------------------------------
local function SlotInfoVanilla(bag, slot)
	local link = GetContainerItemLink(bag, slot)
	if not link then return nil end
	-- Exact ID match. The original string.find(link, 6265) also matched any
	-- item whose link merely contained "6265" (e.g. item 16265) and deleted it.
	local _, _, id = string.find(link, "item:(%d+)")
	local _, count, locked = GetContainerItemInfo(bag, slot)
	return tonumber(id), count or 1, locked
end

local function SlotInfo(bag, slot)
	if api.classic then
		local info = C_Container.GetContainerItemInfo(bag, slot)
		if not info then return nil end
		return info.itemID, info.stackCount or 1, info.isLocked
	elseif api.nampower then
		local ok, t = pcall(GetBagItem, bag, slot)
		if not ok then
			api.nampower = false -- unexpected API shape; fall back for good
			return SlotInfoVanilla(bag, slot)
		end
		if not t then return nil end
		local _, _, locked = GetContainerItemInfo(bag, slot)
		return t.itemId, t.stackCount or 1, locked
	end
	return SlotInfoVanilla(bag, slot)
end

------------------------------------------------------------------------------
-- Soul bag detection
------------------------------------------------------------------------------
local function IsBit4Set(n) -- Lua 5.0 has no bit ops in every client
	return math.mod(math.floor(n / 4), 2) == 1
end

local function AutoIsSoulBag(bag)
	if bag == 0 then return false end
	if api.classicBagType then
		local _, bagType = C_Container.GetContainerNumFreeSlots(bag)
		if bagType and bagType > 0 then return IsBit4Set(bagType) end
	end
	local link = GetInventoryItemLink("player", ContainerIDToInventoryID(bag))
	if not link then return false end
	local _, _, id = string.find(link, "item:(%d+)")
	id = tonumber(id)
	if not id then return false end
	if SOULBAG_IDS[id] then return true end
	local _, _, _, _, _, subType = GetItemInfo(id)
	return subType ~= nil and SOULBAG_SUBTYPES[subType] == true
end

local function IsSoulBag(bag)
	if db.soulbags then return db.soulbags[bag] == true end
	return AutoIsSoulBag(bag)
end

------------------------------------------------------------------------------
-- Inventory scan
------------------------------------------------------------------------------
local function Scan()
	local stacks, freeSoul, total = {}, {}, 0
	for bag = 0, 4 do
		local soul = IsSoulBag(bag)
		for slot = 1, GetContainerNumSlots(bag) do
			local id, count, locked = SlotInfo(bag, slot)
			if id == SHARD_ID then
				table.insert(stacks, { bag = bag, slot = slot, count = count, locked = locked, soul = soul })
				total = total + count
			elseif not id and soul then
				table.insert(freeSoul, { bag = bag, slot = slot })
			end
		end
	end
	return stacks, freeSoul, total
end

-- Deletion order: shards outside soul bags first, backpack first,
-- and from the end of each bag; soul bag shards go last.
local function DeleteOrder(a, b)
	if a.soul ~= b.soul then return not a.soul end
	if a.bag ~= b.bag then return a.bag < b.bag end
	return a.slot > b.slot
end

------------------------------------------------------------------------------
-- Actions (one per pass; the next pass runs after the server answers)
------------------------------------------------------------------------------
local function CursorBusy()
	return CursorHasItem() or (SpellIsTargeting and SpellIsTargeting())
end

-- returns true if it did something
local function TrimStep(stacks, total)
	local excess = total - db.cap
	if excess <= 0 then return false end
	table.sort(stacks, DeleteOrder)
	for _, s in ipairs(stacks) do
		if not s.locked then
			local n = s.count
			if n > excess then n = excess end
			if n < s.count then
				SplitContainerItem(s.bag, s.slot, n) -- delete exactly the excess
			else
				PickupContainerItem(s.bag, s.slot)
			end
			if CursorHasItem() then
				DeleteCursorItem()
				Notify("Deleted " .. Plural(n, "Soul Shard") .. " from bag " .. s.bag
					.. " slot " .. s.slot .. " (" .. total .. " -> " .. (total - n) .. ", cap " .. db.cap .. ").")
				return true
			end
			return false
		end
	end
	return false
end

-- Max shards per slot: 3 on WoW 1.18.1 Clients, 1 on Blizzlike servers.
local function MaxStack()
	if api.classic and C_Item and type(C_Item.GetItemMaxStackSizeByID) == "function" then
		local ok, n = pcall(C_Item.GetItemMaxStackSizeByID, SHARD_ID)
		if ok and type(n) == "number" and n > 0 then return n end
	end
	local _, _, _, _, _, _, n = GetItemInfo(SHARD_ID)
	if type(n) == "number" and n > 0 then return n end
	return 1
end

-- Move exactly n shards from src onto dst (dst empty or a partial shard stack).
local function MoveShards(src, dst, n)
	if api.classic and type(C_Container.MoveItem) == "function" then
		C_Container.MoveItem(src.bag, src.slot, dst.bag, dst.slot, n)
		return
	end
	if n < src.count then
		SplitContainerItem(src.bag, src.slot, n)
	else
		PickupContainerItem(src.bag, src.slot)
	end
	PickupContainerItem(dst.bag, dst.slot)
	if CursorHasItem() then PickupContainerItem(src.bag, src.slot) end -- put it back
end

-- WoW 1.18.1 Clients: merge partial stacks so shards take as few slots as possible.
-- Fills the most-preferred partial stack (soul bag first) from the least-preferred one.
local function MergeStep(stacks, maxStack)
	if maxStack <= 1 then return false end
	local partial = {}
	for _, s in ipairs(stacks) do
		if s.count < maxStack and not s.locked then table.insert(partial, s) end
	end
	if table.getn(partial) < 2 then return false end
	table.sort(partial, DeleteOrder) -- first = least preferred, last = most preferred
	local src, dst = partial[1], partial[table.getn(partial)]
	local n = maxStack - dst.count
	if n > src.count then n = src.count end
	MoveShards(src, dst, n)
	Notify("Merged " .. Plural(n, "Soul Shard") .. " into bag " .. dst.bag .. " slot " .. dst.slot .. ".")
	return true
end

local function SortStep(stacks, freeSoul)
	if not db.sort then return false end
	if MergeStep(stacks, MaxStack()) then return true end
	if table.getn(freeSoul) == 0 then return false end
	for _, s in ipairs(stacks) do
		if not s.soul and not s.locked then
			local dst = freeSoul[1]
			if api.classicSwap then
				C_Container.SwapItems(s.bag, s.slot, dst.bag, dst.slot)
			else
				MoveShards(s, dst, s.count)
			end
			Notify("Moved " .. Plural(s.count, "Soul Shard") .. " into your soul bag (bag " .. dst.bag .. ").")
			return true
		end
	end
	return false
end

------------------------------------------------------------------------------
-- Scheduler (hidden OnUpdate frame: zero cost while idle)
------------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local nextRun, forced, passes = nil, false, 0
local MAX_PASSES = 60

local function Schedule(delay, force)
	local t = GetTime() + (delay or 0.3)
	if not nextRun or t < nextRun then nextRun = t end
	if force then forced = true end
	passes = 0
	frame:Show()
end

local function Pass()
	if not db then return false end
	local manual = forced
	if (inCombat or UnitAffectingCombat("player")) and not db.combat and not manual then
		return false -- PLAYER_REGEN_ENABLED will reschedule
	end
	if CursorBusy() then return true end -- try again shortly
	local stacks, freeSoul, total = Scan()
	if TrimStep(stacks, total) then return true end
	-- don't shuffle bags mid-combat even if combat trimming is on
	if not (inCombat or UnitAffectingCombat("player")) and SortStep(stacks, freeSoul) then return true end
	-- retry while stacks are still locked by a pending server transaction
	for _, s in ipairs(stacks) do if s.locked then return true end end
	return false
end

frame:Hide()
frame:SetScript("OnUpdate", function()
	if not nextRun or GetTime() < nextRun then return end
	nextRun = nil
	passes = passes + 1
	local again = Pass()
	if again and passes < MAX_PASSES then
		nextRun = GetTime() + 0.3
	else
		forced = false
		this:Hide()
	end
end)

------------------------------------------------------------------------------
-- Saved variables & migration
------------------------------------------------------------------------------
local function InitDB()
	if type(ShardCapDB) ~= "table" then
		ShardCapDB = {}
		-- migrate settings from ShardCap 1.x
		if type(SHARDCAP_CAP_VALUE) == "number" then ShardCapDB.cap = SHARDCAP_CAP_VALUE end
		if SHARDCAP_SPAM == true then ShardCapDB.notify = true end
	end
	SHARDCAP_CAP_VALUE, SHARDCAP_SPAM = nil, nil
	db = ShardCapDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end
end

local function WarnDuplicates()
	if IsAddOnLoaded("ShardCapPlus") then
		Print("|cffff5555ShardCapPlus is also enabled.|r Disable it - both would delete shards.")
	end
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

frame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		InitDB()
		DetectAPIs()
		-- ClassicAPI batches all BAG_UPDATEs of a frame into one event
		if api.classic then
			frame:RegisterEvent("BAG_UPDATE_DELAYED")
		else
			frame:RegisterEvent("BAG_UPDATE")
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		inCombat = UnitAffectingCombat("player") and true or false
		WarnDuplicates()
		Schedule(2)
	elseif event == "PLAYER_REGEN_DISABLED" then
		inCombat = true
	elseif event == "PLAYER_REGEN_ENABLED" then
		inCombat = false
		Schedule(0.5)
	elseif event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED" then
		if not inCombat or db.combat then Schedule(0.3) end
	end
end)

------------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------------
local function OnOff(v) if v then return "|cff55ff55on|r" end return "|cffff5555off|r" end

local function SoulBagList()
	local list = {}
	for bag = 1, 4 do if IsSoulBag(bag) then table.insert(list, bag) end end
	if table.getn(list) == 0 then return "none" end
	return table.concat(list, ", ")
end

local function Backend()
	local parts = {}
	if api.classic then table.insert(parts, "ClassicAPI")
	elseif api.nampower then table.insert(parts, "Nampower")
	else table.insert(parts, "vanilla API") end
	return table.concat(parts, ", ")
end

local function PrintStatus()
	local _, freeSoul, total = Scan()
	Print("Cap: |cffffffff" .. db.cap .. "|r  Carrying: |cffffffff" .. total .. "|r  (v" .. VERSION .. ")")
	Print("Soul bags: " .. SoulBagList() .. (db.soulbags and " (manual)" or " (auto)")
		.. ", " .. table.getn(freeSoul) .. " free soul slots")
	Print("Notify " .. OnOff(db.notify) .. ", sort " .. OnOff(db.sort)
		.. ", trim in combat " .. OnOff(db.combat) .. "  [" .. Backend() .. "]")
end

local function PrintHelp()
	Print("/shardcap |cffffffff<number>|r - set the cap (0-200)")
	Print("/shardcap |cffffffffstatus|r - show cap, shard count and settings")
	Print("/shardcap |cffffffffdelete|r - trim to the cap right now (even in combat)")
	Print("/shardcap |cffffffffspam|r - toggle chat notifications")
	Print("/shardcap |cffffffffsort|r - toggle moving shards into your soul bag")
	Print("/shardcap |cffffffffcombat|r - toggle trimming during combat")
	Print("/shardcap |cffffffffsoulbag auto|1-4|r - auto-detect or toggle a bag as soul bag")
	Print("/shardcap |cffffffffreset|r - restore defaults")
	Print("Trims when you leave combat, deleting shards outside your soul bag first.")
end

local function SetSoulBag(arg)
	if arg == "auto" or arg == "" then
		db.soulbags = nil
		Print("Soul bag detection: auto (" .. SoulBagList() .. ").")
		return
	end
	local bag = tonumber(arg)
	if not bag or bag < 1 or bag > 4 or bag ~= math.floor(bag) then
		Print("Use a bag number 1-4, or 'auto'.")
		return
	end
	if not db.soulbags then
		db.soulbags = {}
		for b = 1, 4 do if AutoIsSoulBag(b) then db.soulbags[b] = true end end
	end
	if db.soulbags[bag] then db.soulbags[bag] = nil else db.soulbags[bag] = true end
	Print("Soul bags (manual): " .. SoulBagList() .. ". '/shardcap soulbag auto' to undo.")
	Schedule(0.3)
end

SLASH_SHARDCAP1 = "/shardcap"
SLASH_SHARDCAP2 = "/scap"
SlashCmdList["SHARDCAP"] = function(msg)
	if not db then return end
	msg = string.lower(msg or "")
	local _, _, cmd, rest = string.find(msg, "^%s*(%S*)%s*(.-)%s*$")
	cmd, rest = cmd or "", rest or ""

	local n = tonumber(cmd)
	if n then
		if n < 0 or n > 200 or n ~= math.floor(n) then
			Print("The cap must be a whole number from 0 to 200.")
			return
		end
		db.cap = n
		Print("Cap set to " .. Plural(n, "shard") .. ".")
		Schedule(0.3)
	elseif cmd == "" or cmd == "status" then
		PrintStatus()
		if cmd == "" then Print("Type |cffffffff/shardcap help|r for commands.") end
	elseif cmd == "help" or cmd == "info" then
		PrintHelp()
	elseif cmd == "delete" or cmd == "trim" then
		Schedule(0, true)
	elseif cmd == "spam" or cmd == "notify" then
		db.notify = not db.notify
		Print("Notifications " .. OnOff(db.notify) .. ".")
	elseif cmd == "sort" then
		db.sort = not db.sort
		Print("Moving shards into soul bags " .. OnOff(db.sort) .. ".")
		Schedule(0.3)
	elseif cmd == "combat" then
		db.combat = not db.combat
		Print("Trimming during combat " .. OnOff(db.combat) .. ".")
	elseif cmd == "soulbag" then
		SetSoulBag(rest)
	elseif cmd == "reset" then
		ShardCapDB = nil
		InitDB()
		Print("Settings reset. Cap is " .. db.cap .. ".")
	else
		PrintHelp()
	end
end
