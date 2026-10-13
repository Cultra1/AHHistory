-- AH History: adds a "History" tab to the Auction House
local ADDON_NAME, ns = ...

local DEFAULT_MAX_ENTRIES = 5000
local ALL          = "__ALL__"
local ROW_HEIGHT   = 22
local HISTORY_MODE = { "AHHistoryFrame" }   -- custom display mode for the AH

local db, playerKey, ui
local debugMode = false
local lastItemKey                 -- last opened item in the Buy tab
local pendingItem                 -- buyout in progress (non-commodity)
local pendingCommodity            -- commodity purchase in progress
local pendingClear                -- what the confirmation dialog should clear
local requested = {}              -- items whose data has already been requested
local inOwnTooltip = false        -- prevents duplicate lines in our list tooltip
local settingsCategory
local ApplyDefaultCharFilter      -- defined further below
local catFilter = {}              -- { classID, subClassID } of the selected category
local timeFilter                  -- time range in days, nil = all
local classCache = {}             -- itemID -> { classID, subClassID }
local unknownEvents = {}

local function Print(...) print("|cffffcc00AH History:|r", ...) end
local function Debug(...) if debugMode then Print(...) end end

---------------------------------------------------------------------------
-- Data
--   db.entries[key]: visible list, limited by the "Maximum list entries" option
--   db.stats[key]:   counters (purchases + quantity), never pruned or deleted
---------------------------------------------------------------------------

-- Duplicate key: same item = same itemID (pets: same species)
local function EntryKey(itemID, link)
    local species = link and link:match("|Hbattlepet:(%d+)")
    if species then return "pet:" .. species end
    return "item:" .. itemID
end

-- Returns the keys above the limit (the oldest ones), or nil
local function GetOverflowKeys()
    local limit = db.options.maxEntries or DEFAULT_MAX_ENTRIES
    local keys = {}
    for k in pairs(db.entries) do keys[#keys + 1] = k end
    if #keys <= limit then return nil end
    table.sort(keys, function(a, b)
        return (db.entries[a].lastTime or 0) < (db.entries[b].lastTime or 0)
    end)
    local overflow = {}
    for i = 1, #keys - limit do overflow[keys[i]] = true end
    return overflow
end

-- Permanently remove entries above the limit. Only runs on logout,
-- so a slider accidentally set too low can still be corrected.
-- The counters in db.stats are always kept.
local function Prune()
    local overflow = GetOverflowKeys()
    if not overflow then return end
    for k in pairs(overflow) do db.entries[k] = nil end
end

local function RecordPurchase(itemID, link, qty, total)
    if not itemID or not playerKey then return end
    qty = (qty and qty > 0) and qty or 1
    local now  = time()
    local unit = total and math.floor(total / qty) or nil
    local key  = EntryKey(itemID, link)

    -- List entry
    local e = db.entries[key]
    if not e then
        e = { itemID = itemID, chars = {} }
        db.entries[key] = e
    end
    if link then e.link = link end
    e.lastTime, e.lastQty, e.lastUnit, e.lastChar = now, qty, unit, playerKey
    local c = e.chars[playerKey] or {}
    c.lastTime, c.lastQty, c.lastUnit = now, qty, unit
    e.chars[playerKey] = c

    -- Counters
    local s = db.stats[key] or { count = 0, qty = 0, chars = {} }
    s.count, s.qty = s.count + 1, s.qty + qty
    local sc = s.chars[playerKey] or { count = 0, qty = 0 }
    sc.count, sc.qty = sc.count + 1, sc.qty + qty
    s.chars[playerKey] = sc
    db.stats[key] = s

    Debug("Saved:", link or itemID, "x" .. qty)
    if ns.Refresh then ns.Refresh() end
end

-- Recalculate an entry's last purchase from the remaining characters
local function RecalcEntry(e)
    local best, bestChar
    for charKey, c in pairs(e.chars) do
        if not best or (c.lastTime or 0) > (best.lastTime or 0) then
            best, bestChar = c, charKey
        end
    end
    if best then
        e.lastTime, e.lastQty, e.lastUnit, e.lastChar = best.lastTime, best.lastQty, best.lastUnit, bestChar
    end
end

-- Clearing only affects the list, the counters in db.stats are always kept

-- Remove an item from the list completely
local function RemoveItem(key)
    db.entries[key] = nil
end

-- Remove an item from the list for one character only
local function RemoveItemForChar(key, charKey)
    local e = db.entries[key]
    if not e then return end
    e.chars[charKey] = nil
    if next(e.chars) then RecalcEntry(e) else db.entries[key] = nil end
end

local function ClearAll()
    wipe(db.entries)
end

local function ClearChar(charKey)
    local keys = {}
    for k in pairs(db.entries) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do RemoveItemForChar(k, charKey) end
end

---------------------------------------------------------------------------
-- Purchase tracking
---------------------------------------------------------------------------

-- Buyouts of non-commodities go through PlaceBid(auctionID, buyout)
hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID, bidAmount)
    pendingItem = nil
    if not lastItemKey then return end
    local n = C_AuctionHouse.GetNumItemSearchResults(lastItemKey) or 0
    for i = 1, n do
        local info = C_AuctionHouse.GetItemSearchResultInfo(lastItemKey, i)
        if info and info.auctionID == auctionID then
            -- only real buyouts, ignore normal bids
            if info.buyoutAmount and bidAmount and bidAmount >= info.buyoutAmount then
                pendingItem = {
                    auctionID = auctionID,
                    itemID    = info.itemKey and info.itemKey.itemID,
                    link      = info.itemLink,
                    qty       = info.quantity,
                    total     = info.buyoutAmount,
                }
                Debug("Purchase started:", info.itemLink)
            end
            return
        end
    end
end)

hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function(itemID, qty)
    pendingCommodity = { itemID = itemID, qty = qty }
end)

hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, qty)
    pendingCommodity = pendingCommodity or {}
    pendingCommodity.itemID    = itemID
    pendingCommodity.qty       = qty
    pendingCommodity.confirmed = true
    Debug("Commodity purchase confirmed:", itemID, qty)
end)

local function FinishCommodity(itemID, qty)
    local p = pendingCommodity
    if not p or not p.confirmed then return end
    pendingCommodity = nil
    itemID = itemID or p.itemID
    qty    = qty or p.qty
    local link = select(2, C_Item.GetItemInfo(itemID))
    RecordPurchase(itemID, link, qty, p.total)
end

---------------------------------------------------------------------------
-- UI helpers
---------------------------------------------------------------------------

local function GetCharLabel(charKey)
    if not charKey then return "" end
    local name, realm = charKey:match("^(.-)%-(.*)$")
    local label = (realm == GetNormalizedRealmName()) and name or charKey
    local class = db.chars[charKey]
    local color = class and C_ClassColor.GetClassColor(class)
    return color and color:WrapTextInColorCode(label) or label
end

local function GetItemDisplay(key, e)
    local link = e.link
    if not link then
        link = select(2, C_Item.GetItemInfo(e.itemID))
        if link then
            e.link = link
        elseif not requested[key] then
            requested[key] = true
            Item:CreateFromItemID(e.itemID):ContinueOnItemLoad(function() ns.Refresh() end)
        end
    end

    local icon
    local species = link and link:match("|Hbattlepet:(%d+)")
    if species then
        icon = select(2, C_PetJournal.GetPetInfoBySpeciesID(tonumber(species)))
    else
        icon = C_Item.GetItemIconByID(e.itemID)
    end

    local text = link and (link:gsub("[%[%]]", "")) or ("Item #" .. e.itemID)
    return text, icon, link
end

local function SearchInAH(name)
    local ah = AuctionHouseFrame
    if not name or not ah then return end
    ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
    local bar = ah.SearchBar
    if bar and bar.SetSearchText and bar.StartSearch then
        bar:SetSearchText(name)
        bar:StartSearch()
    end
end

-- Equipment opened in the buy view at a specific item level. If that level has
-- no listings, we switch to a name search that shows all available versions.
local pendingBuyView   -- { itemID, level, name, expires }
local openedFromHistory = false   -- buy view was opened from the History tab

-- Open an item directly in Blizzard's buy view, the same way as clicking a
-- search result. Returns false if that is not possible, the caller then falls
-- back to a name search.
local function OpenBuyView(e, name)
    local ah = AuctionHouseFrame
    if not (ah and ah.SelectBrowseResult and C_AuctionHouse.MakeItemKey) then
        Debug("Buy view not available in this client version, searching by name")
        return false
    end

    local itemKey
    local species = e.link and e.link:match("|Hbattlepet:(%d+)")
    if species then
        itemKey = C_AuctionHouse.MakeItemKey(82800, 0, 0, tonumber(species))   -- 82800 = pet cage
    else
        -- equipment is listed per item level, so use the level of the bought item
        local level = 0
        if e.link and C_Item.IsEquippableItem and C_Item.IsEquippableItem(e.itemID) then
            level = C_Item.GetDetailedItemLevelInfo(e.link) or 0
        end
        itemKey = C_AuctionHouse.MakeItemKey(e.itemID, level)
    end
    if not itemKey then return false end

    local level = itemKey.itemLevel or 0
    pendingBuyView = nil
    local ok, err = pcall(ah.SelectBrowseResult, ah, { itemKey = itemKey, minPrice = 0, totalQuantity = 0 })
    if not ok then
        Debug("Opening the buy view failed, searching by name:", tostring(err))
    elseif level > 0 and name then
        pendingBuyView = { itemID = e.itemID, level = level, name = name, expires = GetTime() + 10 }
    end
    return ok
end

-- Called when item search results arrive: if our buy view stayed empty,
-- show all versions of the item instead
local function CheckEmptyBuyView(itemKey)
    local p = pendingBuyView
    if not p or type(itemKey) ~= "table" then return end
    if GetTime() > p.expires then
        pendingBuyView = nil
        return
    end
    if itemKey.itemID ~= p.itemID or (itemKey.itemLevel or 0) ~= p.level then return end
    local complete = not C_AuctionHouse.HasFullItemSearchResults or C_AuctionHouse.HasFullItemSearchResults(itemKey)
    if not complete then return end

    pendingBuyView = nil
    local count = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
    Debug(("Buy view for item level %d: %d listings"):format(p.level, count))
    if count == 0 then
        Print(("No listings at item level %d, showing all versions."):format(p.level))
        SearchInAH(p.name)
    end
end

local function FormatStats(count, qty)
    return ("Bought %d time(s), %s total"):format(count or 0, BreakUpLargeNumbers(qty or 0))
end

-- Columns from right to left; the item column fills the rest
local RIGHT_COLS = {
    { key = "date",  label = "Last bought", width = 90,  justify = "RIGHT" },
    { key = "price", label = "Unit price",  width = 115, justify = "RIGHT" },
    { key = "qty",   label = "Qty",         width = 35,  justify = "RIGHT" },
    { key = "char",  label = "Character",   width = 100, justify = "LEFT"  },
}

local function LayoutColumns(parent, fontTemplate)
    local cells = {}
    local anchor, anchorPoint, x = parent, "RIGHT", -6
    for _, col in ipairs(RIGHT_COLS) do
        local fs = parent:CreateFontString(nil, "OVERLAY", fontTemplate)
        fs:SetWidth(col.width)
        fs:SetJustifyH(col.justify)
        fs:SetWordWrap(false)
        fs:SetPoint("RIGHT", anchor, anchorPoint, x, 0)
        cells[col.key] = fs
        anchor, anchorPoint, x = fs, "LEFT", -8
    end
    local item = parent:CreateFontString(nil, "OVERLAY", fontTemplate)
    item:SetJustifyH("LEFT")
    item:SetWordWrap(false)
    item:SetPoint("LEFT", parent, "LEFT", 28, 0)
    item:SetPoint("RIGHT", anchor, "LEFT", -8, 0)
    cells.item = item
    return cells
end

local function Row_OnEnter(self)
    local d = self.data
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.link and not self.link:find("|Hbattlepet:") then
        inOwnTooltip = true
        GameTooltip:SetHyperlink(self.link)
        inOwnTooltip = false
    else
        GameTooltip:SetText(self.cells.item:GetText() or "")
    end

    GameTooltip:AddLine(" ")
    local s = db.stats[d.key]
    if s then
        if db.filter == ALL then
            GameTooltip:AddLine(FormatStats(s.count, s.qty), 1, 1, 1)
            local n = 0
            for _ in pairs(s.chars) do n = n + 1 end
            if n > 1 then
                for charKey, sc in pairs(s.chars) do
                    GameTooltip:AddDoubleLine(GetCharLabel(charKey),
                        ("%dx, %s total"):format(sc.count or 0, BreakUpLargeNumbers(sc.qty or 0)),
                        1, 1, 1, 1, 1, 1)
                end
            end
        else
            local sc = s.chars[db.filter]
            if sc then GameTooltip:AddLine(FormatStats(sc.count, sc.qty), 1, 1, 1) end
        end
    end
    GameTooltip:AddLine("Click: open in Buy tab", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Alt-click: search by name", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Shift-click: link in chat", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Right-click: remove", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function Row_OnLeave()
    GameTooltip:Hide()
end

local function ShowRowMenu(row)
    local d = row.data
    if not d then return end
    local name = row.cells.item:GetText() or ""
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(name)
        if db.filter == ALL then
            root:CreateButton("Remove from history", function()
                RemoveItem(d.key)
                ns.Refresh()
            end)
        else
            local charKey = db.filter
            root:CreateButton("Remove for " .. GetCharLabel(charKey), function()
                RemoveItemForChar(d.key, charKey)
                ns.Refresh()
            end)
        end
    end)
end

local function Row_OnClick(self, button)
    if button == "RightButton" then
        GameTooltip:Hide()
        ShowRowMenu(self)
        return
    end
    local name = self.link and self.link:match("%[(.-)%]")
    if IsAltKeyDown() then
        if name then SearchInAH(name) end           -- alt-click: search by name
        return
    end
    if IsModifierKeyDown() and self.link then
        HandleModifiedItemClick(self.link)          -- shift: chat link, ctrl: dressing room
        return
    end
    if self.data and OpenBuyView(self.data.e, name) then
        openedFromHistory = true
        return
    end
    if name then SearchInAH(name) end
end

local function InitRow(row, d)
    if not row.cells then
        row:SetHeight(ROW_HEIGHT)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0.04)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.82, 0, 0.12)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 4, 0)
        row.cells = LayoutColumns(row, "GameFontHighlightSmall")
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnEnter", Row_OnEnter)
        row:SetScript("OnLeave", Row_OnLeave)
        row:SetScript("OnClick", Row_OnClick)
    end

    row.data = d
    local text, icon, link = GetItemDisplay(d.key, d.e)
    row.link = link
    row.icon:SetTexture(icon or 134400)
    row.cells.item:SetText(text)

    local charText = GetCharLabel(d.char)
    if d.otherChars > 0 then
        charText = charText .. " |cff888888+" .. d.otherChars .. "|r"
    end
    row.cells.char:SetText(charText)
    row.cells.qty:SetText(d.qty or "")
    row.cells.price:SetText(d.unit and GetMoneyString(d.unit, true) or "?")
    row.cells.date:SetText(date("%d.%m.%y %H:%M", d.t))
    row.bg:SetShown(d.index % 2 == 0)
end

---------------------------------------------------------------------------
-- Sidebar: categories (like in the Buy tab) and time range
---------------------------------------------------------------------------

local NAV_HEIGHT = 20

-- Same order as in the Buy tab (Enum.ItemClass), unknown classes follow alphabetically
local CLASS_ORDER = { 2, 4, 1, 3, 8, 0, 16, 7, 9, 19, 17, 12, 15 }
local classRank = {}
for i, id in ipairs(CLASS_ORDER) do classRank[id] = i end

local TIME_RANGES = {
    { label = "All time" },
    { days = 1,  label = "Last 24 hours" },
    { days = 7,  label = "Last 7 days" },
    { days = 30, label = "Last 30 days" },
}

local GetClassInfo    = C_Item.GetItemClassInfo or GetItemClassInfo
local GetSubClassInfo = C_Item.GetItemSubClassInfo or GetItemSubClassInfo

local function ClassName(classID)
    return (classID and classID >= 0 and GetClassInfo(classID)) or "Other"
end

local function SubClassName(classID, subClassID)
    return (subClassID and subClassID >= 0 and (GetSubClassInfo(classID, subClassID))) or "Other"
end

local function GetItemClass(itemID)
    local c = classCache[itemID]
    if not c then
        local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
        c = { classID or -1, subClassID or -1 }
        classCache[itemID] = c
    end
    return c[1], c[2]
end

-- Use Blizzard's look if the atlas exists, otherwise a plain color
local function SetAtlasOr(tex, atlas, r, g, b, a)
    if C_Texture.GetAtlasInfo(atlas) then
        tex:SetAtlas(atlas)
        return true
    end
    tex:SetColorTexture(r, g, b, a)
    return false
end

local function SetupNavButton(btn)
    btn:SetHeight(NAV_HEIGHT)
    btn.normal = btn:CreateTexture(nil, "BACKGROUND")
    btn.normal:SetAllPoints()
    btn.selected = btn:CreateTexture(nil, "ARTWORK")
    btn.selected:SetAllPoints()
    SetAtlasOr(btn.selected, "auctionhouse-nav-button-select", 1, 0.82, 0, 0.2)
    btn.selected:Hide()
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    if SetAtlasOr(hl, "auctionhouse-nav-button-highlight", 1, 1, 1, 0.1) then hl:SetBlendMode("ADD") end
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.text:SetJustifyH("LEFT")
    btn.text:SetWordWrap(false)
    btn.count = btn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    btn.count:SetPoint("RIGHT", -8, 0)
end

local function StyleNavButton(btn, secondary, selected, indent)
    if secondary then
        SetAtlasOr(btn.normal, "auctionhouse-nav-button-secondary", 0, 0, 0, 0.15)
    else
        SetAtlasOr(btn.normal, "auctionhouse-nav-button", 0, 0, 0, 0.35)
    end
    btn.text:ClearAllPoints()
    btn.text:SetPoint("LEFT", indent or (secondary and 20 or 10), 0)
    btn.text:SetPoint("RIGHT", btn.count, "LEFT", -4, 0)
    if selected then
        btn.text:SetFontObject(btn.fontSelected or GameFontHighlightSmall)
    else
        btn.text:SetFontObject(btn.fontNormal or GameFontNormalSmall)
    end
    btn.selected:SetShown(selected)
end

local function CatButton_OnClick(self)
    local d = self.data
    if d.kind == "all" then
        catFilter.classID, catFilter.subClassID = nil, nil
    elseif d.kind == "class" then
        if catFilter.classID == d.classID and not catFilter.subClassID then
            catFilter.classID = nil      -- clicking again collapses it
        else
            catFilter.classID, catFilter.subClassID = d.classID, nil
        end
    else
        catFilter.classID, catFilter.subClassID = d.classID, d.subClassID
    end
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    ns.Refresh()
end

local function InitCatButton(btn, d)
    if not btn.text then
        SetupNavButton(btn)
        btn:SetScript("OnClick", CatButton_OnClick)
    end
    btn.data = d
    StyleNavButton(btn, d.kind == "sub", d.selected)
    btn.text:SetText(d.name)
    btn.count:SetText((d.count and d.count > 0) and d.count or "")
end

local function UpdateSidebar(classCounts, subCounts, poolCount)
    local items = {
        { kind = "all", name = "All categories", count = poolCount, selected = not catFilter.classID },
    }

    -- always show the selected category, even if it is currently empty
    if catFilter.classID and not classCounts[catFilter.classID] then classCounts[catFilter.classID] = 0 end

    local classes = {}
    for classID in pairs(classCounts) do classes[#classes + 1] = classID end
    table.sort(classes, function(a, b)
        local ra, rb = classRank[a] or 100, classRank[b] or 100
        if ra ~= rb then return ra < rb end
        return ClassName(a) < ClassName(b)
    end)

    for _, classID in ipairs(classes) do
        local isOpen = catFilter.classID == classID
        items[#items + 1] = {
            kind = "class", classID = classID, name = ClassName(classID),
            count = classCounts[classID], selected = isOpen and not catFilter.subClassID,
        }
        if isOpen then
            if catFilter.subClassID and not subCounts[catFilter.subClassID] then
                subCounts[catFilter.subClassID] = 0
            end
            local subs = {}
            for sub in pairs(subCounts) do subs[#subs + 1] = sub end
            table.sort(subs, function(a, b) return SubClassName(classID, a) < SubClassName(classID, b) end)
            for _, sub in ipairs(subs) do
                items[#items + 1] = {
                    kind = "sub", classID = classID, subClassID = sub, name = SubClassName(classID, sub),
                    count = subCounts[sub], selected = catFilter.subClassID == sub,
                }
            end
        end
    end

    ui.catBox:SetDataProvider(CreateDataProvider(items), ScrollBoxConstants.RetainScrollPosition)
    for _, btn in ipairs(ui.timeButtons) do
        StyleNavButton(btn, false, btn.days == timeFilter)
    end
end

---------------------------------------------------------------------------
-- List refresh
---------------------------------------------------------------------------

-- Item name for searching (from the link, otherwise from the item cache)
local function GetItemName(e)
    local name = e.link and e.link:match("%[(.-)%]")
    return name or C_Item.GetItemInfo(e.itemID)
end

function ns.Refresh()
    if not ui or not ui.frame:IsVisible() then return end
    local filter = db.filter
    local query = strtrim(ui.search:GetText() or ""):lower()
    local overflow = GetOverflowKeys() or {}
    local useSidebar = db.options.showSidebar
    local minTime = (useSidebar and timeFilter) and (time() - timeFilter * 86400) or nil

    -- 1) apply character filter, limit, time range and search
    local total, pool = 0, {}
    for key, e in pairs(db.entries) do
        local d
        if overflow[key] then
            -- above the limit: hide it, it is removed permanently on logout
        elseif filter == ALL then
            local n = 0
            for _ in pairs(e.chars) do n = n + 1 end
            d = {
                key = key, e = e, t = e.lastTime or 0, qty = e.lastQty, unit = e.lastUnit,
                char = e.lastChar, otherChars = n - 1,
            }
        else
            local c = e.chars[filter]
            if c then
                d = {
                    key = key, e = e, t = c.lastTime or 0, qty = c.lastQty, unit = c.lastUnit,
                    char = filter, otherChars = 0,
                }
            end
        end

        if d then
            total = total + 1
            local match = not minTime or d.t >= minTime
            if match and query ~= "" then
                local name = GetItemName(e)
                -- plain find: special characters like "-" or "(" are matched literally
                match = name and name:lower():find(query, 1, true) ~= nil
            end
            if match then
                d.classID, d.subClassID = GetItemClass(e.itemID)
                pool[#pool + 1] = d
            end
        end
    end

    -- 2) count categories and apply the category filter
    local list, classCounts, subCounts = {}, {}, {}
    for _, d in ipairs(pool) do
        classCounts[d.classID] = (classCounts[d.classID] or 0) + 1
        if d.classID == catFilter.classID then
            subCounts[d.subClassID] = (subCounts[d.subClassID] or 0) + 1
        end
        local inCategory = not useSidebar
            or ((not catFilter.classID or d.classID == catFilter.classID)
            and (not catFilter.subClassID or d.subClassID == catFilter.subClassID))
        if inCategory then list[#list + 1] = d end
    end

    -- most recently bought at the top
    table.sort(list, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.key < b.key
    end)
    for i, d in ipairs(list) do d.index = i end

    ui.scrollBox:SetDataProvider(CreateDataProvider(list), ScrollBoxConstants.RetainScrollPosition)
    if #list ~= total then
        ui.count:SetText(("%d / %d items"):format(#list, total))
        ui.empty:SetText("No matching items.")
    else
        ui.count:SetText(("%d items"):format(total))
        ui.empty:SetText("No purchases recorded yet.")
    end
    ui.empty:SetShown(#list == 0)

    if useSidebar then UpdateSidebar(classCounts, subCounts, #pool) end
end

-- Show/hide the sidebar and widen the list accordingly
local function ApplySidebar()
    if not ui then return end
    local show = db.options.showSidebar
    ui.sidebar:SetShown(show)
    ui.inset:ClearAllPoints()
    if show then
        ui.inset:SetPoint("TOPLEFT", ui.sidebar, "TOPRIGHT", 4, 0)
    else
        ui.inset:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 0, -34)
        catFilter.classID, catFilter.subClassID, timeFilter = nil, nil, nil
    end
    ui.inset:SetPoint("BOTTOMRIGHT", ui.frame, "BOTTOMRIGHT", 0, 0)
    ns.Refresh()
end

---------------------------------------------------------------------------
-- Confirmation dialog for clearing
---------------------------------------------------------------------------

StaticPopupDialogs["AHHISTORY_CLEAR"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        if pendingClear == ALL then
            ClearAll()
        elseif pendingClear then
            ClearChar(pendingClear)
        end
        pendingClear = nil
        ns.Refresh()
    end,
    OnCancel = function() pendingClear = nil end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
}

local function AskClear()
    pendingClear = db.filter
    local text
    if pendingClear == ALL then
        text = "Clear the purchase list for ALL characters?\nPurchase counters are kept."
    else
        text = ("Clear the purchase list of %s?\nPurchase counters are kept.")
            :format(GetCharLabel(pendingClear))
    end
    StaticPopup_Show("AHHISTORY_CLEAR", text)
end

---------------------------------------------------------------------------
-- Tab and frame in the Auction House
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Buy tab: group previously bought items at the top
---------------------------------------------------------------------------

local buyTabHookOk = false
local DEFAULT_GROUP_LOAD_LIMIT = 500
local PREV_BOUGHT_MAX_KEYS = 500      -- maximum number of items per "Previously bought" search
local prevBoughtActive = false        -- is our own search currently shown?
local prevBoughtButton
local prevBoughtKeys                  -- ItemKeys of our current search
local prevBoughtPending = false       -- search waits until the Auction House accepts requests
local prevBoughtWaitTicks = 0         -- safety net in case the ready signal never arrives
local prevSearchId = 0                -- increments per search so old timers do nothing
local prevKeySet = {}                 -- items of our current search (itemID:species)

-- Comparison key for an item: itemID plus pet species, without item level etc.
local function BaseSig(k)
    k = k or {}
    return ("%d:%d"):format(k.itemID or 0, k.battlePetSpeciesID or 0)
end

-- Do the displayed results come from our search? Recognizable by content: our
-- search only returns items from our list, any other search almost always others too.
local function ResultsAreOurs(results)
    if #results == 0 then return false end
    for _, r in ipairs(results) do
        if not prevKeySet[BaseSig(r.itemKey)] then return false end
    end
    return true
end
local prevRequeries = 0               -- automatic repeat queries of the current search
local prevRequeryScheduled = false
local PREV_MAX_REQUERIES = 2
local PREV_BOUGHT_SORTS = {
    { sortOrder = Enum.AuctionHouseSortOrder.Name,  reverseSort = false },
    { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
}

-- Send our own search as soon as the Auction House accepts new requests
local function SendPrevBoughtQuery()
    if not prevBoughtKeys or not prevBoughtActive then return end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        -- Normally AUCTION_HOUSE_THROTTLED_SYSTEM_READY takes care of this.
        -- Additionally check every second (max. 20 s) in case the signal never arrives.
        prevBoughtPending = true
        prevBoughtWaitTicks = prevBoughtWaitTicks + 1
        Debug("Previously bought: waiting for the Auction House to accept requests")
        if prevBoughtWaitTicks <= 20 then
            C_Timer.After(1, function()
                if prevBoughtPending then SendPrevBoughtQuery() end
            end)
        end
        return
    end
    prevBoughtPending = false
    C_AuctionHouse.SearchForItemKeys(prevBoughtKeys, PREV_BOUGHT_SORTS)
    Debug(("Previously bought: searching %d items"):format(#prevBoughtKeys))
end
local groupHint                       -- hint text below the result list

local function SetGroupHint(text)
    if not groupHint then return end
    groupHint:SetText(text or "")
    groupHint:SetShown(text ~= nil)
end

local function IsKnownItemKey(itemKey)
    if type(itemKey) ~= "table" or not itemKey.itemID then return false end
    local key
    if itemKey.battlePetSpeciesID and itemKey.battlePetSpeciesID > 0 then
        key = "pet:" .. itemKey.battlePetSpeciesID
    else
        key = "item:" .. itemKey.itemID
    end
    local s = db.stats[key]      -- counters instead of list: includes cleared entries
    return s ~= nil and (s.count or 0) > 0
end

-- Reorders the search results: known items first, within both groups
-- Blizzard's order (including the chosen column sorting) is kept
-- Results of our own search: available items first, unavailable ones at the end
local function HandlePrevBoughtResults(frame)
    local results = frame.browseResults
    if type(results) ~= "table" then return end

    -- While our search is still waiting or in flight, the list still shows the
    -- previous search. Neither reorder it nor load more batches of it,
    -- otherwise the Auction House stays busy and our search never gets through.
    if not ResultsAreOurs(results) then
        SetGroupHint("Loading current listings...")
        return
    end

    -- Repeated queries append their results to the existing list, and the entry
    -- with listings sometimes has different details (e.g. item level) than the old one
    -- without listings. So compare by itemID or pet species:
    --   - entries with listings are kept (exact duplicates only once)
    --   - an entry without listings is dropped as soon as the same item has listings
    local function FullSig(k)
        return ("%d:%d:%d:%d"):format(k.itemID or 0, k.itemLevel or 0,
            k.itemSuffix or 0, k.battlePetSpeciesID or 0)
    end

    local hasOffer = {}
    for _, r in ipairs(results) do
        if (r.totalQuantity or 0) > 0 then hasOffer[BaseSig(r.itemKey or {})] = true end
    end

    local available, none, seen = {}, {}, {}
    for _, r in ipairs(results) do
        local k = r.itemKey or {}
        if (r.totalQuantity or 0) > 0 then
            local sig = "A" .. FullSig(k)
            if not seen[sig] then
                seen[sig] = true
                available[#available + 1] = r
            end
        else
            local sig = "N" .. BaseSig(k)
            if not hasOffer[BaseSig(k)] and not seen[sig] then
                seen[sig] = true
                none[#none + 1] = r
            end
        end
    end

    -- Rewrite the list: available first, unavailable at the end, duplicates removed
    local oldLen = #results
    local i = 0
    for _, r in ipairs(available) do i = i + 1; results[i] = r end
    for _, r in ipairs(none)      do i = i + 1; results[i] = r end
    for j = oldLen, i + 1, -1 do results[j] = nil end
    local list = frame.ItemList
    if list and list.DirtyScrollFrame then list:DirtyScrollFrame() end

    -- The server sometimes sends results in several batches: request the missing ones.
    -- Every new batch triggers another refresh through the event.
    local complete = not C_AuctionHouse.HasFullBrowseResults or C_AuctionHouse.HasFullBrowseResults()
    Debug(("Previously bought: %d results (%d duplicates removed), %d available, complete: %s")
        :format(i, oldLen - i, #available, tostring(complete)))
    if not complete then
        SetGroupHint("Loading current listings...")
        C_AuctionHouse.RequestMoreBrowseResults()
    elseif #none > 0 and prevRequeries < PREV_MAX_REQUERIES then
        -- The server does not always include all listings the first time, a
        -- repeated search adds them (same as clicking again manually)
        if not prevRequeryScheduled then
            prevRequeryScheduled = true
            local searchId = prevSearchId
            SetGroupHint("Loading current listings...")
            Debug(("Previously bought: %d not available, asking again in 1s"):format(#none))
            C_Timer.After(1, function()
                prevRequeryScheduled = false
                if prevBoughtActive and searchId == prevSearchId then
                    prevRequeries = prevRequeries + 1
                    SendPrevBoughtQuery()
                end
            end)
        end
    else
        SetGroupHint(nil)
    end
end

local function GroupKnownFirst(frame)
    if prevBoughtActive then
        HandlePrevBoughtResults(frame)
        return
    end
    if not db.options.buyTabKnownFirst then
        SetGroupHint(nil)
        return
    end
    local results = frame.browseResults
    if type(results) ~= "table" then return end

    -- Incomplete list: load the rest up to the limit, pause grouping above it.
    -- Every additional batch triggers this function again.
    if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults() then
        local limit = db.options.groupLoadLimit or DEFAULT_GROUP_LOAD_LIMIT
        if #results < limit then
            C_AuctionHouse.RequestMoreBrowseResults()
            SetGroupHint("Loading all results for grouping...")
        else
            SetGroupHint(("Grouping paused: more than %s results"):format(BreakUpLargeNumbers(limit)))
        end
        return
    end
    SetGroupHint(nil)
    if #results < 2 then return end

    local known, rest = {}, {}
    for _, r in ipairs(results) do
        if IsKnownItemKey(r.itemKey) then known[#known + 1] = r else rest[#rest + 1] = r end
    end
    if #known == 0 or #rest == 0 then return end

    local i = 0
    for _, r in ipairs(known) do i = i + 1; results[i] = r end
    for _, r in ipairs(rest)  do i = i + 1; results[i] = r end

    local list = frame.ItemList
    if list and list.DirtyScrollFrame then list:DirtyScrollFrame() end
end


-- Colored highlight for known rows in the Buy tab
local DEFAULT_TINT = { r = 1, g = 0.82, b = 0, a = 0.15 }
local buyTabTintOk = false

-- Find the result for a row (stored differently depending on the client version)
local function GetBrowseEntry(frame, elementData)
    local brf = AuctionHouseFrame and AuctionHouseFrame.BrowseResultsFrame
    if type(elementData) == "number" then
        return brf and brf.browseResults and brf.browseResults[elementData]
    elseif type(elementData) == "table" then
        if elementData.itemKey then return elementData end
        if type(elementData.rowData) == "table" then return elementData.rowData end
    end
    return type(frame.rowData) == "table" and frame.rowData or nil
end

local function ApplyRowTint(frame, elementData)
    if type(frame) ~= "table" or not frame.CreateTexture then return end
    local entry = GetBrowseEntry(frame, elementData)
    local show = db.options.buyTabHighlight and not prevBoughtActive
        and entry and IsKnownItemKey(entry.itemKey)
    if show then
        if not frame.ahhTint then
            -- Own layer above the row's cells: the cells are child frames
            -- with their own background and would hide a texture on the row itself
            local overlay = CreateFrame("Frame", nil, frame)
            overlay:SetAllPoints()
            overlay:EnableMouse(false)   -- clicks pass through to the row
            frame.ahhTintFrame = overlay
            frame.ahhTint = overlay:CreateTexture(nil, "OVERLAY")
            frame.ahhTint:SetAllPoints()
        end
        frame.ahhTintFrame:SetFrameLevel(frame:GetFrameLevel() + 10)
        local c = db.options.buyTabColor
        frame.ahhTint:SetColorTexture(c.r, c.g, c.b, c.a)
        frame.ahhTint:Show()
    elseif frame.ahhTint then
        frame.ahhTint:Hide()   -- rows are recycled, so always reset
    end
end

local function RefreshBuyTabTint()
    local brf = AuctionHouseFrame and AuctionHouseFrame.BrowseResultsFrame
    local box = brf and brf.ItemList and brf.ItemList.ScrollBox
    if box and box.ForEachFrame then box:ForEachFrame(ApplyRowTint) end
end

local function OpenColorPicker()
    local c = db.options.buyTabColor
    local prev = { r = c.r, g = c.g, b = c.b, a = c.a }
    local function apply()
        c.r, c.g, c.b = ColorPickerFrame:GetColorRGB()
        c.a = ColorPickerFrame:GetColorAlpha()
        RefreshBuyTabTint()
    end
    ColorPickerFrame:SetupColorPickerAndShow({
        r = c.r, g = c.g, b = c.b, opacity = c.a, hasOpacity = true,
        swatchFunc = apply,
        opacityFunc = apply,
        cancelFunc = function()
            c.r, c.g, c.b, c.a = prev.r, prev.g, prev.b, prev.a
            RefreshBuyTabTint()
        end,
    })
end

local function ResetTintColor()
    db.options.buyTabColor = CopyTable(DEFAULT_TINT)
    RefreshBuyTabTint()
end

local prevBoughtChar                  -- nil = all characters, otherwise "Name-Realm"
local prevCatClass, prevCatSub        -- selected category / subcategory
local prevTreeOpen = false            -- tree on the left is expanded
local prevNodeSelected = false        -- an entry in the tree is selected
                                      -- (prevBoughtActive = our results on the right)
local prevRowButtons = {}             -- button pool for the tree entries
local prevCatBox, prevCatBoxPoints    -- Blizzard's category list and its original anchors
local blizzCatFont                    -- font copied from Blizzard's category buttons
local StartPrevBoughtSearch           -- defined further below
local LayoutPrevBought                -- defined further below

-- "item:123" -> 123, "pet:456" -> pet cage (for category info)
local function KeyToItemID(key)
    local kind, id = key:match("^(%a+):(%d+)$")
    if kind == "pet" then return 82800 end
    return tonumber(id)
end

local function BoughtBy(st, charKey)
    if charKey then
        local sc = st.chars and st.chars[charKey]
        return sc ~= nil and (sc.count or 0) > 0
    end
    return (st.count or 0) > 0
end

local function SortClassIDs(list)
    table.sort(list, function(a, b)
        local ra, rb = classRank[a] or 100, classRank[b] or 100
        if ra ~= rb then return ra < rb end
        return ClassName(a) < ClassName(b)
    end)
end

-- ItemKeys of bought items, filtered by character and category, most recent first
local function BuildKnownItemKeys(charKey, classID, subClassID)
    local ordered, times = {}, {}
    for key, st in pairs(db.stats) do
        local include = BoughtBy(st, charKey)
        if include and classID then
            local c, sc = GetItemClass(KeyToItemID(key))
            include = c == classID and (not subClassID or sc == subClassID)
        end
        if include then
            ordered[#ordered + 1] = key
            local e, t = db.entries[key], 0
            if e then
                if charKey then
                    t = e.chars[charKey] and e.chars[charKey].lastTime or 0
                else
                    t = e.lastTime or 0
                end
            end
            times[key] = t
        end
    end
    table.sort(ordered, function(a, b)
        if times[a] ~= times[b] then return times[a] > times[b] end
        return a < b
    end)

    local keys = {}
    for _, key in ipairs(ordered) do
        if #keys >= PREV_BOUGHT_MAX_KEYS then break end
        local kind, id = key:match("^(%a+):(%d+)$")
        id = tonumber(id)
        local itemKey
        if kind == "item" then
            itemKey = C_AuctionHouse.MakeItemKey(id)
        elseif kind == "pet" then
            itemKey = C_AuctionHouse.MakeItemKey(82800, 0, 0, id)   -- 82800 = pet cage
        end
        if itemKey then keys[#keys + 1] = itemKey end
    end
    return keys
end

-- Number of bought items per category (and per subcategory of the open one)
local function GetPrevCategoryCounts(charKey, openClass)
    local classCounts, subCounts = {}, {}
    for key, st in pairs(db.stats) do
        if BoughtBy(st, charKey) then
            local c, sc = GetItemClass(KeyToItemID(key))
            classCounts[c] = (classCounts[c] or 0) + 1
            if c == openClass then subCounts[sc] = (subCounts[sc] or 0) + 1 end
        end
    end
    return classCounts, subCounts
end

-- Characters with purchases, the logged-in one first
local function GetBuyerChars()
    local set = {}
    for _, st in pairs(db.stats) do
        for charKey, sc in pairs(st.chars or {}) do
            if (sc.count or 0) > 0 then set[charKey] = true end
        end
    end
    local list = {}
    for charKey in pairs(set) do
        if charKey ~= playerKey then list[#list + 1] = charKey end
    end
    table.sort(list)
    if set[playerKey] then table.insert(list, 1, playerKey) end
    return list
end

-- Entries of the expanded tree: characters, below them categories like in the History tab
local function BuildPrevRows()
    local rows = {}
    if not prevTreeOpen then return rows end

    local function AddCharNode(charKey, label)
        local isOpen = prevNodeSelected and prevBoughtChar == charKey
        rows[#rows + 1] = { level = 1, text = label, charKey = charKey, kind = "char",
            selected = isOpen and not prevCatClass }
        if not isOpen or not db.options.prevBoughtCategories then return end

        local classCounts, subCounts = GetPrevCategoryCounts(charKey, prevCatClass)
        local classes = {}
        for classID in pairs(classCounts) do classes[#classes + 1] = classID end
        SortClassIDs(classes)
        for _, classID in ipairs(classes) do
            local classOpen = prevCatClass == classID
            rows[#rows + 1] = { level = 2, text = ClassName(classID), count = classCounts[classID],
                kind = "class", charKey = charKey, classID = classID,
                selected = classOpen and not prevCatSub }
            if classOpen then
                local subs = {}
                for sub in pairs(subCounts) do subs[#subs + 1] = sub end
                table.sort(subs, function(a, b) return SubClassName(classID, a) < SubClassName(classID, b) end)
                for _, sub in ipairs(subs) do
                    rows[#rows + 1] = { level = 3, text = SubClassName(classID, sub), count = subCounts[sub],
                        kind = "sub", charKey = charKey, classID = classID, subClassID = sub,
                        selected = prevCatSub == sub }
                end
            end
        end
    end

    AddCharNode(nil, "All characters")
    for _, charKey in ipairs(GetBuyerChars()) do
        AddCharNode(charKey, GetCharLabel(charKey))
    end
    return rows
end

local function StylePrevButton(btn, level, selected)
    if blizzCatFont then btn.fontNormal, btn.fontSelected = blizzCatFont, blizzCatFont end
    StyleNavButton(btn, level > 0, selected, 10 + level * 10)
end

local function UpdatePrevBoughtButton()
    if not prevBoughtButton then return end
    StylePrevButton(prevBoughtButton, 0, false)
    for _, btn in ipairs(prevRowButtons) do
        if btn:IsShown() and btn.row then StylePrevButton(btn, btn.row.level, btn.row.selected) end
    end
end

-- Collapse the tree and clear the selection. The results on the right stay
-- until a new search starts (like Blizzard's categories).
local function CollapsePrevTree()
    prevTreeOpen = false
    LayoutPrevBought()
end

local function PrevRow_OnClick(self)
    local row = self.row
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    if row.selected then
        -- Second click: collapse only this entry, the level above gets selected
        if row.kind == "sub" then
            StartPrevBoughtSearch(row.charKey, row.classID)
        elseif row.kind == "class" then
            StartPrevBoughtSearch(row.charKey)
        else
            -- Character: collapse and deselect, the character list stays visible.
            -- The results on the right stay until the next search.
            prevNodeSelected = false
            LayoutPrevBought()
        end
    elseif row.kind == "char" then
        StartPrevBoughtSearch(row.charKey)
    elseif row.kind == "class" then
        StartPrevBoughtSearch(row.charKey, row.classID)
    else
        StartPrevBoughtSearch(row.charKey, row.classID, row.subClassID)
    end
end

-- Stack the button and tree above Blizzard's list and move the list down accordingly
LayoutPrevBought = function()
    if not prevBoughtButton then return end

    local rowData = BuildPrevRows()
    local stack = { prevBoughtButton }
    for i, row in ipairs(rowData) do
        local btn = prevRowButtons[i]
        if not btn then
            btn = CreateFrame("Button", nil, prevBoughtButton:GetParent())
            SetupNavButton(btn)
            btn:SetScript("OnClick", PrevRow_OnClick)
            prevRowButtons[i] = btn
        end
        btn.row = row
        btn.text:SetText(row.text)
        btn.count:SetText(row.count or "")
        btn:Show()
        stack[#stack + 1] = btn
    end
    for i = #rowData + 1, #prevRowButtons do
        prevRowButtons[i]:Hide()
        prevRowButtons[i].row = nil
    end

    -- bottom to top: the last entry sits directly above Blizzard's list
    for i = #stack, 1, -1 do
        local btn = stack[i]
        btn:ClearAllPoints()
        local below = stack[i + 1]
        if below then
            btn:SetPoint("BOTTOMLEFT", below, "TOPLEFT", 0, 0)
            btn:SetPoint("BOTTOMRIGHT", below, "TOPRIGHT", 0, 0)
        else
            btn:SetPoint("BOTTOMLEFT", prevCatBox, "TOPLEFT", 0, 4)
            btn:SetPoint("BOTTOMRIGHT", prevCatBox, "TOPRIGHT", 0, 4)
        end
    end

    local offset = #stack * NAV_HEIGHT + 4
    prevCatBox:ClearAllPoints()
    for _, pt in ipairs(prevCatBoxPoints) do
        local y = pt[5] or 0
        if pt[1]:find("TOP") then y = y - offset end
        prevCatBox:SetPoint(pt[1], pt[2], pt[3], pt[4], y)
    end

    UpdatePrevBoughtButton()
end

StartPrevBoughtSearch = function(charKey, classID, subClassID)
    local ah = AuctionHouseFrame
    local keys = BuildKnownItemKeys(charKey, classID, subClassID)
    if #keys == 0 then
        Print("No purchases recorded yet.")
        return
    end

    local buyMode = AuctionHouseFrameDisplayMode and AuctionHouseFrameDisplayMode.Buy
    local current = ah.GetDisplayMode and ah:GetDisplayMode() or ah.displayMode
    if buyMode and current ~= buyMode then ah:SetDisplayMode(buyMode) end

    -- Clear Blizzard's category selection (if this client version supports it)
    local cl = ah.CategoriesList
    if cl and cl.SetSelectedCategory then pcall(cl.SetSelectedCategory, cl, nil) end

    prevBoughtActive = true
    prevTreeOpen = true
    prevNodeSelected = true
    prevBoughtChar, prevCatClass, prevCatSub = charKey, classID, subClassID
    prevBoughtKeys = keys
    prevKeySet = {}
    for _, k in ipairs(keys) do prevKeySet[BaseSig(k)] = true end
    prevBoughtWaitTicks = 0
    prevSearchId = prevSearchId + 1
    prevRequeries = 0
    prevRequeryScheduled = false
    LayoutPrevBought()
    SetGroupHint("Loading current listings...")
    SendPrevBoughtQuery()
end

-- Copy the font from Blizzard's category buttons so it looks identical
-- Click on a column header: Blizzard then repeats its own last
-- search with the new sort order (right after opening the AH: the favorites search).
-- In our view, repeat our own search with that sort order instead.
local lastBrowseSig

local function QuerySig(query)
    if type(query) ~= "table" then return "" end
    local parts = { tostring(query.searchString or ""), tostring(query.minLevel or ""),
                    tostring(query.maxLevel or "") }
    for _, f in ipairs(query.filters or {}) do parts[#parts + 1] = "f" .. tostring(f) end
    for _, c in ipairs(query.itemClassFilters or {}) do
        parts[#parts + 1] = ("c%s:%s:%s"):format(tostring(c.classID), tostring(c.subClassID),
            tostring(c.inventoryType))
    end
    return table.concat(parts, "|")
end

local function RestartPrevBought(sorts)
    if type(sorts) == "table" and #sorts > 0 then PREV_BOUGHT_SORTS = CopyTable(sorts) end
    prevSearchId = prevSearchId + 1
    prevRequeries = 0
    prevRequeryScheduled = false
    prevBoughtWaitTicks = 0
    SetGroupHint("Loading current listings...")
    Debug("Previously bought: re-sorting")
    SendPrevBoughtQuery()
end

-- Like Blizzard's list: clicking another category immediately clears our selection
-- and collapses the tree. The results on the right stay until a new search starts.
local function OnBlizzCategoryClicked()
    Debug("Blizzard category clicked")
    if prevTreeOpen then
        prevTreeOpen = false
        LayoutPrevBought()
    end
end

local catClickHookOk = false
local favoritesHookOk = false

local function CopyBlizzardCategoryFont()
    if blizzCatFont or not prevCatBox or not prevCatBox.ForEachFrame then return end
    prevCatBox:ForEachFrame(function(frame)
        if blizzCatFont then return end
        local fs = frame.Text or (frame.GetFontString and frame:GetFontString())
        local font = fs and fs.GetFontObject and fs:GetFontObject()
        if font then blizzCatFont = font end
    end)
    if blizzCatFont then UpdatePrevBoughtButton() end
end

local function CreatePrevBoughtButton(ah)
    local cl = ah.CategoriesList
    local catBox = cl and cl.ScrollBox
    if not catBox then return end

    prevCatBox = catBox
    prevCatBoxPoints = {}
    for i = 1, catBox:GetNumPoints() do prevCatBoxPoints[i] = { catBox:GetPoint(i) } end

    local btn = CreateFrame("Button", nil, cl)
    SetupNavButton(btn)
    btn.text:SetText("Previously bought")
    btn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if prevTreeOpen then
            CollapsePrevTree()                                 -- expanded: collapse
        else
            StartPrevBoughtSearch(nil)
        end
    end)
    btn:SetScript("OnShow", CopyBlizzardCategoryFont)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Previously bought")
        GameTooltip:AddLine("Shows items you have bought before that are currently listed. "
            .. "Pick a character below to see only their purchases.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    prevBoughtButton = btn

    -- Every click on a Blizzard category goes through the list's OnFilterClicked.
    -- (Hooking individual buttons does not work: Blizzard resets their click script
    -- when recycling them, which overwrites other hooks.)
    if cl.OnFilterClicked then
        hooksecurefunc(cl, "OnFilterClicked", OnBlizzCategoryClicked)
        catClickHookOk = true
    end
    LayoutPrevBought()

    local function EndPrevBoughtView()
        if prevBoughtActive or prevTreeOpen then
            prevBoughtActive = false
            prevTreeOpen = false
            prevBoughtPending = false
            LayoutPrevBought()
        end
    end

    -- Every normal search (search box, category) ends our view and collapses the tree.
    -- Exception: Blizzard only repeats its last search with a new sort order.
    hooksecurefunc(C_AuctionHouse, "SendBrowseQuery", function(query)
        local sig = QuerySig(query)
        local isResort = prevBoughtActive and sig == lastBrowseSig
        lastBrowseSig = sig
        if isResort then
            RestartPrevBought(query.sorts)
        else
            EndPrevBoughtView()
        end
    end)

    -- Favorites search: if it comes from the star button, the player wants to
    -- see their favorites. Otherwise Blizzard only repeated it for re-sorting.
    local favoritesClicked = false
    local favButton = ah.SearchBar and ah.SearchBar.FavoritesSearchButton
    if favButton then
        -- PreClick runs before Blizzard's click handler, i.e. before the favorites search
        favButton:HookScript("PreClick", function() favoritesClicked = true end)
        favoritesHookOk = true
    end
    if C_AuctionHouse.SearchForFavorites then
        hooksecurefunc(C_AuctionHouse, "SearchForFavorites", function(sorts)
            if favoritesClicked then
                favoritesClicked = false
                EndPrevBoughtView()
            elseif prevBoughtActive then
                RestartPrevBought(sorts)
            end
        end)
    end
end

local function HookBuyTab(ah)
    local brf = ah.BrowseResultsFrame
    if brf and brf.UpdateBrowseResults then
        hooksecurefunc(brf, "UpdateBrowseResults", GroupKnownFirst)
        buyTabHookOk = true
    end

    -- After every redraw of the result list (search, scrolling, sorting)
    -- tint all visible rows
    local box = brf and brf.ItemList and brf.ItemList.ScrollBox
    if box and box.Update then
        hooksecurefunc(box, "Update", RefreshBuyTabTint)
        buyTabTintOk = true
    end

    if brf then
        groupHint = brf:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        groupHint:SetPoint("TOPRIGHT", brf, "BOTTOMRIGHT", -4, -6)
        groupHint:Hide()
    end

    if C_AuctionHouse.SearchForItemKeys and C_AuctionHouse.MakeItemKey then
        CreatePrevBoughtButton(ah)
    end
end

---------------------------------------------------------------------------
-- History tab position
--   Other addons (e.g. Auctioneer) add their own tabs, sometimes at fixed
--   positions or later than we do. On every AH open we look for the tab that
--   is actually furthest to the right and line up behind it.
---------------------------------------------------------------------------

-- Does frame (directly or through its anchor chain) depend on target?
-- Anchoring to such a frame would create a loop, so we skip it.
local function DependsOn(frame, target)
    local visited = {}
    local function walk(f)
        if not f or visited[f] or not f.GetNumPoints then return false end
        visited[f] = true
        for i = 1, f:GetNumPoints() do
            local _, rel = f:GetPoint(i)
            if rel == target or walk(rel) then return true end
        end
        return false
    end
    return walk(frame)
end

-- All visible tab-like buttons in the tab row of the Auction House
local function FindTabRowButtons()
    local ah = AuctionHouseFrame
    local ref = ah.BuyTab or ah.Tabs[1]
    local refTop = ref and ref:GetTop()
    local found = {}
    if not refTop then return found end
    for _, child in ipairs({ ah:GetChildren() }) do
        if child ~= ui.tab and child:IsShown() and child:GetObjectType() == "Button" then
            local top, right = child:GetTop(), child:GetRight()
            if top and right and math.abs(top - refTop) < 8 then
                found[#found + 1] = child
            end
        end
    end
    return found
end

local function PlaceHistoryTab()
    if not ui or not ui.tab then return end
    local ah, tab = AuctionHouseFrame, ui.tab

    local best = ui.defaultTabAnchor
    local bestRight = best and best:GetRight() or 0
    for _, button in ipairs(FindTabRowButtons()) do
        local right = button:GetRight()
        if right > bestRight and not DependsOn(button, tab) then
            best, bestRight = button, right
        end
    end

    tab:ClearAllPoints()
    tab:SetPoint("LEFT", best, "RIGHT", ui.tabXOff, 0)

    if debugMode then
        local name = best and (best:GetName() or best:GetText() or "unnamed") or "none"
        Debug(("History tab placed after: %s"):format(tostring(name)))
        local tabRight, ahRight = tab:GetRight(), ah:GetRight()
        if tabRight and ahRight and tabRight > ahRight then
            Debug("History tab does not fit into the Auction House frame")
        end
    end
end

local function CreateUI()
    local ah = AuctionHouseFrame
    if not ah or ui then return end

    local f = CreateFrame("Frame", nil, ah)
    f:SetPoint("TOPLEFT", ah, "TOPLEFT", 10, -30)
    f:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -8, 28)
    f:Hide()
    ah.AHHistoryFrame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 58, -8)   -- right of the portrait icon
    title:SetText("Purchase History")

    local count = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    count:SetPoint("LEFT", title, "RIGHT", 10, -1)

    local dd = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    dd:SetWidth(200)
    dd:SetPoint("TOPRIGHT", -6, -4)
    dd:SetupMenu(function(_, root)
        local function IsSelected(v) return db.filter == v end
        local function SetSelected(v) db.filter = v; ns.Refresh() end
        root:CreateRadio("All characters", IsSelected, SetSelected, ALL)
        local chars = {}
        for k in pairs(db.chars) do chars[#chars + 1] = k end
        table.sort(chars)
        for _, k in ipairs(chars) do
            root:CreateRadio(GetCharLabel(k), IsSelected, SetSelected, k)
        end
    end)

    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(90, 22)
    clearBtn:SetPoint("RIGHT", dd, "LEFT", -8, 0)
    clearBtn:SetText("Clear...")
    clearBtn:SetScript("OnClick", AskClear)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Clear list")
        GameTooltip:AddLine("Clears the list of the character selected on the right,", 1, 1, 1)
        GameTooltip:AddLine("or everything when \"All characters\" is selected.", 1, 1, 1)
        GameTooltip:AddLine("Purchase counters are kept.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", Row_OnLeave)

    local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    search:SetSize(160, 20)
    search:SetPoint("RIGHT", clearBtn, "LEFT", -12, 0)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function() ns.Refresh() end)

    -- Sidebar on the left
    local sidebar = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    sidebar:SetPoint("TOPLEFT", 0, -34)
    sidebar:SetPoint("BOTTOMLEFT", 0, 0)
    sidebar:SetWidth(165)

    local timeButtons = {}
    for i = #TIME_RANGES, 1, -1 do
        local range = TIME_RANGES[i]
        local btn = CreateFrame("Button", nil, sidebar)
        SetupNavButton(btn)
        btn.days = range.days
        btn.text:SetText(range.label)
        btn:SetPoint("BOTTOMLEFT", 4, 4 + (#TIME_RANGES - i) * NAV_HEIGHT)
        btn:SetPoint("BOTTOMRIGHT", -4, 4 + (#TIME_RANGES - i) * NAV_HEIGHT)
        btn:SetScript("OnClick", function(self)
            timeFilter = self.days
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            ns.Refresh()
        end)
        StyleNavButton(btn, false, false)
        timeButtons[i] = btn
    end

    local timeHeader = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    timeHeader:SetPoint("BOTTOMLEFT", timeButtons[1], "TOPLEFT", 6, 4)
    timeHeader:SetText("Time range")

    local catBox = CreateFrame("Frame", nil, sidebar, "WowScrollBoxList")
    catBox:SetPoint("TOPLEFT", 4, -4)
    catBox:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -14, 4 + (#TIME_RANGES * NAV_HEIGHT) + 26)

    local catBar = CreateFrame("EventFrame", nil, sidebar, "MinimalScrollBar")
    catBar:SetPoint("TOPLEFT", catBox, "TOPRIGHT", 4, 0)
    catBar:SetPoint("BOTTOMLEFT", catBox, "BOTTOMRIGHT", 4, 0)

    local catView = CreateScrollBoxListLinearView()
    catView:SetElementExtent(NAV_HEIGHT)
    catView:SetElementInitializer("Button", InitCatButton)
    ScrollUtil.InitScrollBoxListWithScrollBar(catBox, catBar, catView)
    if ScrollUtil.AddManagedScrollBarVisibilityBehavior then
        ScrollUtil.AddManagedScrollBarVisibilityBehavior(catBox, catBar)
    end

    -- List on the right (anchors are set by ApplySidebar)
    local inset = CreateFrame("Frame", nil, f, "InsetFrameTemplate")

    local header = CreateFrame("Frame", nil, inset)
    header:SetPoint("TOPLEFT", 4, -4)
    header:SetPoint("TOPRIGHT", -26, -4)
    header:SetHeight(20)
    local hcells = LayoutColumns(header, "GameFontNormalSmall")
    hcells.item:SetText("Item")
    for _, col in ipairs(RIGHT_COLS) do hcells[col.key]:SetText(col.label) end

    local scrollBox = CreateFrame("Frame", nil, inset, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    scrollBox:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -26, 4)

    local scrollBar = CreateFrame("EventFrame", nil, inset, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 8, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 8, 0)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    local empty = inset:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("CENTER")
    empty:SetText("No purchases recorded yet.")

    ui = {
        frame = f, scrollBox = scrollBox, count = count, empty = empty, dropdown = dd, search = search,
        sidebar = sidebar, inset = inset, catBox = catBox, timeButtons = timeButtons,
    }

    -- Tab button at the bottom next to Buy/Sell/Auctions
    local tabs = ah.Tabs
    local lastTab = tabs[#tabs]   -- remember it BEFORE the new tab exists

    local xOff = 3
    if tabs[2] then
        local _, rel, _, x = tabs[2]:GetPoint(1)
        if rel == tabs[1] and x then xOff = x end
    end

    local template = C_XMLUtil.GetTemplateInfo("AuctionHouseFrameTabTemplate")
        and "AuctionHouseFrameTabTemplate" or "PanelTabButtonTemplate"
    local tab = CreateFrame("Button", "AuctionHouseFrameAHHistoryTab", ah, template)

    -- Blizzard's template adds itself to ah.Tabs (parentArray),
    -- so only insert it if it is not already there
    local index = tIndexOf(tabs, tab)
    if not index then
        table.insert(tabs, tab)
        index = #tabs
    end

    tab:SetPoint("LEFT", lastTab, "RIGHT", xOff, 0)
    tab:SetText("History")
    tab:SetID(index)
    tab.displayMode = HISTORY_MODE
    if ah.tabsForDisplayMode then ah.tabsForDisplayMode[HISTORY_MODE] = index end
    PanelTemplates_SetNumTabs(ah, #tabs)

    tab:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
        ah:SetDisplayMode(HISTORY_MODE)
    end)

    ui.tab = tab
    ui.defaultTabAnchor = lastTab
    ui.tabXOff = xOff
    -- one frame later, so other addons have created and placed their tabs
    ah:HookScript("OnShow", function() C_Timer.After(0, PlaceHistoryTab) end)

    -- show/hide our own frame ourselves, independent of Blizzard's logic
    hooksecurefunc(ah, "SetDisplayMode", function(self, mode)
        if mode == HISTORY_MODE then
            f:Show()
            PanelTemplates_SetTab(self, tab:GetID())
            return
        end
        f:Hide()

        local modes = AuctionHouseFrameDisplayMode or {}
        if mode ~= modes.ItemBuy and mode ~= modes.CommoditiesBuy then
            openedFromHistory = false
        end

        -- Blizzard does not update the tabs for every mode (e.g. the buy view).
        -- The History tab must not stay selected, a selected tab cannot be clicked.
        local selected = PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(self) or self.selectedTab
        if selected == tab:GetID() then
            PanelTemplates_SetTab(self, tIndexOf(self.Tabs, self.BuyTab) or 1)
        end
    end)

    -- "Back" in the buy view: return to the History tab if we came from there
    local backFromHistory = false
    for _, buyFrame in ipairs({ ah.ItemBuyFrame, ah.CommoditiesBuyFrame }) do
        local back = buyFrame and buyFrame.BackButton
        if back then
            -- PreClick runs before Blizzard switches back to the Buy tab
            back:HookScript("PreClick", function() backFromHistory = openedFromHistory end)
            back:HookScript("OnClick", function()
                if backFromHistory then
                    backFromHistory = false
                    ah:SetDisplayMode(HISTORY_MODE)
                end
            end)
        end
    end

    f:SetScript("OnShow", function()
        dd:GenerateMenu()
        ns.Refresh()
    end)

    ApplySidebar()
    HookBuyTab(ah)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Counter in every item tooltip (bags, chat links, professions etc.)
---------------------------------------------------------------------------

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if not db or not db.options.globalTooltip or inOwnTooltip then return end
    -- main tooltips only, no comparison tooltips
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    local id = data and data.id
    if issecretvalue and issecretvalue(id) then return end
    if type(id) ~= "number" then return end
    local s = db.stats["item:" .. id]
    if not s or (s.count or 0) == 0 then
        -- Skip items that can never be on the AH (Bind on Pickup, quest items)
        local bindType = select(14, C_Item.GetItemInfo(id))
        if bindType == nil or bindType == 1 or bindType == 4 then return end
        tooltip:AddLine("|cffffcc00AH:|r no purchases recorded", 0.5, 0.5, 0.5)
        return
    end
    tooltip:AddLine(("|cffffcc00AH:|r bought %dx, %s total"):format(s.count, BreakUpLargeNumbers(s.qty or 0)),
        1, 1, 1)
end)

---------------------------------------------------------------------------
-- Options in the game menu (Esc > Options > AddOns > AH History)
---------------------------------------------------------------------------

-- Set the character filter to the default from the options
ApplyDefaultCharFilter = function()
    if db.options.defaultCurrentChar and playerKey then
        db.filter = playerKey
    else
        db.filter = ALL
    end
end

local function CreateSettings()
    local category, layout = Settings.RegisterVerticalLayoutCategory("AH History")

    local setting = Settings.RegisterAddOnSetting(category,
        "AHHistory_GlobalTooltip",       -- unique name
        "globalTooltip",                 -- key in db.options
        db.options,
        Settings.VarType.Boolean,
        "Show purchase counter in item tooltips",
        true)
    Settings.CreateCheckbox(category, setting,
        "Adds a line with your Auction House purchase count to every item tooltip, "
        .. "e.g. in your bags, chat links or profession windows.")

    local limitSetting = Settings.RegisterAddOnSetting(category,
        "AHHistory_MaxEntries",
        "maxEntries",
        db.options,
        Settings.VarType.Number,
        "Maximum list entries",
        DEFAULT_MAX_ENTRIES)
    local sliderOptions = Settings.CreateSliderOptions(500, 10000, 500)
    sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(category, limitSetting, sliderOptions,
        "How many different items the History tab keeps. Older entries beyond the limit "
        .. "are hidden right away and removed on logout, so you can still undo a change "
        .. "until then. Purchase counters are always kept.")
    limitSetting:SetValueChangedCallback(function() ns.Refresh() end)

    local sidebarSetting = Settings.RegisterAddOnSetting(category,
        "AHHistory_ShowSidebar",
        "showSidebar",
        db.options,
        Settings.VarType.Boolean,
        "Show category and time filters",
        true)
    Settings.CreateCheckbox(category, sidebarSetting,
        "Shows a sidebar in the History tab with item categories like in the Buy tab "
        .. "and a time range filter. When disabled, the list uses the full width.")
    sidebarSetting:SetValueChangedCallback(function() ApplySidebar() end)

    local charSetting = Settings.RegisterAddOnSetting(category,
        "AHHistory_DefaultCurrentChar",
        "defaultCurrentChar",
        db.options,
        Settings.VarType.Boolean,
        "Show only the current character by default",
        false)
    Settings.CreateCheckbox(category, charSetting,
        "When enabled, the History tab starts filtered to the character you are logged in with. "
        .. "When disabled, it starts with all characters. You can still switch at any time "
        .. "with the dropdown in the History tab.")
    local buySetting = Settings.RegisterAddOnSetting(category,
        "AHHistory_BuyTabKnownFirst",
        "buyTabKnownFirst",
        db.options,
        Settings.VarType.Boolean,
        "Show previously bought items first in the Buy tab",
        true)
    Settings.CreateCheckbox(category, buySetting,
        "Groups items you have bought before at the top of the Buy tab search results. "
        .. "The chosen column sorting still applies within both groups. "
        .. "Changes take effect with the next search.")

    local loadSetting = Settings.RegisterAddOnSetting(category,
        "AHHistory_GroupLoadLimit",
        "groupLoadLimit",
        db.options,
        Settings.VarType.Number,
        "Results to load for grouping",
        DEFAULT_GROUP_LOAD_LIMIT)
    local loadOptions = Settings.CreateSliderOptions(100, 5000, 100)
    loadOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(category, loadSetting, loadOptions,
        "Searches with up to this many results are loaded completely, so previously bought "
        .. "items can be grouped at the top. Larger searches are shown without grouping.\n\n"
        .. "|cffff4040Warning: higher values send more requests to the server. This can make "
        .. "the Auction House noticeably slower and may trigger Blizzard's request throttling.|r")

    local tintSetting = Settings.RegisterAddOnSetting(category,
        "AHHistory_BuyTabHighlight",
        "buyTabHighlight",
        db.options,
        Settings.VarType.Boolean,
        "Highlight previously bought items in the Buy tab",
        true)
    Settings.CreateCheckbox(category, tintSetting,
        "Tints the rows of items you have bought before in the Buy tab search results.")
    tintSetting:SetValueChangedCallback(function() RefreshBuyTabTint() end)

    local prevCatSetting = Settings.RegisterAddOnSetting(category,
        "AHHistory_PrevBoughtCategories",
        "prevBoughtCategories",
        db.options,
        Settings.VarType.Boolean,
        "Show categories under \"Previously bought\"",
        true)
    Settings.CreateCheckbox(category, prevCatSetting,
        "Shows item categories below each character in the \"Previously bought\" entry "
        .. "of the Buy tab. Disable this if the list on the left gets too long.")
    prevCatSetting:SetValueChangedCallback(function()
        if prevBoughtActive and prevCatClass and not db.options.prevBoughtCategories then
            StartPrevBoughtSearch(prevBoughtChar)   -- clear the category filter
        else
            LayoutPrevBought()
        end
    end)

    if layout and CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer("Highlight color", "Choose color...",
            OpenColorPicker, "Color and transparency of the Buy tab highlight.", true))
        layout:AddInitializer(CreateSettingsButtonInitializer("Reset highlight color", "Reset",
            ResetTintColor, "Restores the default gold highlight.", true))
    end

    charSetting:SetValueChangedCallback(function()
        ApplyDefaultCharFilter()
        if ui then ui.dropdown:GenerateMenu() end
        ns.Refresh()
    end)

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

-- Migrate data from early versions (counters inside list entries) to db.stats
local function MigrateV1()
    for key, e in pairs(db.entries) do
        if e.count ~= nil or not db.stats[key] then
            local s = db.stats[key] or { count = 0, qty = 0, chars = {} }
            if not db.stats[key] then
                for charKey, c in pairs(e.chars) do
                    local cnt = c.count or 1
                    local qty = c.lastQty or 1   -- only the known quantity, no estimate
                    s.chars[charKey] = { count = cnt, qty = qty }
                    s.count, s.qty = s.count + cnt, s.qty + qty
                end
                db.stats[key] = s
            end
            e.count = nil
            for _, c in pairs(e.chars) do c.count = nil end
        end
    end
end

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= ADDON_NAME then return end
    AHHistoryDB = AHHistoryDB or {}
    db = AHHistoryDB
    db.entries = db.entries or {}
    db.stats   = db.stats or {}
    db.chars   = db.chars or {}
    db.filter  = db.filter or ALL
    db.options = db.options or {}
    if db.options.globalTooltip == nil then db.options.globalTooltip = true end
    if db.options.maxEntries == nil then db.options.maxEntries = DEFAULT_MAX_ENTRIES end
    if db.options.showSidebar == nil then db.options.showSidebar = true end
    if db.options.defaultCurrentChar == nil then db.options.defaultCurrentChar = false end
    if db.options.buyTabKnownFirst == nil then db.options.buyTabKnownFirst = true end
    if db.options.buyTabHighlight == nil then db.options.buyTabHighlight = true end
    if db.options.groupLoadLimit == nil then db.options.groupLoadLimit = DEFAULT_GROUP_LOAD_LIMIT end
    if db.options.prevBoughtCategories == nil then db.options.prevBoughtCategories = true end
    if type(db.options.buyTabColor) ~= "table" then db.options.buyTabColor = CopyTable(DEFAULT_TINT) end
    MigrateV1()
    CreateSettings()

    -- Wait one frame so other addons (e.g. TSM) create their tabs first,
    -- and isolate errors so they never break other addons' code
    EventUtil.ContinueOnAddOnLoaded("Blizzard_AuctionHouseUI", function()
        C_Timer.After(0, function() xpcall(CreateUI, geterrorhandler()) end)
    end)
end

function handlers.PLAYER_LOGOUT()
    if db then Prune() end
end

function handlers.PLAYER_LOGIN()
    playerKey = UnitName("player") .. "-" .. (GetNormalizedRealmName() or "")
    db.chars[playerKey] = select(2, UnitClass("player"))
    ApplyDefaultCharFilter()
end

function handlers.ITEM_SEARCH_RESULTS_UPDATED(itemKey)
    if type(itemKey) == "table" then lastItemKey = itemKey end
    CheckEmptyBuyView(itemKey)
end
handlers.ITEM_SEARCH_RESULTS_ADDED = handlers.ITEM_SEARCH_RESULTS_UPDATED

function handlers.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
    local p = pendingItem
    if p and (not auctionID or auctionID == p.auctionID) then
        pendingItem = nil
        RecordPurchase(p.itemID, p.link, p.qty, p.total)
    end
end

function handlers.COMMODITY_PRICE_UPDATED(_, totalPrice)
    if pendingCommodity then pendingCommodity.total = totalPrice end
end

function handlers.COMMODITY_PURCHASE_SUCCEEDED() FinishCommodity() end
function handlers.COMMODITY_PURCHASED(itemID, qty) FinishCommodity(itemID, qty) end
function handlers.COMMODITY_PURCHASE_FAILED() pendingCommodity = nil end

function handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
    if prevBoughtPending and prevBoughtActive then SendPrevBoughtQuery() end
end

-- Blizzard's result list does not reliably pick up our results by itself,
-- especially right after opening the AH. So for EVERY incoming batch
-- refresh the list ourselves one frame later (several batches in the
-- same frame trigger only one refresh).
local prevRefreshQueued = false
local function QueuePrevBoughtRefresh()
    if not prevBoughtActive or prevRefreshQueued then return end
    prevRefreshQueued = true
    C_Timer.After(0, function()
        prevRefreshQueued = false
        local brf = AuctionHouseFrame and AuctionHouseFrame.BrowseResultsFrame
        if prevBoughtActive and brf and brf.UpdateBrowseResults then
            Debug("Previously bought: results received, refreshing list")
            brf:UpdateBrowseResults()
        end
    end)
end

function handlers.BROWSE_RESULTS_UPDATED() QueuePrevBoughtRefresh() end
function handlers.BROWSE_RESULTS_ADDED() QueuePrevBoughtRefresh() end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)
for event in pairs(handlers) do
    -- unknown events raise an error, so register them via pcall
    if not pcall(events.RegisterEvent, events, event) then
        unknownEvents[#unknownEvents + 1] = event
    end
end

---------------------------------------------------------------------------
-- Slash command and debug
---------------------------------------------------------------------------

local debugFrame = CreateFrame("Frame")
debugFrame:SetScript("OnEvent", function(_, event, ...)
    if event:find("AUCTION") or event:find("COMMODITY") or event:find("BID") or event:find("ITEM_SEARCH") then
        Print("|cff88ccff" .. event .. "|r", ...)
    end
end)

SLASH_AHHISTORY1 = "/ahhistory"
SlashCmdList.AHHISTORY = function(msg)
    msg = (msg or ""):lower()
    if msg == "color" then
        OpenColorPicker()
    elseif msg == "tabcheck" then
        if not ui or not ui.tab or not AuctionHouseFrame:IsShown() then
            Print("Open the Auction House first.")
        else
            local buttons = FindTabRowButtons()
            local names = {}
            for _, b in ipairs(buttons) do
                names[#names + 1] = ("%s (%.0f)"):format(tostring(b:GetName() or b:GetText() or "unnamed"),
                    b:GetRight() or 0)
            end
            Print(("tab row: %d buttons"):format(#buttons))
            Print(#names > 0 and table.concat(names, ", ") or "none")
            Print(("history tab right edge: %.0f, frame right edge: %.0f")
                :format(ui.tab:GetRight() or 0, AuctionHouseFrame:GetRight() or 0))
        end
    elseif msg == "catcheck" then
        local cl = AuctionHouseFrame and AuctionHouseFrame.CategoriesList
        Print("list:", tostring(cl ~= nil), "scrollbox:", tostring(prevCatBox ~= nil),
            "update method:", tostring(prevCatBox and prevCatBox.Update ~= nil),
            "foreach:", tostring(prevCatBox and prevCatBox.ForEachFrame ~= nil),
            "tree open:", tostring(prevTreeOpen), "click hook:", tostring(catClickHookOk),
            "favorites hook:", tostring(favoritesHookOk))
        if cl then
            local methods = {}
            for _, name in ipairs({ "SetSelectedCategory", "OnFilterClicked", "OnCategoryClicked",
                                    "SelectCategory", "SetCategory", "GetSelectedCategory" }) do
                if cl[name] then methods[#methods + 1] = name end
            end
            Print("list methods:", #methods > 0 and table.concat(methods, ", ") or "none found")
        end
        if prevCatBox and prevCatBox.ForEachFrame then
            local n, clickable = 0, 0
            local sample
            prevCatBox:ForEachFrame(function(frame)
                n = n + 1
                if frame.HasScript and frame:HasScript("OnClick") then clickable = clickable + 1 end
                if not sample then
                    local kids = {}
                    for _, child in ipairs({ frame:GetChildren() }) do
                        kids[#kids + 1] = child:GetObjectType() .. ((child.HasScript and child:HasScript("OnClick")) and "*" or "")
                    end
                    sample = ("%s, children: %s"):format(frame:GetObjectType(),
                        #kids > 0 and table.concat(kids, " ") or "none")
                end
            end)
            Print(("frames %d, clickable %d"):format(n, clickable))
            Print("first frame:", sample or "none")
        end
        local brf = AuctionHouseFrame and AuctionHouseFrame.BrowseResultsFrame
        local box = brf and brf.ItemList and brf.ItemList.ScrollBox
        Print("hook:", tostring(buyTabTintOk), "scrollbox:", tostring(box ~= nil),
            "results:", brf and brf.browseResults and #brf.browseResults or "nil")
        Print("option:", tostring(db.options.buyTabHighlight), "update method:", tostring(box and box.Update ~= nil))
        if box and box.ForEachFrame then
            RefreshBuyTabTint()   -- tint once directly, then count
            local rows, found, known, shown = 0, 0, 0, 0
            local sample, knownFrame
            box:ForEachFrame(function(frame, elementData)
                rows = rows + 1
                sample = sample or type(elementData)
                local entry = GetBrowseEntry(frame, elementData)
                if entry then found = found + 1 end
                if entry and IsKnownItemKey(entry.itemKey) then
                    known = known + 1
                    knownFrame = knownFrame or frame
                end
                if frame.ahhTint and frame.ahhTint:IsShown() then shown = shown + 1 end
            end)
            Print(("rows %d, data found %d, known %d, tinted %d, elementData type %s")
                :format(rows, found, known, shown, tostring(sample)))
            if knownFrame then
                local t = knownFrame.ahhTint
                Print(("known row: %s, size %.0fx%.0f, level %d, strata %s, visible %s")
                    :format(knownFrame:GetObjectType(), knownFrame:GetWidth(), knownFrame:GetHeight(),
                    knownFrame:GetFrameLevel(), knownFrame:GetFrameStrata(), tostring(knownFrame:IsVisible())))
                if t then
                    local r, g, b, a = t:GetVertexColor()
                    Print(("tint: level %d, visible %s, alpha %.2f, color alpha %.2f")
                        :format(knownFrame.ahhTintFrame:GetFrameLevel(), tostring(t:IsVisible()),
                        t:GetAlpha(), db.options.buyTabColor.a or -1))
                else
                    Print("tint: not created")
                end
            end
        end
    elseif msg == "options" or msg == "config" then
        if settingsCategory then Settings.OpenToCategory(settingsCategory:GetID()) end
    elseif msg == "debug" then
        debugMode = not debugMode
        if debugMode then
            debugFrame:RegisterAllEvents()
            Print("Debug on.")
            if #unknownEvents > 0 then
                Print("Unavailable events:", table.concat(unknownEvents, ", "))
            end
            if ui and not buyTabHookOk then
                Print("Buy tab grouping is not available in this client version.")
            end
            if ui and not buyTabTintOk then
                Print("Buy tab highlight is not available in this client version.")
            end
        else
            debugFrame:UnregisterAllEvents()
            Print("Debug off.")
        end
    else
        local n = 0
        for _ in pairs(db.entries) do n = n + 1 end
        Print(("%d items in list. Commands: /ahhistory options, /ahhistory debug"):format(n))
    end
end
