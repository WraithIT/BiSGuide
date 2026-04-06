----------------------------------------------------------------------
-- BiSGuide - Instance Data
-- Midnight Season 1 raids and M+ dungeons with boss lists
----------------------------------------------------------------------

local addonName, ns = ...

ns.SEASON_LABEL = "Midnight - Season 1"

ns.SEASON_INSTANCES = {
    -- Raids (3 wings, 9 bosses total)
    {
        name = "The Dreamrift",
        instanceType = "raid",
        bosses = {
            "Chimaerus",
        },
    },
    {
        name = "The Voidspire",
        instanceType = "raid",
        bosses = {
            "Imperator Averzian",
            "Vorasius",
            "Fallen-King Salhadaar",
            "Vaelgor & Ezzorak",
            "Lightblinded Vanguard",
            "Crown of the Cosmos",
        },
    },
    {
        name = "March on Quel'Danas",
        instanceType = "raid",
        bosses = {
            "Belo'ren, Child of Al'ar",
            "Midnight Falls",
        },
    },
    -- M+ Dungeons (4 new + 4 legacy)
    {
        name = "Magisters' Terrace",
        instanceType = "dungeon",
        bosses = {
            "Arcanotron Custos",
            "Seranel Sunlash",
            "Gemellus",
            "Degentrius",
        },
    },
    {
        name = "Maisara Caverns",
        instanceType = "dungeon",
        bosses = {
            "Muro'jin",
            "Vordaza",
            "Rak'tul",
        },
    },
    {
        name = "Nexus-Point Xenas",
        instanceType = "dungeon",
        bosses = {
            "Kasreth",
            "Corewarden Nysarra",
            "Lothraxion",
        },
    },
    {
        name = "Windrunner Spire",
        instanceType = "dungeon",
        bosses = {
            "Emberdawn",
            "Kalis",
            "Commander Kroluk",
            "Restless Heart",
        },
    },
    {
        name = "Algeth'ar Academy",
        instanceType = "dungeon",
        bosses = {
            "Vexamus",
            "Overgrown Ancient",
            "Crawth",
            "Echo of Doragosa",
        },
    },
    {
        name = "Pit of Saron",
        instanceType = "dungeon",
        bosses = {
            "Forgemaster Garfrost",
            "Ick & Krick",
            "Scourgelord Tyrannus",
        },
    },
    {
        name = "The Seat of the Triumvirate",
        instanceType = "dungeon",
        bosses = {
            "Zuraal the Ascended",
            "Saprish",
            "Viceroy Nezhar",
            "L'ura",
        },
    },
    {
        name = "Skyreach",
        instanceType = "dungeon",
        bosses = {
            "Ranjit",
            "Araknath",
            "Rukhran",
            "High Sage Viryx",
        },
    },
}
