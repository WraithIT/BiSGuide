----------------------------------------------------------------------
-- BiSGuide - Loot Tracker
-- Uses WoW Encounter Journal API for complete, localized loot data.
-- Sidebar layout: Raid/Dungeon tabs, instance nav, boss/loot rows.
----------------------------------------------------------------------

local addonName, ns = ...

local TRACKER_WIDTH  = 500
local SIDEBAR_W      = 135
local HEADER_H       = 70
local TAB_H          = 26
local INST_BTN_H     = 26
local BOSS_ROW_H     = 26
local ITEM_ROW_H     = 22

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local selectedTab      = "raid"
local selectedInstIdx  = 1
local filteredList     = {}
local filterArmor      = true

-- EJ-discovered season data: {name, instanceType, ejID, bosses={...}}
local ejInstances = {}
local ejReady     = false

----------------------------------------------------------------------
-- Armor types
----------------------------------------------------------------------

local CLASS_ARMOR = {
    DEATHKNIGHT="Plate", PALADIN="Plate", WARRIOR="Plate",
    EVOKER="Mail", HUNTER="Mail", SHAMAN="Mail",
    DEMONHUNTER="Leather", DRUID="Leather", MONK="Leather", ROGUE="Leather",
    MAGE="Cloth", PRIEST="Cloth", WARLOCK="Cloth",
}

local ARMOR_LABELS = { Plate="Plate", Mail="Mail", Leather="Leather", Cloth="Cloth" }

----------------------------------------------------------------------
-- EJ Discovery — build season instance list at runtime
----------------------------------------------------------------------

local function DiscoverEJ()
    ejInstances = {}

    -- 1) Raids from current tier
    local currentTier = EJ_GetCurrentTier()
    if not currentTier then return end
    EJ_SelectTier(currentTier)

    local ri = 1
    while true do
        local id, name = EJ_GetInstanceByIndex(ri, true)
        if not id then break end

        EJ_SelectInstance(id)
        EJ_SetDifficulty(16) -- Mythic raid

        local bosses = {}
        local ei = 1
        while true do
            local eName, _, encounterID = EJ_GetEncounterInfoByIndex(ei)
            if not eName then break end
            bosses[#bosses + 1] = {name = eName, id = encounterID}
            ei = ei + 1
        end

        ejInstances[#ejInstances + 1] = {
            name = name,
            instanceType = "raid",
            ejID = id,
            bosses = bosses,
        }
        ri = ri + 1
    end

    -- 2) M+ dungeons from C_ChallengeMode rotation
    local cmMaps = C_ChallengeMode and C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapTable()
    if not cmMaps or #cmMaps == 0 then
        -- Fallback: current tier dungeons
        local di = 1
        while true do
            local id, name = EJ_GetInstanceByIndex(di, false)
            if not id then break end
            EJ_SelectInstance(id)
            EJ_SetDifficulty(23) -- Mythic dungeon
            local bosses = {}
            local ei = 1
            while true do
                local eName, _, encounterID = EJ_GetEncounterInfoByIndex(ei)
                if not eName then break end
                bosses[#bosses + 1] = {name = eName, id = encounterID}
                ei = ei + 1
            end
            ejInstances[#ejInstances + 1] = {
                name = name,
                instanceType = "dungeon",
                ejID = id,
                bosses = bosses,
            }
            di = di + 1
        end
        ejReady = true
        return
    end

    -- Build CM name set (localized)
    local cmNames = {}
    for _, cmID in ipairs(cmMaps) do
        local cmName = C_ChallengeMode.GetMapUIInfo(cmID)
        if cmName then cmNames[cmName] = true end
    end

    -- Search ALL EJ tiers for matching dungeon names
    local numTiers = EJ_GetNumTiers()
    local found = {}
    for t = 1, numTiers do
        EJ_SelectTier(t)
        local di = 1
        while true do
            local id, name = EJ_GetInstanceByIndex(di, false)
            if not id then break end
            if cmNames[name] and not found[name] then
                found[name] = true
                EJ_SelectInstance(id)
                EJ_SetDifficulty(23)
                local bosses = {}
                local ei = 1
                while true do
                    local eName, _, encounterID = EJ_GetEncounterInfoByIndex(ei)
                    if not eName then break end
                    bosses[#bosses + 1] = {name = eName, id = encounterID}
                    ei = ei + 1
                end
                ejInstances[#ejInstances + 1] = {
                    name = name,
                    instanceType = "dungeon",
                    ejID = id,
                    bosses = bosses,
                }
            end
            di = di + 1
        end
    end

    ejReady = true
end

----------------------------------------------------------------------
-- EJ Loot retrieval
----------------------------------------------------------------------

local function SetLootFilter()
    if filterArmor then
        local _, _, classID = UnitClass("player")
        local specIndex = GetSpecialization()
        local specID = specIndex and GetSpecializationInfo(specIndex)
        if classID and specID then
            EJ_SetLootFilter(classID, specID)
        end
    else
        EJ_ResetLootFilter()
    end
end

-- Resolve item name: try EJ info, then link, then GetItemInfo, then request
local function ResolveItemName(info)
    -- 1) EJ already has name
    if info.name and info.name ~= "" then return info.name end
    -- 2) Extract from item link
    if info.link then
        local n = info.link:match("%[(.-)%]")
        if n then return n end
    end
    -- 3) Try GetItemInfo (returns cached or nil + triggers server request)
    local n = GetItemInfo(info.itemID)
    if n then return n end
    -- 4) Request async load
    if C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(info.itemID)
    end
    return nil  -- still loading
end

-- Get loot for a single encounter (raid boss)
local function GetEncounterLoot(ejInstanceID, ejEncounterID)
    EJ_SelectInstance(ejInstanceID)
    EJ_SelectEncounter(ejEncounterID)
    SetLootFilter()

    local items = {}
    local num = EJ_GetNumLoot()
    for i = 1, num do
        local info = C_EncounterJournal.GetLootInfoByIndex(i)
        if info and info.itemID then
            local name = ResolveItemName(info)
            items[#items + 1] = {
                name = name or ("Loading..."),
                itemId = info.itemID,
                icon = info.icon,
                slot = info.slot or "",
                armorType = info.armorType,
                link = info.link,
                quality = info.itemQuality,
                loaded = (name ~= nil),
            }
        end
    end
    return items
end

-- Get all loot for an instance (dungeon — aggregates all encounters)
local function GetInstanceLoot(ejInstanceID, bosses)
    local items, seen = {}, {}
    for _, boss in ipairs(bosses) do
        local bossLoot = GetEncounterLoot(ejInstanceID, boss.id)
        for _, item in ipairs(bossLoot) do
            if not seen[item.itemId] then
                seen[item.itemId] = true
                items[#items + 1] = item
            end
        end
    end
    return items
end

-- Pre-cache all loot for an instance (triggers server item requests)
local function PreCacheLoot(ejInstanceID, bosses)
    for _, boss in ipairs(bosses) do
        EJ_SelectInstance(ejInstanceID)
        EJ_SelectEncounter(boss.id)
        EJ_ResetLootFilter()  -- no filter = all items = more to cache
        local num = EJ_GetNumLoot()
        for i = 1, num do
            local info = C_EncounterJournal.GetLootInfoByIndex(i)
            if info and info.itemID then
                GetItemInfo(info.itemID)  -- trigger cache
            end
        end
    end
end

----------------------------------------------------------------------
-- Tracked data (keys: ejInstanceID + ejEncounterID or 0)
----------------------------------------------------------------------

local function EnsureTable(instID, key)
    if not BiSGuideDB.trackedLoot then BiSGuideDB.trackedLoot = {} end
    local k = tostring(instID)
    if not BiSGuideDB.trackedLoot[k] then BiSGuideDB.trackedLoot[k] = {} end
    local bk = tostring(key)
    if not BiSGuideDB.trackedLoot[k][bk] then BiSGuideDB.trackedLoot[k][bk] = {} end
end

local function GetTracked(instID, key)
    local d = BiSGuideDB and BiSGuideDB.trackedLoot
    local k, bk = tostring(instID), tostring(key)
    return d and d[k] and d[k][bk]
end

local function AddTracked(instID, key, name, itemId)
    EnsureTable(instID, key)
    table.insert(BiSGuideDB.trackedLoot[tostring(instID)][tostring(key)], {
        name = name, itemId = itemId, obtained = false,
    })
end

local function RemoveTracked(instID, key, idx)
    local t = GetTracked(instID, key)
    if t then table.remove(t, idx) end
end

local function ToggleObtained(instID, key, idx)
    local t = GetTracked(instID, key)
    if t and t[idx] then t[idx].obtained = not t[idx].obtained end
end

local function CountTracked(instID, key)
    local t = GetTracked(instID, key)
    if not t then return 0, 0 end
    local total, got = #t, 0
    for _, v in ipairs(t) do if v.obtained then got = got + 1 end end
    return total, got
end

local function IsAlreadyTracked(instID, key, itemId)
    local t = GetTracked(instID, key)
    if not t or not itemId then return false end
    for _, v in ipairs(t) do if v.itemId == itemId then return true end end
    return false
end

----------------------------------------------------------------------
-- Main panel
----------------------------------------------------------------------

local tracker = CreateFrame("Frame", "BiSGuideLootTracker", UIParent, "BackdropTemplate")
tracker:SetSize(TRACKER_WIDTH, 550)
tracker:SetPoint("CENTER")
tracker:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 16,
    insets = {left = 4, right = 4, top = 4, bottom = 4},
})
tracker:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
tracker:SetFrameStrata("HIGH")
tracker:EnableMouse(true)
tracker:SetMovable(true)
tracker:RegisterForDrag("LeftButton")
tracker:SetScript("OnDragStart", tracker.StartMoving)
tracker:SetScript("OnDragStop", tracker.StopMovingOrSizing)
tracker:SetClampedToScreen(true)
tracker:Hide()
ns.lootTracker = tracker

local titleText = tracker:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
titleText:SetPoint("TOP", 0, -10)
titleText:SetText("Loot Tracker")
titleText:SetTextColor(1, 0.82, 0)

local seasonText = tracker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
seasonText:SetPoint("TOP", titleText, "BOTTOM", 0, -2)
seasonText:SetTextColor(0.6, 0.6, 0.6)

local closeBtn = CreateFrame("Button", nil, tracker, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -2, -2)
closeBtn:SetScript("OnClick", function() tracker:Hide() end)

----------------------------------------------------------------------
-- Tabs: Raid / Dungeon
----------------------------------------------------------------------

local function MakeTab(label, value, anchorTo)
    local tab = CreateFrame("Button", nil, tracker, "BackdropTemplate")
    tab:SetSize(90, TAB_H)
    tab:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
    })
    tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tab.label:SetPoint("CENTER")
    tab.label:SetText(label)
    tab.value = value
    if anchorTo then
        tab:SetPoint("LEFT", anchorTo, "RIGHT", 4, 0)
    else
        tab:SetPoint("TOPLEFT", tracker, "TOPLEFT", 12, -38)
    end
    return tab
end

local tabRaid    = MakeTab("Raid", "raid")
local tabDungeon = MakeTab("Dungeon", "dungeon", tabRaid)

local function UpdateTabColors()
    for _, tab in ipairs({tabRaid, tabDungeon}) do
        if tab.value == selectedTab then
            tab:SetBackdropColor(0, 0.6, 0.9, 0.9)
            tab:SetBackdropBorderColor(0, 0.8, 1, 1)
            tab.label:SetTextColor(1, 1, 1)
        else
            tab:SetBackdropColor(0.15, 0.15, 0.2, 0.8)
            tab:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
            tab.label:SetTextColor(0.6, 0.6, 0.6)
        end
    end
end

----------------------------------------------------------------------
-- Armor filter toggle
----------------------------------------------------------------------

local armorBtn = CreateFrame("Button", nil, tracker, "BackdropTemplate")
armorBtn:SetSize(70, TAB_H)
armorBtn:SetPoint("LEFT", tabDungeon, "RIGHT", 12, 0)
armorBtn:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
})
armorBtn.label = armorBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
armorBtn.label:SetPoint("CENTER")

local selectPopup  -- forward declaration

local function UpdateArmorBtn()
    local pc = ns:GetPlayerClass()
    local at = pc and CLASS_ARMOR[pc] or "All"
    if filterArmor then
        armorBtn.label:SetText(at)
        armorBtn:SetBackdropColor(0.5, 0.35, 0.1, 0.9)
        armorBtn:SetBackdropBorderColor(0.8, 0.6, 0.2, 1)
        armorBtn.label:SetTextColor(1, 0.9, 0.6)
    else
        armorBtn.label:SetText("All")
        armorBtn:SetBackdropColor(0.15, 0.15, 0.2, 0.8)
        armorBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
        armorBtn.label:SetTextColor(0.6, 0.6, 0.6)
    end
end

armorBtn:SetScript("OnClick", function()
    filterArmor = not filterArmor
    UpdateArmorBtn()
    if selectPopup then selectPopup:Hide() end
end)
armorBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(filterArmor and "Filtered by your class" or "Showing all items")
    GameTooltip:AddLine("Click to toggle", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
armorBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

----------------------------------------------------------------------
-- Sidebar
----------------------------------------------------------------------

local sidebar = CreateFrame("Frame", nil, tracker, "BackdropTemplate")
sidebar:SetPoint("TOPLEFT", tracker, "TOPLEFT", 8, -HEADER_H)
sidebar:SetPoint("BOTTOMLEFT", tracker, "BOTTOMLEFT", 8, 8)
sidebar:SetWidth(SIDEBAR_W)
sidebar:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8x8"})
sidebar:SetBackdropColor(0.06, 0.06, 0.09, 0.6)

local MAX_SIDEBAR = 10
local sidebarBtns = {}
for i = 1, MAX_SIDEBAR do
    local btn = CreateFrame("Button", nil, sidebar, "BackdropTemplate")
    btn:SetSize(SIDEBAR_W, INST_BTN_H)
    btn:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, -((i-1)*(INST_BTN_H+1)))
    btn:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8x8"})
    btn:SetBackdropColor(0.1, 0.1, 0.15, 0.7)
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.text:SetPoint("LEFT", 6, 0); btn.text:SetPoint("RIGHT", -36, 0)
    btn.text:SetJustifyH("LEFT"); btn.text:SetWordWrap(false)
    btn.text:SetTextColor(0.75, 0.75, 0.75)
    btn.count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.count:SetPoint("RIGHT", -4, 0)
    btn.count:SetJustifyH("RIGHT")
    btn:SetScript("OnEnter", function(s)
        if not s.isSelected then s:SetBackdropColor(0.18,0.18,0.28,0.8) end
        GameTooltip:SetOwner(s,"ANCHOR_RIGHT"); GameTooltip:SetText(s.fullName or ""); GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(s)
        if not s.isSelected then s:SetBackdropColor(0.1,0.1,0.15,0.7) end
        GameTooltip:Hide()
    end)
    btn:Hide()
    sidebarBtns[i] = btn
end

----------------------------------------------------------------------
-- Content scroll
----------------------------------------------------------------------

local contentScroll = CreateFrame("ScrollFrame", "BiSGuideLTScroll", tracker, "UIPanelScrollFrameTemplate")
contentScroll:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 6, 0)
contentScroll:SetPoint("BOTTOMRIGHT", tracker, "BOTTOMRIGHT", -28, 8)
local contentChild = CreateFrame("Frame", nil, contentScroll)
contentChild:SetWidth(TRACKER_WIDTH - SIDEBAR_W - 50)
contentChild:SetHeight(1)
contentScroll:SetScrollChild(contentChild)
local contentW = TRACKER_WIDTH - SIDEBAR_W - 50

----------------------------------------------------------------------
-- Row pool
----------------------------------------------------------------------

local rowPool = {}
local function MakeRow(idx)
    local r = CreateFrame("Frame", nil, contentChild, "BackdropTemplate")
    r:SetSize(contentW, BOSS_ROW_H)
    r:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8x8"})
    r:EnableMouse(true)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.text:SetJustifyH("LEFT"); r.text:SetWordWrap(false)
    r.badge = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.badge:SetPoint("RIGHT", r, "RIGHT", -30, 0)
    -- + btn
    r.addBtn = CreateFrame("Button", nil, r, "BackdropTemplate")
    r.addBtn:SetSize(20, 18)
    r.addBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
    r.addBtn:SetBackdropColor(0.15,0.4,0.15,0.8); r.addBtn:SetBackdropBorderColor(0.3,0.6,0.3,1)
    r.addBtn.tx = r.addBtn:CreateFontString(nil,"OVERLAY","GameFontNormal")
    r.addBtn.tx:SetPoint("CENTER",0,1); r.addBtn.tx:SetText("+"); r.addBtn.tx:SetTextColor(0.4,1,0.4)
    r.addBtn:SetScript("OnEnter", function(s) s:SetBackdropColor(0.2,0.6,0.2,0.9) end)
    r.addBtn:SetScript("OnLeave", function(s) s:SetBackdropColor(0.15,0.4,0.15,0.8) end)
    r.addBtn:Hide()
    -- X btn
    r.removeBtn = CreateFrame("Button", nil, r)
    r.removeBtn:SetSize(16,16); r.removeBtn:SetPoint("RIGHT",r,"RIGHT",-6,0)
    r.removeBtn.tx = r.removeBtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    r.removeBtn.tx:SetPoint("CENTER"); r.removeBtn.tx:SetText("|cffff4444X|r")
    r.removeBtn:SetScript("OnEnter", function(s) s.tx:SetText("|cffff0000X|r")
        GameTooltip:SetOwner(s,"ANCHOR_RIGHT"); GameTooltip:SetText("Remove"); GameTooltip:Show() end)
    r.removeBtn:SetScript("OnLeave", function(s) s.tx:SetText("|cffff4444X|r"); GameTooltip:Hide() end)
    r.removeBtn:Hide()
    -- checkbox
    r.cb = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
    r.cb:SetSize(20,20); r.cb:Hide()
    rowPool[idx] = r; return r
end
local function GetRow(i) return rowPool[i] or MakeRow(i) end
local function ResetRow(r)
    r.addBtn:Hide(); r.removeBtn:Hide(); r.cb:Hide()
    r.badge:SetText(""); r.badge:Show()
    r.text:SetFontObject("GameFontNormal"); r.text:SetTextColor(1,1,1)
    r:SetScript("OnMouseDown",nil); r:SetScript("OnEnter",nil); r:SetScript("OnLeave",nil)
end

----------------------------------------------------------------------
-- Selection popup (shows EJ loot)
----------------------------------------------------------------------

selectPopup = CreateFrame("Frame", "BiSGuideLTSelectPopup", UIParent, "BackdropTemplate")
selectPopup:SetBackdrop({
    bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=1,
})
selectPopup:SetBackdropColor(0.1,0.1,0.15,0.98)
selectPopup:SetBackdropBorderColor(0.4,0.4,0.5,1)
selectPopup:SetFrameStrata("FULLSCREEN_DIALOG")
selectPopup:EnableMouse(true); selectPopup:Hide()

local SEL_H = 20
local MAX_SEL = 30
local selBtns = {}
for i = 1, MAX_SEL do
    local b = CreateFrame("Button", nil, selectPopup)
    b:SetHeight(SEL_H)
    b:SetNormalFontObject("GameFontNormalSmall")
    b:SetHighlightFontObject("GameFontHighlightSmall")
    local hl = b:CreateTexture(nil,"HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(0.2,0.4,0.7,0.4)
    b.slotLabel = b:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    b.slotLabel:SetPoint("RIGHT",b,"RIGHT",-6,0); b.slotLabel:SetTextColor(0.5,0.5,0.5)
    b:Hide(); selBtns[i] = b
end

-- Manual entry dialog (fallback)
local manualDlg = CreateFrame("Frame", "BiSGuideLTManual", UIParent, "BackdropTemplate")
manualDlg:SetSize(320,120); manualDlg:SetPoint("CENTER")
manualDlg:SetBackdrop({
    bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
    tile=true, tileSize=32, edgeSize=16, insets={left=4,right=4,top=4,bottom=4},
})
manualDlg:SetBackdropColor(0.1,0.1,0.15,0.98)
manualDlg:SetFrameStrata("FULLSCREEN_DIALOG"); manualDlg:EnableMouse(true); manualDlg:Hide()

local mdTitle = manualDlg:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
mdTitle:SetPoint("TOP",0,-14); mdTitle:SetText("Track Item"); mdTitle:SetTextColor(1,0.82,0)
local mdSub = manualDlg:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
mdSub:SetPoint("TOP",mdTitle,"BOTTOM",0,-2); mdSub:SetTextColor(0.7,0.7,0.7)

local mdEdit = CreateFrame("EditBox","BiSGuideLTEdit",manualDlg,"BackdropTemplate")
mdEdit:SetSize(280,26); mdEdit:SetPoint("TOP",mdSub,"BOTTOM",0,-10)
mdEdit:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
mdEdit:SetBackdropColor(0.05,0.05,0.08,1); mdEdit:SetBackdropBorderColor(0.4,0.4,0.5,1)
mdEdit:SetFontObject("GameFontHighlight"); mdEdit:SetAutoFocus(false)
mdEdit:SetMaxLetters(200); mdEdit:SetTextInsets(6,6,0,0)

local mdSave = CreateFrame("Button",nil,manualDlg,"UIPanelButtonTemplate")
mdSave:SetSize(90,24); mdSave:SetPoint("BOTTOMRIGHT",manualDlg,"BOTTOM",-6,12); mdSave:SetText("Add")
local mdCancel = CreateFrame("Button",nil,manualDlg,"UIPanelButtonTemplate")
mdCancel:SetSize(90,24); mdCancel:SetPoint("BOTTOMLEFT",manualDlg,"BOTTOM",6,12); mdCancel:SetText("Cancel")

local mdInstID, mdKey

mdCancel:SetScript("OnClick", function() manualDlg:Hide() end)
mdEdit:SetScript("OnEscapePressed", function() manualDlg:Hide() end)
mdEdit:SetScript("OnEnterPressed", function() mdSave:Click() end)

mdSave:SetScript("OnClick", function()
    local text = mdEdit:GetText()
    if not text or text:trim() == "" then return end
    local id = text:match("|Hitem:(%d+)")
    local nm = text:match("|h%[(.-)%]|h")
    if id and nm then
        AddTracked(mdInstID, mdKey, nm, tonumber(id))
    else
        local n = tonumber(text:trim())
        if n then
            local iname = GetItemInfo(n)
            AddTracked(mdInstID, mdKey, iname or ("Item #"..n), n)
        else
            AddTracked(mdInstID, mdKey, text:trim(), nil)
        end
    end
    manualDlg:Hide()
    UpdateSidebar(); ns:UpdateLootTrackerContent()
end)

manualDlg:SetScript("OnHide", function() mdEdit:SetText(""); mdEdit:ClearFocus() end)

local origInsertLink = ChatEdit_InsertLink
ChatEdit_InsertLink = function(text, ...)
    if mdEdit:IsVisible() and mdEdit:HasFocus() then mdEdit:Insert(text); return true end
    if origInsertLink then return origInsertLink(text, ...) end
end

----------------------------------------------------------------------
-- Show selection popup with EJ loot
----------------------------------------------------------------------

-- Stored popup params for retry
local lastPopupParams = {}

local function ShowSelectPopup(anchorBtn, ejInstID, trackKey, instance, ejEncounterID)
    selectPopup:Hide()

    -- Store params for retry
    lastPopupParams = {anchorBtn, ejInstID, trackKey, instance, ejEncounterID}

    -- Get loot from EJ
    local lootItems
    if ejEncounterID then
        lootItems = GetEncounterLoot(ejInstID, ejEncounterID)
    else
        lootItems = GetInstanceLoot(ejInstID, instance.bosses)
    end

    -- Remove already tracked
    local final = {}
    local hasUnloaded = false
    for _, item in ipairs(lootItems) do
        if not IsAlreadyTracked(ejInstID, trackKey, item.itemId) then
            final[#final + 1] = item
            if not item.loaded then hasUnloaded = true end
        end
    end

    -- If some items not loaded yet, retry after a short delay
    if hasUnloaded then
        C_Timer.After(0.5, function()
            if selectPopup:IsShown() or (anchorBtn and anchorBtn:IsVisible()) then
                ShowSelectPopup(anchorBtn, ejInstID, trackKey, instance, ejEncounterID)
            end
        end)
    end

    local count = math.min(#final, MAX_SEL - 1)
    local totalRows = count + 1

    local popupW = math.max(anchorBtn:GetParent():GetWidth(), 280)
    selectPopup:SetSize(popupW, totalRows * SEL_H + 4)
    selectPopup:ClearAllPoints()
    selectPopup:SetPoint("TOPLEFT", anchorBtn, "BOTTOMLEFT", -20, -1)

    for i = 1, MAX_SEL do
        if i <= count then
            local item = final[i]
            -- Use link for colored display, fall back to name
            local displayName = item.name or ("Loading...")
            if item.link then
                displayName = item.link:match("|c%x+|H.-|h(%[.-%])|h|r") or displayName
            end
            selBtns[i]:SetText(displayName)
            selBtns[i].slotLabel:SetText(item.slot or "")
            selBtns[i]:SetPoint("TOPLEFT", selectPopup, "TOPLEFT", 2, -(2+(i-1)*SEL_H))
            selBtns[i]:SetPoint("RIGHT", selectPopup, "RIGHT", -2, 0)

            local cItem = item
            local cInstID, cKey = ejInstID, trackKey
            selBtns[i]:SetScript("OnClick", function()
                AddTracked(cInstID, cKey, cItem.name or ("Item #"..cItem.itemId), cItem.itemId)
                selectPopup:Hide()
                UpdateSidebar(); ns:UpdateLootTrackerContent()
            end)
            selBtns[i]:SetScript("OnEnter", function(self)
                if cItem.link then
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    GameTooltip:SetHyperlink(cItem.link)
                    GameTooltip:Show()
                elseif cItem.itemId then
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    GameTooltip:SetHyperlink("item:" .. cItem.itemId)
                    GameTooltip:Show()
                end
            end)
            selBtns[i]:SetScript("OnLeave", function() GameTooltip:Hide() end)
            selBtns[i]:Show()
        elseif i == count + 1 then
            selBtns[i]:SetText("|cff888888Manual entry...|r")
            selBtns[i].slotLabel:SetText("")
            selBtns[i]:SetPoint("TOPLEFT", selectPopup, "TOPLEFT", 2, -(2+(i-1)*SEL_H))
            selBtns[i]:SetPoint("RIGHT", selectPopup, "RIGHT", -2, 0)
            selBtns[i]:SetScript("OnClick", function()
                selectPopup:Hide()
                mdInstID = ejInstID; mdKey = trackKey
                mdSub:SetText(instance.name)
                mdEdit:SetText(""); manualDlg:Show(); mdEdit:SetFocus()
            end)
            selBtns[i]:SetScript("OnEnter", nil); selBtns[i]:SetScript("OnLeave", nil)
            selBtns[i]:Show()
        else
            selBtns[i]:Hide()
        end
    end
    selectPopup:Show()
end

selectPopup:SetScript("OnKeyDown", function(s,k) if k=="ESCAPE" then s:Hide() end end)
selectPopup:SetScript("OnShow", function(s) s:SetPropagateKeyboardInput(false) end)

----------------------------------------------------------------------
-- Rebuild filtered list
----------------------------------------------------------------------

-- Count ALL tracked items for an instance (across all boss keys)
local function CountAllTracked(instID)
    local d = BiSGuideDB and BiSGuideDB.trackedLoot
    local k = tostring(instID)
    if not d or not d[k] then return 0, 0 end
    local total, got = 0, 0
    for _, items in pairs(d[k]) do
        for _, v in ipairs(items) do
            total = total + 1
            if v.obtained then got = got + 1 end
        end
    end
    return total, got
end

local function RebuildFiltered()
    filteredList = {}
    for _, inst in ipairs(ejInstances) do
        if inst.instanceType == selectedTab then
            filteredList[#filteredList + 1] = inst
        end
    end
    if selectedInstIdx > #filteredList then selectedInstIdx = 1 end
end

----------------------------------------------------------------------
-- Update sidebar
----------------------------------------------------------------------

local function UpdateSidebar()
    for i = 1, MAX_SIDEBAR do
        local btn = sidebarBtns[i]
        if i <= #filteredList then
            local inst = filteredList[i]
            btn.fullName = inst.name
            btn.text:SetText(inst.name)
            btn.isSelected = (i == selectedInstIdx)
            if btn.isSelected then
                btn:SetBackdropColor(0,0.5,0.8,0.8); btn.text:SetTextColor(1,1,1)
            else
                btn:SetBackdropColor(0.1,0.1,0.15,0.7); btn.text:SetTextColor(0.75,0.75,0.75)
            end

            -- Show tracked count
            local total, got = CountAllTracked(inst.ejID)
            if total > 0 then
                btn.count:SetText(got .. "/" .. total)
                if got == total then
                    btn.count:SetTextColor(0, 1, 0)
                else
                    btn.count:SetTextColor(1, 0.8, 0)
                end
            else
                btn.count:SetText("")
            end

            local ci = i
            btn:SetScript("OnClick", function()
                selectedInstIdx = ci; selectPopup:Hide(); UpdateSidebar(); UpdateSidebar(); ns:UpdateLootTrackerContent()
            end)
            btn:Show()
        else
            btn:Hide()
        end
    end
end

----------------------------------------------------------------------
-- Render tracked items helper
----------------------------------------------------------------------

local function RenderTracked(instID, trackKey, ri, yOff)
    local tracked = GetTracked(instID, trackKey)
    if not tracked then return ri, yOff end
    for ti, item in ipairs(tracked) do
        ri = ri + 1
        local ir = GetRow(ri); ResetRow(ir)
        ir:SetHeight(ITEM_ROW_H); ir:ClearAllPoints()
        ir:SetPoint("TOPLEFT", contentChild, "TOPLEFT", 0, -yOff)
        ir:SetSize(contentW, ITEM_ROW_H)

        local tI, tK, tIdx = instID, trackKey, ti
        ir.cb:ClearAllPoints(); ir.cb:SetPoint("LEFT", ir, "LEFT", 8, 0)
        ir.cb:SetChecked(item.obtained)
        ir.cb:SetScript("OnClick", function() ToggleObtained(tI,tK,tIdx); UpdateSidebar(); ns:UpdateLootTrackerContent() end)
        ir.cb:Show()

        ir.text:ClearAllPoints()
        ir.text:SetPoint("LEFT", ir.cb, "RIGHT", 2, 0)
        ir.text:SetPoint("RIGHT", ir, "RIGHT", -24, 0)
        ir.text:SetFontObject("GameFontNormalSmall")

        if item.obtained then
            ir.text:SetText("|cff00ff00"..item.name.."|r"); ir:SetBackdropColor(0.05,0.2,0.05,0.3)
        else
            ir.text:SetText(item.name); ir.text:SetTextColor(0.64,0.21,0.93) -- epic purple default
            ir:SetBackdropColor(0.08,0.08,0.12,0.3)
        end

        ir.removeBtn:ClearAllPoints(); ir.removeBtn:SetPoint("RIGHT", ir, "RIGHT", -6, 0)
        ir.removeBtn:SetScript("OnClick", function() RemoveTracked(tI,tK,tIdx); UpdateSidebar(); ns:UpdateLootTrackerContent() end)
        ir.removeBtn:Show()

        local cap = item
        ir:SetScript("OnEnter", function(s)
            if cap.itemId then
                GameTooltip:SetOwner(s,"ANCHOR_LEFT"); GameTooltip:SetHyperlink("item:"..cap.itemId); GameTooltip:Show()
            end
            if not cap.obtained then s:SetBackdropColor(0.15,0.15,0.25,0.5) end
        end)
        ir:SetScript("OnLeave", function(s)
            GameTooltip:Hide()
            s:SetBackdropColor(cap.obtained and 0.05 or 0.08, cap.obtained and 0.2 or 0.08, cap.obtained and 0.05 or 0.12, 0.3)
        end)
        ir:Show()
        yOff = yOff + ITEM_ROW_H + 1
    end
    return ri, yOff
end

----------------------------------------------------------------------
-- Render header row (boss or "Loot Table") with + button
----------------------------------------------------------------------

local function RenderHeader(ri, yOff, label, instID, trackKey, instance, ejEncounterID)
    ri = ri + 1
    local br = GetRow(ri); ResetRow(br)
    br:SetHeight(BOSS_ROW_H); br:ClearAllPoints()
    br:SetPoint("TOPLEFT", contentChild, "TOPLEFT", 0, -yOff)
    br:SetSize(contentW, BOSS_ROW_H)
    br:SetBackdropColor(0.14,0.14,0.2,0.7)

    br.text:ClearAllPoints()
    br.text:SetPoint("LEFT", br, "LEFT", 8, 0)
    br.text:SetPoint("RIGHT", br, "RIGHT", -70, 0)
    br.text:SetFontObject("GameFontNormal")
    br.text:SetText(label); br.text:SetTextColor(0.95,0.95,0.95)

    local total, got = CountTracked(instID, trackKey)
    if total > 0 then
        br.badge:SetText(got.."/"..total)
        br.badge:SetTextColor(got==total and 0 or 1, got==total and 1 or 0.8, got==total and 0 or 0)
    end

    local cInstID, cKey, cInst, cEID = instID, trackKey, instance, ejEncounterID
    br.addBtn:ClearAllPoints(); br.addBtn:SetPoint("RIGHT", br, "RIGHT", -6, 0)
    br.addBtn:SetScript("OnClick", function(self)
        if selectPopup:IsShown() then selectPopup:Hide()
        else ShowSelectPopup(self, cInstID, cKey, cInst, cEID) end
    end)
    br.addBtn:Show()

    br:SetScript("OnEnter", function(s) s:SetBackdropColor(0.2,0.2,0.3,0.8) end)
    br:SetScript("OnLeave", function(s) s:SetBackdropColor(0.14,0.14,0.2,0.7) end)
    br:Show()
    return ri, yOff + BOSS_ROW_H + 1
end

----------------------------------------------------------------------
-- Update content
----------------------------------------------------------------------

function UpdateSidebar(); ns:UpdateLootTrackerContent()
    local inst = filteredList[selectedInstIdx]
    if not inst then
        for i = 1, #rowPool do rowPool[i]:Hide() end
        contentChild:SetHeight(1); return
    end

    -- Pre-cache loot items so names are ready when user clicks "+"
    PreCacheLoot(inst.ejID, inst.bosses)

    local ri, yOff = 0, 0

    if inst.instanceType == "dungeon" then
        -- Dungeon: flat loot table, trackKey = 0
        ri, yOff = RenderHeader(ri, yOff, "Loot Table", inst.ejID, 0, inst, nil)
        ri, yOff = RenderTracked(inst.ejID, 0, ri, yOff)
    else
        -- Raid: per-boss
        for _, boss in ipairs(inst.bosses) do
            ri, yOff = RenderHeader(ri, yOff, boss.name, inst.ejID, boss.id, inst, boss.id)
            ri, yOff = RenderTracked(inst.ejID, boss.id, ri, yOff)
        end
    end

    for i = ri + 1, #rowPool do rowPool[i]:Hide() end
    contentChild:SetHeight(math.max(yOff, 1))
end

----------------------------------------------------------------------
-- Master update
----------------------------------------------------------------------

function ns:UpdateLootTracker()
    if not tracker:IsShown() then return end
    if not ejReady then DiscoverEJ() end
    seasonText:SetText(ns.SEASON_LABEL or "")
    UpdateTabColors()
    UpdateArmorBtn()
    RebuildFiltered()
    UpdateSidebar()
    self:UpdateLootTrackerContent()
end

----------------------------------------------------------------------
-- Tab click handlers
----------------------------------------------------------------------

for _, tab in ipairs({tabRaid, tabDungeon}) do
    tab:SetScript("OnClick", function(self)
        selectedTab = self.value; selectedInstIdx = 1
        selectPopup:Hide(); ns:UpdateLootTracker()
    end)
    tab:SetScript("OnEnter", function(s)
        if s.value ~= selectedTab then s:SetBackdropColor(0.2,0.5,0.7,0.6) end
    end)
    tab:SetScript("OnLeave", function(s)
        if s.value ~= selectedTab then s:SetBackdropColor(0.15,0.15,0.2,0.8) end
    end)
end

----------------------------------------------------------------------
-- Show / Hide / Toggle
----------------------------------------------------------------------

function ns:ShowLootTracker()
    tracker:ClearAllPoints()
    if ns.frame and ns.frame:IsShown() then
        tracker:SetPoint("TOPLEFT", ns.frame, "TOPRIGHT", 2, 0)
        tracker:SetHeight(ns.frame:GetHeight())
    else
        tracker:SetPoint("CENTER")
    end
    tracker:Show()
    ns:UpdateLootTracker()
end

function ns:HideLootTracker()
    tracker:Hide(); selectPopup:Hide(); manualDlg:Hide()
end

function ns:ToggleLootTracker()
    if tracker:IsShown() then ns:HideLootTracker() else ns:ShowLootTracker() end
end

----------------------------------------------------------------------
-- Init: discover EJ data after login
----------------------------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        -- Small delay to ensure EJ data is available
        C_Timer.After(1, function()
            DiscoverEJ()
        end)
    end
end)
