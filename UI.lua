----------------------------------------------------------------------
-- BiSGuide - UI
-- Side panel attached to CharacterFrame showing BiS gear
-- Includes class/spec dropdown for browsing any spec's BiS
----------------------------------------------------------------------

local addonName, ns = ...

local PANEL_WIDTH = 320
local ROW_HEIGHT = 40
local TAB_HEIGHT = 28
local HEADER_HEIGHT = 90  -- extra room for dropdowns

----------------------------------------------------------------------
-- Main panel frame
----------------------------------------------------------------------

local panel = CreateFrame("Frame", "BiSGuidePanel", UIParent, "BackdropTemplate")
panel:SetSize(PANEL_WIDTH, 520)
panel:SetPoint("TOPLEFT", CharacterFrame, "TOPRIGHT", -2, 0)
panel:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 16,
    insets = {left = 4, right = 4, top = 4, bottom = 4},
})
panel:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
panel:SetFrameStrata("HIGH")
panel:SetFrameLevel(CharacterFrame:GetFrameLevel() + 1)
panel:EnableMouse(true)
panel:SetMovable(false)
panel:Hide()

ns.frame = panel

----------------------------------------------------------------------
-- Title
----------------------------------------------------------------------

local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", panel, "TOP", 0, -12)
title:SetText("BiS Guide")
title:SetTextColor(0, 0.8, 1)

local specLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
specLabel:SetPoint("TOP", title, "BOTTOM", 0, -2)
specLabel:SetTextColor(0.8, 0.8, 0.8)

----------------------------------------------------------------------
-- Close button
----------------------------------------------------------------------

local closeBtn = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)
closeBtn:SetScript("OnClick", function() panel:Hide() end)

----------------------------------------------------------------------
-- Class / Spec dropdowns
----------------------------------------------------------------------

local selectedDropdownClass = nil  -- index into ns.ALL_CLASSES
local selectedDropdownSpec = nil   -- spec name string
local scrollFrame  -- forward declaration (created later, used in ApplySelection)

-- Dropdown button helper
local function CreateDropdownButton(parent, width)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width, 22)
    btn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(0.15, 0.15, 0.2, 0.9)
    btn:SetBackdropBorderColor(0.4, 0.4, 0.5, 1)

    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.text:SetPoint("LEFT", btn, "LEFT", 6, 0)
    btn.text:SetPoint("RIGHT", btn, "RIGHT", -16, 0)
    btn.text:SetJustifyH("LEFT")
    btn.text:SetTextColor(1, 1, 1)

    btn.arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.arrow:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
    btn.arrow:SetText("v")
    btn.arrow:SetTextColor(0.6, 0.6, 0.6)

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.25, 0.25, 0.35, 0.9)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.15, 0.15, 0.2, 0.9)
    end)

    return btn
end

-- Dropdown menu frame (reusable)
local menuFrame = CreateFrame("Frame", "BiSGuideDropdownMenu", UIParent, "BackdropTemplate")
menuFrame:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
menuFrame:SetBackdropColor(0.1, 0.1, 0.15, 0.98)
menuFrame:SetBackdropBorderColor(0.4, 0.4, 0.5, 1)
menuFrame:SetFrameStrata("DIALOG")
menuFrame:EnableMouse(true)
menuFrame:Hide()

local menuItems = {}
local menuCallbacks = {}  -- Store callbacks separately (not on frame)
local MAX_MENU_ITEMS = 20

for i = 1, MAX_MENU_ITEMS do
    local idx = i  -- Capture index in closure
    local item = CreateFrame("Button", nil, menuFrame)
    item:SetHeight(18)
    item:SetNormalFontObject("GameFontNormalSmall")
    item:SetHighlightFontObject("GameFontHighlightSmall")
    item:SetText("")

    local highlight = item:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(0.2, 0.4, 0.7, 0.4)

    item:SetScript("OnClick", function()
        local cb = menuCallbacks[idx]
        menuFrame:Hide()
        if cb then cb() end
    end)

    menuItems[i] = item
end

local function ShowMenu(anchorFrame, entries, onClick)
    local count = #entries
    if count > MAX_MENU_ITEMS then count = MAX_MENU_ITEMS end

    menuFrame:SetSize(anchorFrame:GetWidth(), count * 18 + 4)
    menuFrame:ClearAllPoints()
    menuFrame:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -1)

    for i = 1, MAX_MENU_ITEMS do
        if i <= count then
            menuItems[i]:SetText(entries[i].label)
            menuItems[i]:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 2, -(2 + (i-1) * 18))
            menuItems[i]:SetPoint("RIGHT", menuFrame, "RIGHT", -2, 0)
            menuCallbacks[i] = function() onClick(entries[i]) end

            if entries[i].selected then
                menuItems[i]:SetText("|cff00ccff" .. entries[i].label .. "|r")
            end

            menuItems[i]:Show()
        else
            menuItems[i]:Hide()
            menuCallbacks[i] = nil
        end
    end

    menuFrame:Show()
end

-- Close menu when clicking elsewhere
menuFrame:SetScript("OnShow", function()
    menuFrame:SetPropagateKeyboardInput(false)
end)
menuFrame:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then self:Hide() end
end)

-- Class dropdown
local classBtn = CreateDropdownButton(panel, 140)
classBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -42)
classBtn.text:SetText("Class")

-- Spec dropdown
local specBtn = CreateDropdownButton(panel, 140)
specBtn:SetPoint("LEFT", classBtn, "RIGHT", 6, 0)
specBtn.text:SetText("Spec")

local function UpdateSpecDropdown()
    if not selectedDropdownClass then
        specBtn.text:SetText("Spec")
        return
    end

    local classInfo = ns.ALL_CLASSES[selectedDropdownClass]
    if not classInfo then return end

    -- Auto-select first spec if none selected
    if not selectedDropdownSpec then
        selectedDropdownSpec = classInfo.specs[1]
    end

    specBtn.text:SetText(selectedDropdownSpec or "Spec")
end

local function ApplySelection()
    if selectedDropdownClass and selectedDropdownSpec then
        local classInfo = ns.ALL_CLASSES[selectedDropdownClass]
        ns:SetViewClassSpec(classInfo.file, selectedDropdownSpec)
    end
    -- Force scroll to top and refresh
    scrollFrame:SetVerticalScroll(0)
    ns:UpdateTabs()
    ns:UpdateUI()
end

-- Class dropdown click
classBtn:SetScript("OnClick", function(self)
    if menuFrame:IsShown() then
        menuFrame:Hide()
        return
    end

    local entries = {}
    -- "My Character" option to reset
    table.insert(entries, {
        label = "|cff00ff00< My Character >|r",
        value = 0,
        selected = not ns:IsCustomView(),
    })

    for i, classInfo in ipairs(ns.ALL_CLASSES) do
        local color = RAID_CLASS_COLORS[classInfo.file]
        local hex = color and color:GenerateHexColor() or "ffffffff"
        table.insert(entries, {
            label = "|c" .. hex .. classInfo.name .. "|r",
            value = i,
            selected = (i == selectedDropdownClass),
        })
    end

    ShowMenu(self, entries, function(entry)
        if entry.value == 0 then
            -- Reset to player
            selectedDropdownClass = nil
            selectedDropdownSpec = nil
            ns:ResetView()
            classBtn.text:SetText("|cff00ff00My Character|r")
            specBtn.text:SetText("")
            ns:UpdateUI()
        else
            selectedDropdownClass = entry.value
            local classInfo = ns.ALL_CLASSES[entry.value]
            local color = RAID_CLASS_COLORS[classInfo.file]
            local hex = color and color:GenerateHexColor() or "ffffffff"
            classBtn.text:SetText("|c" .. hex .. classInfo.name .. "|r")

            -- Auto-select first spec
            selectedDropdownSpec = classInfo.specs[1]
            UpdateSpecDropdown()
            ApplySelection()
        end
    end)
end)

-- Spec dropdown click
specBtn:SetScript("OnClick", function(self)
    if menuFrame:IsShown() then
        menuFrame:Hide()
        return
    end

    if not selectedDropdownClass then return end

    local classInfo = ns.ALL_CLASSES[selectedDropdownClass]
    if not classInfo then return end

    local entries = {}
    for _, specName in ipairs(classInfo.specs) do
        table.insert(entries, {
            label = specName,
            value = specName,
            selected = (specName == selectedDropdownSpec),
        })
    end

    ShowMenu(self, entries, function(entry)
        selectedDropdownSpec = entry.value
        specBtn.text:SetText(entry.value)
        ApplySelection()
    end)
end)

----------------------------------------------------------------------
-- Content type tabs
----------------------------------------------------------------------

local tabs = {}
local selectedContentType = "raid"

local function CreateTab(parent, label, contentType, anchorPoint, anchorTo)
    local tab = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tab:SetSize(90, TAB_HEIGHT)
    tab:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })

    tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tab.label:SetPoint("CENTER")
    tab.label:SetText(label)

    tab.contentType = contentType

    tab:SetScript("OnClick", function(self)
        selectedContentType = self.contentType
        BiSGuideDB.lastContentType = selectedContentType
        ns:UpdateTabs()
        ns:UpdateUI()
    end)

    tab:SetScript("OnEnter", function(self)
        if selectedContentType ~= self.contentType then
            self:SetBackdropColor(0.2, 0.5, 0.7, 0.6)
        end
    end)

    tab:SetScript("OnLeave", function(self)
        if selectedContentType ~= self.contentType then
            self:SetBackdropColor(0.15, 0.15, 0.2, 0.8)
        end
    end)

    if anchorTo then
        tab:SetPoint("LEFT", anchorTo, "RIGHT", 4, 0)
    else
        tab:SetPoint(anchorPoint, parent, anchorPoint, 12, -HEADER_HEIGHT)
    end

    return tab
end

tabs.raid = CreateTab(panel, "Raid", "raid", "TOPLEFT")
tabs.mythicplus = CreateTab(panel, "M+", "mythicplus", nil, tabs.raid)
tabs.pvp = CreateTab(panel, "PvP", "pvp", nil, tabs.mythicplus)

function ns:UpdateTabs()
    for key, tab in pairs(tabs) do
        if key == selectedContentType then
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
-- Scroll frame for gear list
----------------------------------------------------------------------

scrollFrame = CreateFrame("ScrollFrame", "BiSGuideScrollFrame", panel, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -(HEADER_HEIGHT + TAB_HEIGHT + 12))
scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 8)

local scrollChild = CreateFrame("Frame", nil, scrollFrame)
scrollChild:SetSize(PANEL_WIDTH - 40, 1)
scrollFrame:SetScrollChild(scrollChild)

----------------------------------------------------------------------
-- Item link builder (includes bonus IDs for correct ilvl)
----------------------------------------------------------------------

local function BuildItemLink(itemID, bonusStr)
    if not bonusStr or bonusStr == "" then
        return "item:" .. itemID
    end
    local bonuses = {}
    for b in bonusStr:gmatch("(%d+)") do
        bonuses[#bonuses + 1] = b
    end
    if #bonuses == 0 then
        return "item:" .. itemID
    end
    -- item:ID:enchant:gem1:gem2:gem3:gem4:suffix:unique:level:spec:modifiers:difficulty:numBonuses:b1:b2:...
    return "item:" .. itemID .. "::::::::::::" .. #bonuses .. ":" .. table.concat(bonuses, ":")
end

----------------------------------------------------------------------
-- Item row pool
----------------------------------------------------------------------

local rowPool = {}

local function GetRow(index)
    if rowPool[index] then return rowPool[index] end

    local row = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
    row:SetSize(PANEL_WIDTH - 44, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -((index - 1) * (ROW_HEIGHT + 2)))

    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })

    -- Slot label
    row.slotLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.slotLabel:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
    row.slotLabel:SetTextColor(0.6, 0.6, 0.6)
    row.slotLabel:SetWidth(70)
    row.slotLabel:SetJustifyH("LEFT")

    -- Item name
    row.itemName = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.itemName:SetPoint("TOPLEFT", row, "TOPLEFT", 80, -4)
    row.itemName:SetPoint("RIGHT", row, "RIGHT", -30, 0)
    row.itemName:SetJustifyH("LEFT")
    row.itemName:SetWordWrap(false)

    -- Source text
    row.source = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.source:SetPoint("TOPLEFT", row.itemName, "BOTTOMLEFT", 0, -2)
    row.source:SetPoint("RIGHT", row, "RIGHT", -30, 0)
    row.source:SetTextColor(0.5, 0.5, 0.5)
    row.source:SetJustifyH("LEFT")
    row.source:SetWordWrap(false)

    -- Status icon (equipped or not)
    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.status:SetPoint("RIGHT", row, "RIGHT", -8, 0)

    -- Tooltip on hover - full WoW item tooltip
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if self.itemID then
            -- If the BiS item is equipped in that slot, show the equipped tooltip
            local equipID = GetInventoryItemID("player", self.slotID or 0)
            if equipID and equipID == self.itemID then
                GameTooltip:SetInventoryItem("player", self.slotID)
            else
                -- Show item tooltip with bonus IDs for correct ilvl
                local link = BuildItemLink(self.itemID, self.itemBonus)
                GameTooltip:SetHyperlink(link)
            end
            -- Append source info
            if self.itemSource and self.itemSource ~= "" then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Source: " .. self.itemSource, 0.7, 0.7, 0.7)
            end
            if self.isEquipped then
                GameTooltip:AddLine("|cff00ff00Equipped|r")
            end
            GameTooltip:Show()
        end
        if not self.isEquipped then
            self:SetBackdropColor(0.2, 0.2, 0.3, 0.6)
        end
    end)
    row:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        self:UpdateBG()
    end)

    function row:UpdateBG()
        if self.isEquipped then
            self:SetBackdropColor(0.05, 0.3, 0.05, 0.4)
        elseif self.index and self.index % 2 == 0 then
            self:SetBackdropColor(0.12, 0.12, 0.18, 0.5)
        else
            self:SetBackdropColor(0.08, 0.08, 0.12, 0.3)
        end
    end

    rowPool[index] = row
    return row
end

----------------------------------------------------------------------
-- Update the gear list
----------------------------------------------------------------------

function ns:UpdateUI()
    local classFile = self:GetViewClass()
    local spec = self:GetViewSpec()

    -- Update spec label
    if ns:IsCustomView() then
        -- Viewing another class/spec
        local color = RAID_CLASS_COLORS[classFile]
        local hex = color and color:GenerateHexColor() or "ffffffff"
        specLabel:SetText("|c" .. hex .. spec .. "|r |cff888888(viewing)|r")
    else
        -- Viewing own spec
        local specLocalized = self:GetPlayerSpecLocalized()
        if classFile and specLocalized and specLocalized ~= "" then
            local color = RAID_CLASS_COLORS[classFile]
            local hex = color and color:GenerateHexColor() or "ffffffff"
            specLabel:SetText("|c" .. hex .. specLocalized .. " " .. (UnitClass("player")) .. "|r")
        else
            specLabel:SetText("No specialization")
        end
    end

    self:UpdateTabs()

    -- Get BiS data
    local bisList = self:GetBiSList(selectedContentType)

    -- Build a lookup: slot ID -> bis entry
    local bisLookup = {}
    if bisList then
        for _, entry in ipairs(bisList) do
            bisLookup[entry.slot] = entry
        end
    end

    -- Populate rows
    local rowIndex = 0
    for _, slotInfo in ipairs(ns.SLOTS) do
        rowIndex = rowIndex + 1
        local row = GetRow(rowIndex)
        row.index = rowIndex
        row:Show()

        row.slotLabel:SetText(slotInfo.label)

        local entry = bisLookup[slotInfo.id]
        if entry then
            -- Set item name with quality color
            local quality = entry.quality or 4
            local qColor = ns.QUALITY_COLORS[quality] or ns.QUALITY_COLORS[4]
            row.itemName:SetText(entry.name or "Unknown")
            row.itemName:SetTextColor(qColor[1], qColor[2], qColor[3])

            -- Source
            row.source:SetText(entry.source or "")

            -- Store data for tooltip
            row.itemID = entry.itemId
            row.itemBonus = entry.bonus or ""
            row.bisName = entry.name
            row.itemSource = entry.source
            row.itemQuality = quality
            row.itemIlvl = entry.ilvl
            row.slotID = slotInfo.id

            -- Check equipped (only relevant for own class)
            if not ns:IsCustomView() then
                row.isEquipped = ns:IsItemEquipped(slotInfo.id, entry.itemId)
            else
                row.isEquipped = false
            end

            if row.isEquipped then
                row.status:SetText("|cff00ff00E|r")
            else
                row.status:SetText("|cffff4444X|r")
            end
        else
            row.itemName:SetText("|cff666666No data|r")
            row.itemName:SetTextColor(0.4, 0.4, 0.4)
            row.source:SetText("")
            row.status:SetText("")
            row.itemID = nil
            row.itemBonus = nil
            row.bisName = nil
            row.itemSource = nil
            row.itemQuality = nil
            row.itemIlvl = nil
            row.slotID = nil
            row.isEquipped = false
        end

        row:UpdateBG()
    end

    -- Hide unused rows
    for i = rowIndex + 1, #rowPool do
        rowPool[i]:Hide()
    end

    -- Update scroll child height
    scrollChild:SetHeight(rowIndex * (ROW_HEIGHT + 2))
end

----------------------------------------------------------------------
-- Show / Hide / Toggle
----------------------------------------------------------------------

function ns:ShowPanel()
    panel:Show()
    self:UpdateUI()
end

function ns:HidePanel()
    panel:Hide()
    menuFrame:Hide()
end

function ns:TogglePanel()
    if panel:IsShown() then
        self:HidePanel()
    else
        self:ShowPanel()
    end
end

----------------------------------------------------------------------
-- Hook into CharacterFrame
----------------------------------------------------------------------

local function InitDropdownDefaults()
    -- Set dropdowns to player's current class/spec
    local playerClassFile = ns:GetPlayerClass()
    local playerSpec = ns:GetPlayerSpec()
    for i, classInfo in ipairs(ns.ALL_CLASSES) do
        if classInfo.file == playerClassFile then
            selectedDropdownClass = i
            classBtn.text:SetText("|cff00ff00My Character|r")
            specBtn.text:SetText(playerSpec or "")
            break
        end
    end
end

local function OnCharacterFrameShow()
    if BiSGuideDB and BiSGuideDB.lastContentType then
        selectedContentType = BiSGuideDB.lastContentType
    end
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", CharacterFrame, "TOPRIGHT", -2, 0)
    panel:SetHeight(CharacterFrame:GetHeight())

    -- Default to player's class/spec if no custom view
    if not ns:IsCustomView() then
        InitDropdownDefaults()
    end

    ns:ShowPanel()
end

local function OnCharacterFrameHide()
    ns:HidePanel()
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("PLAYER_LOGIN")
hookFrame:SetScript("OnEvent", function()
    if CharacterFrame then
        CharacterFrame:HookScript("OnShow", OnCharacterFrameShow)
        CharacterFrame:HookScript("OnHide", OnCharacterFrameHide)
    end
end)
