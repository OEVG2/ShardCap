-- Mock WoW 1.12 client + scenario tests for ShardCap. Run with Lua 5.0.
local ADDON_FILE = arg[1] or "ShardCap.lua"
local fails, passes = 0, 0
local function check(cond, name)
	if cond then passes = passes + 1; print("  ok   " .. name)
	else fails = fails + 1; print("  FAIL " .. name) end
end

local now, bags, bagItem, cursor, combat, frames, chat, maxStack
local itemNames = { [6265] = "Soul Shard", [16265] = "Some Other Item", [6948] = "Hearthstone" }

local function reset(opts)
	opts = opts or {}
	now, cursor, combat, frames, chat = 0, nil, false, {}, {}
	maxStack = opts.maxStack or 3
	bags, bagItem = {}, {}
	for b = 0, 4 do bags[b] = { size = 0, slots = {} } end
	ShardCapDB, SHARDCAP_CAP_VALUE, SHARDCAP_SPAM = nil, nil, nil
	C_Container, C_Item, GetBagItem, CLASSIC_API_VERSION = nil, nil, nil, nil
end
local function setBag(b, size, itemID) bags[b].size = size; bagItem[b] = itemID end
local function put(b, s, id, n) bags[b].slots[s] = { id = id, count = n or 1 } end

-- vanilla API
function GetTime() return now end
function GetContainerNumSlots(b) return bags[b] and bags[b].size or 0 end
function GetContainerItemLink(b, s)
	local it = bags[b].slots[s]; if not it then return nil end
	return "|cffffffff|Hitem:" .. it.id .. ":0:0:0|h[" .. (itemNames[it.id] or "?") .. "]|h|r"
end
function GetContainerItemInfo(b, s)
	local it = bags[b].slots[s]; if not it then return nil end
	return "tex", it.count, it.locked
end
function ContainerIDToInventoryID(b) return 19 + b end
function GetInventoryItemLink(u, inv)
	local id = bagItem[inv - 19]; if not id then return nil end
	return "|Hitem:" .. id .. ":0:0:0|h[bag]|h"
end
function GetItemInfo(id)
	id = tonumber(id)
	if id == 6265 then return "Soul Shard", "item:6265", 1, 0, "Reagent", "Reagent", maxStack end
	if id == 22243 then return "Small Soul Pouch", "item:22243", 2, 0, "Container", "Soul Bag", 1 end
	if id == 99999 then return "Custom Soul Bag", "item:99999", 2, 0, "Container", "Soul Bag", 1 end
	return "Bag", "item:" .. id, 1, 0, "Container", "Bag", 1
end
function CursorHasItem() return cursor ~= nil end
function SpellIsTargeting() return false end
function PickupContainerItem(b, s)
	local it = bags[b].slots[s]
	if cursor then
		if it and it.id == cursor.id and it.count + cursor.count <= maxStack then
			it.count = it.count + cursor.count; cursor = nil
		elseif not it then
			bags[b].slots[s] = cursor; cursor = nil
		else
			bags[b].slots[s] = cursor; cursor = it
		end
	elseif it then
		bags[b].slots[s] = nil; cursor = it
	end
end
function SplitContainerItem(b, s, n)
	local it = bags[b].slots[s]
	if cursor or not it or n >= it.count then return end
	it.count = it.count - n; cursor = { id = it.id, count = n }
end
function DeleteCursorItem() cursor = nil end
function UnitAffectingCombat() return combat end
function IsAddOnLoaded() return false end
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) table.insert(chat, m) end }
SlashCmdList = {}
function CreateFrame()
	local f = { scripts = {}, events = {}, shown = true }
	function f:RegisterEvent(e) self.events[e] = true end
	function f:SetScript(k, fn) self.scripts[k] = fn end
	function f:Show() self.shown = true end
	function f:Hide() self.shown = false end
	table.insert(frames, f)
	return f
end

local F
local function fire(e, a1)
	if not F.events[e] then return end
	event, arg1 = e, a1
	this = F; F.scripts.OnEvent()
end
local function run(seconds)
	local stop = now + (seconds or 10)
	while now < stop do
		now = now + 0.05
		if F.shown and F.scripts.OnUpdate then this = F; F.scripts.OnUpdate() end
	end
end
local function load(classic)
	if classic then
		CLASSIC_API_VERSION = 10000
		C_Container = {
			GetContainerItemInfo = function(b, s)
				local it = bags[b].slots[s]; if not it then return nil end
				return { itemID = it.id, stackCount = it.count, isLocked = it.locked and true or false }
			end,
			GetContainerNumFreeSlots = function(b)
				local id = bagItem[b]
				local t = (id == 22243 or id == 99999) and 4 or 0
				return 0, t
			end,
			SwapItems = function(sb, ss, db_, ds)
				local a, b2 = bags[sb].slots[ss], bags[db_].slots[ds]
				bags[sb].slots[ss], bags[db_].slots[ds] = b2, a; return true
			end,
			MoveItem = function(sb, ss, db_, ds, n)
				local src, dst = bags[sb].slots[ss], bags[db_].slots[ds]
				if not src or n > src.count then return false end
				if dst and (dst.id ~= src.id or dst.count + n > maxStack) then return false end
				if dst then dst.count = dst.count + n else bags[db_].slots[ds] = { id = src.id, count = n } end
				src.count = src.count - n; if src.count == 0 then bags[sb].slots[ss] = nil end
				return true
			end,
		}
		C_Item = { GetItemMaxStackSizeByID = function(id) return maxStack end }
	end
	dofile(ADDON_FILE)
	F = frames[1]
	fire("ADDON_LOADED", "ShardCap")
	fire("PLAYER_ENTERING_WORLD")
end
local function count(onlyBag)
	local t = 0
	for b = 0, 4 do
		if not onlyBag or onlyBag == b then
			for s = 1, bags[b].size do
				local it = bags[b].slots[s]
				if it and it.id == 6265 then t = t + it.count end
			end
		end
	end
	return t
end
local function slotsUsed()
	local t = 0
	for b = 0, 4 do for s = 1, bags[b].size do
		local it = bags[b].slots[s]; if it and it.id == 6265 then t = t + 1 end
	end end
	return t
end

for _, classic in ipairs({ false, true }) do
	local tag = classic and "[ClassicAPI] " or "[vanilla] "
	print(tag)

	-- 1. WoW 1.18.1 Clients stacks of 3: trims to exactly the cap, backpack first
	reset(); setBag(0, 16); setBag(4, 12, 22243)
	put(0, 2, 6265, 3); put(4, 1, 6265, 3); put(4, 2, 6265, 3); put(4, 3, 6265, 2)
	load(classic); ShardCapDB.cap = 6; ShardCapDB.sort = false; fire("BAG_UPDATE"); fire("BAG_UPDATE_DELAYED"); run()
	check(count() == 6, tag .. "trim 11 -> 6 with stacks of 3 (got " .. count() .. ")")
	check(count(0) == 0, tag .. "deleted from backpack before soul bag")
	check(cursor == nil, tag .. "cursor left empty")

	-- 2. Exactness: 13 shards, cap 12 -> deletes exactly 1 (ShardCapPlus deleted a whole stack of 3)
	reset(); setBag(0, 16); setBag(4, 12, 22243)
	put(0, 1, 6265, 1); for s = 1, 4 do put(4, s, 6265, 3) end
	load(classic); ShardCapDB.cap = 12; fire("BAG_UPDATE"); fire("BAG_UPDATE_DELAYED"); run()
	check(count() == 12, tag .. "13 -> exactly 12 (got " .. count() .. ")")

	reset(); setBag(0, 16); setBag(4, 12, 22243)
	put(0, 1, 6265, 3); for s = 1, 4 do put(4, s, 6265, 3) end
	load(classic); ShardCapDB.cap = 13; ShardCapDB.sort = false; fire("BAG_UPDATE"); fire("BAG_UPDATE_DELAYED"); run()
	check(count() == 13 and count(0) == 1, tag .. "15 -> 13 splits the backpack stack (got " .. count() .. ")")

	-- 3. No false positives: item 16265 is never touched
	reset(); setBag(0, 16)
	put(0, 1, 16265, 1); put(0, 2, 6265, 1); put(0, 3, 6265, 1)
	load(classic); ShardCapDB.cap = 1; fire("BAG_UPDATE"); fire("BAG_UPDATE_DELAYED"); run()
	check(bags[0].slots[1] and bags[0].slots[1].id == 16265, tag .. "item 16265 kept")
	check(count() == 1, tag .. "shards trimmed to 1")

	-- 4. Merge partial stacks into the soul bag stack
	reset(); setBag(0, 16); setBag(4, 12, 22243)
	put(0, 5, 6265, 1); put(4, 1, 6265, 2); put(4, 2, 6265, 1)
	load(classic); ShardCapDB.cap = 20; fire("BAG_UPDATE"); fire("BAG_UPDATE_DELAYED"); run()
	check(count() == 4, tag .. "merge keeps all 4 shards")
	check(slotsUsed() == 2, tag .. "4 shards in 2 slots after merging (got " .. slotsUsed() .. ")")
	check(count(0) == 0, tag .. "backpack emptied into soul bag")

	-- 5. Blizzlike (no stacking): move shards into free soul bag slots
	reset({ maxStack = 1 }); setBag(0, 16); setBag(2, 16, 22243)
	put(0, 1, 6265); put(0, 2, 6265); put(2, 1, 6265)
	load(classic); ShardCapDB.cap = 20; fire("BAG_UPDATE"); fire("BAG_UPDATE_DELAYED"); run()
	check(count(2) == 3 and count(0) == 0, tag .. "shards moved into soul bag in bag 2")

	-- 6. Combat: nothing deleted in combat, trimmed on leaving it
	reset(); setBag(0, 16)
	for s = 1, 5 do put(0, s, 6265, 1) end
	load(classic); run(); ShardCapDB.cap = 2
	combat = true; fire("PLAYER_REGEN_DISABLED"); put(0, 6, 6265, 1); fire("BAG_UPDATE"); fire("BAG_UPDATE_DELAYED"); run()
	check(count() == 6, tag .. "no deletion during combat")
	combat = false; fire("PLAYER_REGEN_ENABLED"); run()
	check(count() == 2, tag .. "trimmed after combat (got " .. count() .. ")")

	-- 7. Manual /shardcap delete works in combat
	reset(); setBag(0, 16); for s = 1, 4 do put(0, s, 6265, 1) end
	load(classic); combat = true; fire("PLAYER_REGEN_DISABLED"); ShardCapDB.cap = 1
	SlashCmdList.SHARDCAP("delete"); run()
	check(count() == 1, tag .. "manual delete in combat")

	-- 8. Holding an item on the cursor blocks deletion
	reset(); setBag(0, 16); for s = 1, 4 do put(0, s, 6265, 1) end
	cursor = { id = 6948, count = 1 }
	load(classic); ShardCapDB.cap = 1; fire("BAG_UPDATE"); fire("BAG_UPDATE_DELAYED"); run(2)
	check(count() == 4 and cursor.id == 6948, tag .. "waits while the cursor holds an item")
	cursor = nil; run()
	check(count() == 1, tag .. "proceeds once the cursor is free")

	-- 9. Locked stack is skipped until unlocked
	reset(); setBag(0, 16); put(0, 1, 6265, 1); put(0, 2, 6265, 1)
	bags[0].slots[2].locked = true; bags[0].slots[1].locked = true
	load(classic); ShardCapDB.cap = 0; fire("BAG_UPDATE"); fire("BAG_UPDATE_DELAYED"); run(1)
	check(count() == 2, tag .. "locked stacks untouched")
	bags[0].slots[2].locked = nil; bags[0].slots[1].locked = nil; run()
	check(count() == 0, tag .. "deleted after unlock")
end

-- 10. Migration from ShardCap 1.x and slash parsing
print("[misc]")
reset(); setBag(0, 16)
dofile(ADDON_FILE); F = frames[1]
SHARDCAP_CAP_VALUE, SHARDCAP_SPAM = 7, true
fire("ADDON_LOADED", "ShardCap")
check(ShardCapDB.cap == 7 and ShardCapDB.notify == true, "migrated 1.x cap and spam setting")
check(SHARDCAP_CAP_VALUE == nil, "old globals cleared")
SlashCmdList.SHARDCAP("-3"); check(ShardCapDB.cap == 7, "negative cap rejected")
SlashCmdList.SHARDCAP("2.5"); check(ShardCapDB.cap == 7, "fractional cap rejected")
SlashCmdList.SHARDCAP("  15 "); check(ShardCapDB.cap == 15, "cap set with whitespace")
SlashCmdList.SHARDCAP("soulbag 3"); check(ShardCapDB.soulbags and ShardCapDB.soulbags[3], "manual soul bag")
SlashCmdList.SHARDCAP("soulbag auto"); check(ShardCapDB.soulbags == nil, "back to auto")
SlashCmdList.SHARDCAP("status"); SlashCmdList.SHARDCAP("help")
check(table.getn(chat) > 5, "status/help print")

-- 11. Unknown custom soul bag found through its "Soul Bag" subtype
reset(); setBag(0, 16); setBag(3, 20, 99999); put(0, 1, 6265, 1)
load(false); ShardCapDB.cap = 10; fire("BAG_UPDATE"); run()
check(count(3) == 1, "soul bag detected by subtype")

print(string.format("\n%d passed, %d failed", passes, fails))
if fails > 0 then os.exit(1) end
