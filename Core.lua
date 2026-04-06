----------------------------------------------------------------------
-- BiSGuide - Core
-- Detects class/spec and provides data access for the UI
----------------------------------------------------------------------

local addonName, ns = ...

ns.SLOTS = {
    {id = 1,  slotName = "HeadSlot",          label = "Head"},
    {id = 2,  slotName = "NeckSlot",          label = "Neck"},
    {id = 3,  slotName = "ShoulderSlot",      label = "Shoulder"},
    {id = 5,  slotName = "ChestSlot",         label = "Chest"},
    {id = 6,  slotName = "WaistSlot",         label = "Waist"},
    {id = 7,  slotName = "LegsSlot",          label = "Legs"},
    {id = 8,  slotName = "FeetSlot",          label = "Feet"},
    {id = 9,  slotName = "WristSlot",         label = "Wrist"},
    {id = 10, slotName = "HandsSlot",         label = "Hands"},
    {id = 11, slotName = "Finger0Slot",       label = "Finger 1"},
    {id = 12, slotName = "Finger1Slot",       label = "Finger 2"},
    {id = 13, slotName = "Trinket0Slot",      label = "Trinket 1"},
    {id = 14, slotName = "Trinket1Slot",      label = "Trinket 2"},
    {id = 15, slotName = "BackSlot",          label = "Back"},
    {id = 16, slotName = "MainHandSlot",      label = "Main Hand"},
    {id = 17, slotName = "SecondaryHandSlot", label = "Off Hand"},
}

ns.CONTENT_TYPES = {"raid", "mythicplus", "pvp"}
ns.CONTENT_LABELS = {
    raid      = "Raid",
    mythicplus = "M+",
    pvp       = "PvP",
}

-- Quality colors (Blizzard standard)
ns.QUALITY_COLORS = {
    [0] = {0.62, 0.62, 0.62},  -- Poor (grey)
    [1] = {1.00, 1.00, 1.00},  -- Common (white)
    [2] = {0.12, 1.00, 0.00},  -- Uncommon (green)
    [3] = {0.00, 0.44, 0.87},  -- Rare (blue)
    [4] = {0.64, 0.21, 0.93},  -- Epic (purple)
    [5] = {1.00, 0.50, 0.00},  -- Legendary (orange)
}

----------------------------------------------------------------------
-- Player info
----------------------------------------------------------------------

-- SpecID → English name (locale-independent lookup for Data.lua)
local SPEC_ENGLISH = {
    -- Death Knight
    [250] = "Blood", [251] = "Frost", [252] = "Unholy",
    -- Demon Hunter
    [577] = "Havoc", [581] = "Vengeance", [1456] = "Devourer",
    -- Druid
    [102] = "Balance", [103] = "Feral", [104] = "Guardian", [105] = "Restoration",
    -- Evoker
    [1467] = "Devastation", [1468] = "Preservation", [1473] = "Augmentation",
    -- Hunter
    [253] = "Beast Mastery", [254] = "Marksmanship", [255] = "Survival",
    -- Mage
    [62] = "Arcane", [63] = "Fire", [64] = "Frost",
    -- Monk
    [268] = "Brewmaster", [270] = "Mistweaver", [269] = "Windwalker",
    -- Paladin
    [65] = "Holy", [66] = "Protection", [70] = "Retribution",
    -- Priest
    [256] = "Discipline", [257] = "Holy", [258] = "Shadow",
    -- Rogue
    [259] = "Assassination", [260] = "Outlaw", [261] = "Subtlety",
    -- Shaman
    [262] = "Elemental", [263] = "Enhancement", [264] = "Restoration",
    -- Warlock
    [265] = "Affliction", [266] = "Demonology", [267] = "Destruction",
    -- Warrior
    [71] = "Arms", [72] = "Fury", [73] = "Protection",
}

-- All classes and their specs (English names matching Data.lua keys)
ns.ALL_CLASSES = {
    {file = "DEATHKNIGHT",  name = "Death Knight",  specs = {"Blood", "Frost", "Unholy"}},
    {file = "DEMONHUNTER",  name = "Demon Hunter",  specs = {"Havoc", "Vengeance", "Devourer"}},
    {file = "DRUID",        name = "Druid",         specs = {"Balance", "Feral", "Guardian", "Restoration"}},
    {file = "EVOKER",       name = "Evoker",        specs = {"Devastation", "Preservation", "Augmentation"}},
    {file = "HUNTER",       name = "Hunter",        specs = {"Beast Mastery", "Marksmanship", "Survival"}},
    {file = "MAGE",         name = "Mage",          specs = {"Arcane", "Fire", "Frost"}},
    {file = "MONK",         name = "Monk",          specs = {"Brewmaster", "Mistweaver", "Windwalker"}},
    {file = "PALADIN",      name = "Paladin",       specs = {"Holy", "Protection", "Retribution"}},
    {file = "PRIEST",       name = "Priest",        specs = {"Discipline", "Holy", "Shadow"}},
    {file = "ROGUE",        name = "Rogue",         specs = {"Assassination", "Outlaw", "Subtlety"}},
    {file = "SHAMAN",       name = "Shaman",        specs = {"Elemental", "Enhancement", "Restoration"}},
    {file = "WARLOCK",      name = "Warlock",       specs = {"Affliction", "Demonology", "Destruction"}},
    {file = "WARRIOR",      name = "Warrior",       specs = {"Arms", "Fury", "Protection"}},
}

local playerClass, playerClassFile
local playerSpec = ""
local playerSpecLocalized = ""

-- Viewing state (overridden by dropdown, nil = use player's)
local viewClassFile = nil
local viewSpec = nil

function ns:GetPlayerClass()
    return playerClassFile
end

function ns:GetPlayerSpec()
    return playerSpec
end

function ns:GetPlayerSpecLocalized()
    return playerSpecLocalized
end

-- Get the currently viewed class/spec (dropdown override or player default)
function ns:GetViewClass()
    return viewClassFile or playerClassFile
end

function ns:GetViewSpec()
    return viewSpec or playerSpec
end

function ns:SetViewClassSpec(classFile, specName)
    viewClassFile = classFile
    viewSpec = specName
end

function ns:ResetView()
    viewClassFile = nil
    viewSpec = nil
end

function ns:IsCustomView()
    return viewClassFile ~= nil
end

local function UpdatePlayerInfo()
    _, playerClassFile = UnitClass("player")

    local specIndex = GetSpecialization()
    if specIndex then
        local specID, name = GetSpecializationInfo(specIndex)
        playerSpecLocalized = name or ""
        -- Use English name for Data.lua lookup (works in all languages)
        playerSpec = SPEC_ENGLISH[specID] or name or ""
    else
        playerSpec = ""
        playerSpecLocalized = ""
    end
end

----------------------------------------------------------------------
-- Data access
----------------------------------------------------------------------

function ns:GetBiSList(contentType)
    if not BiSGuideData then return nil end

    local classFile = self:GetViewClass()
    local spec = self:GetViewSpec()

    local classData = BiSGuideData[classFile]
    if not classData then return nil end

    local specData = classData[spec]
    if not specData then return nil end

    return specData[contentType]
end

-- Check if an item is currently equipped in the given slot
function ns:GetEquippedItemID(slotID)
    local itemID = GetInventoryItemID("player", slotID)
    return itemID
end

-- Check if a BiS item is equipped
function ns:IsItemEquipped(slotID, bisItemID)
    local equippedID = self:GetEquippedItemID(slotID)
    return equippedID == bisItemID
end

----------------------------------------------------------------------
-- Event handling
----------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        UpdatePlayerInfo()

        -- Init saved variables
        if not BiSGuideDB then
            BiSGuideDB = {
                lastContentType = "raid",
            }
        end
        if not BiSGuideDB.trackedLoot then
            BiSGuideDB.trackedLoot = {}
        end

        -- Announce
        local classColor = RAID_CLASS_COLORS[playerClassFile]
        local hex = classColor and classColor:GenerateHexColor() or "ffffffff"
        print("|cff00ccffBiS Guide|r loaded - " ..
              "|c" .. hex .. playerSpec .. " " .. (UnitClass("player")) .. "|r")

        if not BiSGuideData or not BiSGuideData[playerClassFile] then
            print("|cff00ccffBiS Guide|r: No data for your class. Run the scraper to generate Data.lua")
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        UpdatePlayerInfo()
        if ns.UpdateUI then
            ns:UpdateUI()
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        if ns.UpdateUI and ns.frame and ns.frame:IsShown() then
            ns:UpdateUI()
        end
    end
end)

----------------------------------------------------------------------
-- Slash command
----------------------------------------------------------------------

SLASH_BISGUIDE1 = "/bis"
SLASH_BISGUIDE2 = "/bisguide"
SlashCmdList["BISGUIDE"] = function(msg)
    msg = msg:lower():trim()

    if msg == "show" or msg == "" then
        if ns.TogglePanel then
            ns:TogglePanel()
        end
    elseif msg == "raid" or msg == "mythicplus" or msg == "m+" or msg == "pvp" then
        if msg == "m+" then msg = "mythicplus" end
        BiSGuideDB.lastContentType = msg
        if ns.ShowPanel then ns:ShowPanel() end
        if ns.UpdateUI then ns:UpdateUI() end
    elseif msg == "tracker" or msg == "loot" then
        if ns.ToggleLootTracker then ns:ToggleLootTracker() end
    else
        print("|cff00ccffBiS Guide|r commands:")
        print("  /bis - Toggle BiS panel")
        print("  /bis raid - Show raid BiS")
        print("  /bis m+ - Show M+ BiS")
        print("  /bis pvp - Show PvP BiS")
        print("  /bis tracker - Toggle Loot Tracker")
    end
end
