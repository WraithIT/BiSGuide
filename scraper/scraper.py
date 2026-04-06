#!/usr/bin/env python3
"""
BiSGuide Scraper v3
- Playwright for full JS rendering of guide pages
- Wowhead XML API for accurate slot, quality, and source info
- Zone name resolution for drop sources

Usage:
    python scraper.py                          # All classes
    python scraper.py --class mage --spec fire # One spec
    python scraper.py --dry-run                # Preview
"""

import argparse
import json
import re
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

import requests
from playwright.sync_api import sync_playwright

# ──────────────────────────────────────────────────────────────────────
# Class / Spec definitions
# ──────────────────────────────────────────────────────────────────────

CLASSES = {
    "death-knight":  {"wow": "DEATHKNIGHT",  "specs": ["Blood", "Frost", "Unholy"]},
    "demon-hunter":  {"wow": "DEMONHUNTER",  "specs": ["Havoc", "Vengeance", "Devourer"]},
    "druid":         {"wow": "DRUID",        "specs": ["Balance", "Feral", "Guardian", "Restoration"]},
    "evoker":        {"wow": "EVOKER",       "specs": ["Devastation", "Preservation", "Augmentation"]},
    "hunter":        {"wow": "HUNTER",       "specs": ["Beast Mastery", "Marksmanship", "Survival"]},
    "mage":          {"wow": "MAGE",         "specs": ["Arcane", "Fire", "Frost"]},
    "monk":          {"wow": "MONK",         "specs": ["Brewmaster", "Mistweaver", "Windwalker"]},
    "paladin":       {"wow": "PALADIN",      "specs": ["Holy", "Protection", "Retribution"]},
    "priest":        {"wow": "PRIEST",       "specs": ["Discipline", "Holy", "Shadow"]},
    "rogue":         {"wow": "ROGUE",        "specs": ["Assassination", "Outlaw", "Subtlety"]},
    "shaman":        {"wow": "SHAMAN",       "specs": ["Elemental", "Enhancement", "Restoration"]},
    "warlock":       {"wow": "WARLOCK",      "specs": ["Affliction", "Demonology", "Destruction"]},
    "warrior":       {"wow": "WARRIOR",      "specs": ["Arms", "Fury", "Protection"]},
}

# Maps Wowhead INVTYPE id → addon equipment slot id
# Key difference: INVTYPE 11=Finger→equip 11, INVTYPE 12=Trinket→equip 13,
# INVTYPE 16=Cloak→equip 15, INVTYPE 13=OneHand→equip 16
INVTYPE_TO_EQUIP = {
    1: 1, 2: 2, 3: 3, 5: 5, 6: 6, 7: 7, 8: 8, 9: 9, 10: 10,
    11: 11,  # Finger → Finger0 (handle Finger1 dynamically)
    12: 13,  # Trinket → Trinket0 (handle Trinket1 dynamically)
    13: 16,  # One-Hand → MainHand
    14: 17,  # Shield → OffHand
    15: 16,  # Ranged → MainHand (legacy)
    16: 15,  # Cloak → Back
    17: 16,  # Two-Hand → MainHand
    20: 5,   # Robe → Chest
    21: 16,  # Main Hand weapon → MainHand
    22: 17,  # Off-hand weapon → OffHand
    23: 17,  # Held In Off-hand → OffHand
    25: 16,  # Thrown → MainHand (legacy)
    26: 16,  # Ranged right → MainHand (legacy)
}

ALL_EQUIP_SLOTS = [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
CONTENT_TYPES = ["raid", "mythicplus", "pvp"]
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0",
    "Accept": "*/*",
}

# ── u.gg PvP API ──

UGG_CLASS_NAMES = {
    "death-knight": "DeathKnight", "demon-hunter": "DemonHunter",
    "druid": "Druid", "evoker": "Evoker", "hunter": "Hunter",
    "mage": "Mage", "monk": "Monk", "paladin": "Paladin",
    "priest": "Priest", "rogue": "Rogue", "shaman": "Shaman",
    "warlock": "Warlock", "warrior": "Warrior",
}

UGG_SLOT_MAP = {
    "head": 1, "neck": 2, "shoulder": 3, "chest": 5,
    "belt": 6, "legs": 7, "feet": 8, "wrist": 9,
    "gloves": 10, "cape": 15,
    "ring1": 11, "ring2": 12,
    "trinket1": 13, "trinket2": 14,
    "weapon1": 16, "weapon2": 17,
}

UGG_QUALITY_MAP = {
    "POOR": 0, "COMMON": 1, "UNCOMMON": 2, "RARE": 3, "EPIC": 4, "LEGENDARY": 5,
}

# ──────────────────────────────────────────────────────────────────────
# Cache (items + zones)
# ──────────────────────────────────────────────────────────────────────

CACHE_FILE = Path(__file__).parent / "item_cache.json"
_item_cache: dict = {}
_zone_cache: dict = {}
_cache_lock = threading.Lock()
_wowhead_semaphore = threading.Semaphore(2)  # Max 2 concurrent Wowhead requests


def load_cache():
    global _item_cache, _zone_cache
    if CACHE_FILE.exists():
        try:
            data = json.loads(CACHE_FILE.read_text("utf-8"))
            _item_cache = data.get("items", {})
            _zone_cache = data.get("zones", {})
        except Exception:
            pass


def save_cache():
    with _cache_lock:
        CACHE_FILE.write_text(json.dumps(
            {"items": _item_cache, "zones": _zone_cache},
            ensure_ascii=False, indent=1,
        ), "utf-8")


# ──────────────────────────────────────────────────────────────────────
# Zone name resolution
# ──────────────────────────────────────────────────────────────────────

def get_zone_name(zone_id: int) -> str:
    key = str(zone_id)
    with _cache_lock:
        if key in _zone_cache:
            return _zone_cache[key]

    try:
        with _wowhead_semaphore:
            resp = requests.get(
                f"https://www.wowhead.com/zone={zone_id}",
                headers=HEADERS, timeout=10, allow_redirects=True,
            )
        m = re.search(r"<title>([^<]+?)(?:\s*[-–—]|\s*Zone)", resp.text)
        if not m:
            m = re.search(r'<h1[^>]*class="heading-size-1"[^>]*>([^<]+)', resp.text)
        name = m.group(1).strip() if m else ""
    except Exception:
        name = ""

    with _cache_lock:
        _zone_cache[key] = name
    return name


# ──────────────────────────────────────────────────────────────────────
# Wowhead XML Item API
# ──────────────────────────────────────────────────────────────────────

def _wowhead_get(url: str, retries: int = 3) -> str | None:
    """GET with semaphore, retry on 403 with exponential backoff."""
    for attempt in range(retries):
        with _wowhead_semaphore:
            try:
                resp = requests.get(url, headers=HEADERS, timeout=12)
                if resp.status_code == 403 and attempt < retries - 1:
                    delay = 2 ** (attempt + 1)  # 2s, 4s
                    print(f"    [429/403] {url.split('?')[0]} — retry in {delay}s")
                    time.sleep(delay)
                    continue
                resp.raise_for_status()
                return resp.text
            except requests.exceptions.HTTPError as e:
                if attempt < retries - 1:
                    continue
                print(f"    [WARN] {url.split('?')[0]}: {e}")
                return None
            except Exception as e:
                print(f"    [WARN] {url.split('?')[0]}: {e}")
                return None
    return None


TOOLTIP_SLOT_MAP = {
    "Head": 1, "Neck": 2, "Shoulder": 3, "Chest": 5, "Robe": 5,
    "Waist": 6, "Legs": 7, "Feet": 8, "Wrist": 9, "Hands": 10,
    "Finger": 11, "Trinket": 13, "Back": 15, "Cloak": 15,
    "Main Hand": 16, "One-Hand": 16, "Two-Hand": 16,
    "Off Hand": 17, "Held In Off-hand": 17, "Shield": 17,
    "Ranged": 16,
}


def _get_item_info_tooltip(item_id: int) -> dict | None:
    """Fallback: fetch item info via Wowhead tooltip JSON API."""
    url = f"https://nether.wowhead.com/tooltip/item/{item_id}"
    try:
        with _wowhead_semaphore:
            resp = requests.get(url, headers=HEADERS, timeout=10)
            resp.raise_for_status()
            data = resp.json()
    except Exception as e:
        print(f"    [WARN] Tooltip API failed for {item_id}: {e}")
        return None

    name = data.get("name", "Unknown")
    quality = data.get("quality", 3)

    # Parse ilvl from tooltip HTML
    tooltip = data.get("tooltip", "")
    ilvl = 0
    ilvl_m = re.search(r"Item Level.*?(\d+)", tooltip)
    if ilvl_m:
        ilvl = int(ilvl_m.group(1))

    # Parse slot from tooltip HTML — match known slot names anywhere in <td>
    equip_slot = None
    slot_names = "|".join(TOOLTIP_SLOT_MAP.keys())
    slot_m = re.search(rf'<td>({slot_names})</td>', tooltip)
    if slot_m:
        equip_slot = TOOLTIP_SLOT_MAP[slot_m.group(1)]

    result = {"slot": equip_slot, "quality": quality, "name": name, "source": "PvP Vendor", "ilvl": ilvl}
    with _cache_lock:
        _item_cache[str(item_id)] = result
    return result


SOURCE_LABELS = {
    1: "Crafted", 2: "Drop", 3: "PvP", 4: "Quest", 5: "Vendor", 6: "Discovery",
}


def get_item_info(item_id: int, bonus: str = "") -> dict | None:
    """
    Fetch item info via Wowhead XML API.
    Returns {"slot": int, "quality": int, "name": str, "source": str, "ilvl": int} or None.
    """
    key = str(item_id)
    with _cache_lock:
        if key in _item_cache:
            cached = _item_cache[key]
            # If we have bonus and cached has no ilvl, re-fetch with bonus for ilvl
            if bonus and cached.get("ilvl", 0) == 0:
                pass  # Fall through to re-fetch
            else:
                return cached

    # Fetch base item data (rate-limited with retry on 403)
    url_base = f"https://www.wowhead.com/item={item_id}?xml"
    xml = _wowhead_get(url_base)
    if xml is None:
        # Fallback: tooltip JSON API (works for PvP items blocked by XML API)
        return _get_item_info_tooltip(item_id)

    # If bonus IDs available, fetch again with bonus to get correct ilvl
    ilvl_xml = None
    if bonus:
        ilvl_xml = _wowhead_get(f"https://www.wowhead.com/item={item_id}?bonus={bonus}&xml")

    # ── Parse XML fields ──
    name_m = re.search(r"<name><!\[CDATA\[(.+?)\]\]></name>", xml)
    name = name_m.group(1) if name_m else "Unknown"

    quality_m = re.search(r'<quality id="(\d+)">', xml)
    quality = int(quality_m.group(1)) if quality_m else 4

    # Get ilvl from bonus response if available, otherwise from base
    ilvl_source = ilvl_xml if ilvl_xml else xml
    level_m = re.search(r"<level>(\d+)</level>", ilvl_source)
    ilvl = int(level_m.group(1)) if level_m else 0

    slot_m = re.search(r'<inventorySlot id="(\d+)">', xml)
    invtype = int(slot_m.group(1)) if slot_m else None
    equip_slot = INVTYPE_TO_EQUIP.get(invtype) if invtype else None

    # ── Detect tier set from tooltip ──
    tooltip_m = re.search(r"<htmlTooltip><!\[CDATA\[(.+?)\]\]></htmlTooltip>", xml, re.DOTALL)
    tooltip_html = tooltip_m.group(1) if tooltip_m else ""
    is_tier_set = bool(re.search(r"item-set=\d+", tooltip_html))

    # Extract set name if tier set
    set_name = ""
    if is_tier_set:
        sm = re.search(r'class="q">([^<]+)</a>\s*\(\d+/\d+\)', tooltip_html)
        if sm:
            set_name = sm.group(1).strip()

    # ── Parse source from embedded JSON ──
    source_text = ""
    json_m = re.search(r"<json><!\[CDATA\[(.+?)\]\]></json>", xml)
    if json_m:
        try:
            jdata = json.loads("{" + json_m.group(1) + "}")
            source_text = _build_source(jdata)
        except Exception:
            pass

    # Tier set labeling
    if is_tier_set:
        if source_text:
            source_text = f"Tier Set ({set_name}) - {source_text}"
        else:
            source_text = f"Tier Set ({set_name})" if set_name else "Tier Set (Raid)"

    # ── NEVER leave source empty ──
    if not source_text:
        if quality >= 4:
            source_text = "Raid Drop"
        elif quality == 3:
            source_text = "Dungeon Drop"
        else:
            source_text = "Drop"

    result = {"slot": equip_slot, "quality": quality, "name": name, "source": source_text, "ilvl": ilvl}
    with _cache_lock:
        _item_cache[key] = result
    return result


def _build_source(jdata: dict) -> str:
    """Build human-readable source string from Wowhead JSON data."""
    sources = jdata.get("source", [])
    source_more = jdata.get("sourcemore", [])

    if not sources:
        return ""

    src_type = sources[0]

    if src_type == 1:  # Crafted
        if source_more:
            sm = source_more[0]
            recipe = sm.get("n", "")
            if recipe:
                return f"Crafted ({recipe})"
        return "Crafted"

    elif src_type == 2:  # Drop
        parts = []
        for sm in source_more:
            if "n" in sm:
                parts.append(sm["n"])
            if "z" in sm:
                zname = get_zone_name(sm["z"])
                if zname and zname not in parts:
                    parts.append(zname)
        if parts:
            return " - ".join(parts[:2])
        return "Drop"

    elif src_type == 3:
        return "PvP Vendor"
    elif src_type == 4:
        return "Quest"
    elif src_type == 5:
        return "Vendor"
    elif src_type == 6:
        return "Discovery"

    return SOURCE_LABELS.get(src_type, "")


# ──────────────────────────────────────────────────────────────────────
# Playwright scraping
# ──────────────────────────────────────────────────────────────────────

EXTRACT_JS = r"""
() => {
    const body = document.querySelector('#guide-body')
                 || document.querySelector('.guide-body')
                 || document.querySelector('article')
                 || document.body;

    const result = { sections: [], allItems: [] };
    const seenIds = new Set();

    const allAnchors = body.querySelectorAll('a[href*="/item="], a[href*="/item/"]');
    allAnchors.forEach(a => {
        const m = a.href.match(/item[=/](\d+)/);
        if (!m) return;
        const id = parseInt(m[1]);
        if (id < 1000 || seenIds.has(id)) return;
        seenIds.add(id);

        const name = a.textContent.trim();
        if (!name || name.length < 3 || name.startsWith('http')) return;

        let quality = 4;
        const cls = a.className || '';
        if (cls.indexOf('q5') >= 0) quality = 5;
        else if (cls.indexOf('q3') >= 0) quality = 3;

        const href = a.getAttribute('href') || '';
        const bm = href.match(/bonus=([0-9:]+)/);
        const bonus = bm ? bm[1] : '';

        result.allItems.push({ id, name, quality, bonus });
    });

    const headings = body.querySelectorAll('h2, h3');
    let curType = null;
    let curItems = [];

    const flush = () => {
        if (curType && curItems.length)
            result.sections.push({ type: curType, items: [...curItems] });
        curItems = [];
    };

    headings.forEach(h => {
        const t = h.textContent.toLowerCase();
        let ct = null;
        if (t.indexOf('raid') >= 0 && (t.indexOf('best') >= 0 || t.indexOf('bis') >= 0 || t.indexOf('gear') >= 0))
            ct = 'raid';
        else if ((t.indexOf('mythic') >= 0 || t.indexOf('m+') >= 0 || t.indexOf('dungeon') >= 0) &&
                 (t.indexOf('best') >= 0 || t.indexOf('bis') >= 0 || t.indexOf('gear') >= 0))
            ct = 'mythicplus';
        else if (t.indexOf('pvp') >= 0 && (t.indexOf('best') >= 0 || t.indexOf('bis') >= 0 || t.indexOf('gear') >= 0))
            ct = 'pvp';

        if (ct) { flush(); curType = ct; }

        let el = h.nextElementSibling;
        while (el && !el.matches('h2, h3')) {
            el.querySelectorAll('a[href*="/item="], a[href*="/item/"]').forEach(a => {
                const m2 = a.href.match(/item[=/](\d+)/);
                if (m2) {
                    const id2 = parseInt(m2[1]);
                    if (id2 >= 1000) curItems.push({ id: id2, name: a.textContent.trim() });
                }
            });
            el = el.nextElementSibling;
        }
    });
    flush();

    return result;
}
"""


def scrape_page(url: str, browser) -> dict:
    print(f"  [BROWSER] {url}")
    ctx = browser.new_context(
        user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0",
        viewport={"width": 1400, "height": 900},
    )
    page = ctx.new_page()
    try:
        page.goto(url, wait_until="domcontentloaded", timeout=30_000)
        page.wait_for_timeout(3000)
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        page.wait_for_timeout(2000)
        return page.evaluate(EXTRACT_JS)
    except Exception as e:
        print(f"  [ERROR] {e}")
        return {"sections": [], "allItems": []}
    finally:
        ctx.close()


# ──────────────────────────────────────────────────────────────────────
# Resolve items → BiS list
# ──────────────────────────────────────────────────────────────────────

@dataclass
class BiSItem:
    slot: int
    item_id: int
    name: str
    source: str
    quality: int
    ilvl: int = 0
    bonus: str = ""


def resolve_items(raw_items: list[dict]) -> list[BiSItem]:
    """
    Query XML API for each item in parallel, map to equipment slots.
    One item per slot, no duplicates. First mention = BiS.
    """
    # De-duplicate by item ID, preserving order
    unique = []
    seen = set()
    for raw in raw_items:
        if raw["id"] not in seen:
            seen.add(raw["id"])
            unique.append(raw)

    # Fetch all item info in parallel
    info_map: dict[int, dict] = {}

    def _fetch(raw):
        return raw["id"], get_item_info(raw["id"], raw.get("bonus", ""))

    with ThreadPoolExecutor(max_workers=8) as pool:
        for item_id, info in pool.map(_fetch, unique):
            if info:
                info_map[item_id] = info

    # Assign slots in original order (first mention = BiS)
    filled: dict[int, BiSItem] = {}
    used_ids: set[int] = set()

    for raw in raw_items:
        item_id = raw["id"]
        if item_id in used_ids or item_id not in info_map:
            continue

        info = info_map[item_id]
        if info["slot"] is None:
            continue

        slot = info["slot"]

        # Dual-slot handling: finger 11→12, trinket 13→14
        if slot == 11 and 11 in filled and 12 not in filled:
            slot = 12
        elif slot == 13 and 13 in filled and 14 not in filled:
            slot = 14
        elif slot == 16 and 16 in filled and 17 not in filled:
            slot = 17

        if slot in filled:
            continue

        used_ids.add(item_id)
        filled[slot] = BiSItem(
            slot=slot,
            item_id=item_id,
            name=info["name"],
            source=info["source"],
            quality=info["quality"],
            ilvl=info.get("ilvl", 0),
            bonus=raw.get("bonus", ""),
        )

    return sorted(filled.values(), key=lambda x: x.slot)


# ──────────────────────────────────────────────────────────────────────
# URLs
# ──────────────────────────────────────────────────────────────────────

def wowhead_bis(cls: str, spec: str) -> str:
    return f"https://www.wowhead.com/guide/classes/{cls}/{spec.lower().replace(' ','-')}/bis-gear"

def wowhead_pvp(cls: str, spec: str) -> str:
    return f"https://www.wowhead.com/guide/classes/{cls}/{spec.lower().replace(' ','-')}/pvp-bis-gear"

def icyveins_bis(cls: str, spec: str) -> str:
    return f"https://www.icy-veins.com/wow/{cls}/{spec.lower().replace(' ','-')}/bis-gear"


# ──────────────────────────────────────────────────────────────────────
# u.gg PvP API
# ──────────────────────────────────────────────────────────────────────

def fetch_ugg_pvp(cls_slug: str, spec: str) -> list[BiSItem]:
    """
    Fetch PvP BiS from u.gg JSON API (3v3 bracket).
    Returns resolved BiSItem list.
    """
    ugg_cls = UGG_CLASS_NAMES.get(cls_slug)
    if not ugg_cls:
        print(f"  [u.gg] Unknown class slug: {cls_slug}")
        return []

    url = f"https://stats2.u.gg/wow/builds/v29/PVP/3v3/{ugg_cls}.json"
    print(f"  [u.gg PvP] {url}")

    try:
        resp = requests.get(url, headers=HEADERS, timeout=15)
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:
        print(f"  [u.gg] API error: {e}")
        return []

    # Find the spec data (try exact name, then without spaces for multi-word specs)
    spec_data = data.get(spec) or data.get(spec.replace(" ", ""))
    if not spec_data:
        print(f"  [u.gg] No data for spec '{spec}', available: {list(data.keys())}")
        return []

    # Pick the hero talent build with the most players
    best_build = None
    best_players = -1
    for hero_name, build in spec_data.items():
        stats = build.get("stats", {})
        players = stats.get("unique_player_count", 0)
        if players > best_players:
            best_players = players
            best_build = build
            print(f"  [u.gg] Hero talent '{hero_name}': {players} players, rating {stats.get('rating', '?')}")

    if not best_build:
        print(f"  [u.gg] No builds found for {spec}")
        return []

    items_data = best_build.get("items", {})
    combos = best_build.get("combos", {})

    # Collect raw items from individual slots
    raw_items: dict[int, int] = {}  # equip_slot → item_id
    for slot_name, equip_slot in UGG_SLOT_MAP.items():
        slot_entry = items_data.get(slot_name)
        if slot_entry and isinstance(slot_entry, dict) and slot_entry.get("item", 0) > 0:
            raw_items[equip_slot] = slot_entry["item"]

    # Override ring/trinket/weapon pairs from combos (more accurate)
    for combo_key, slot1, slot2 in [
        ("ring1_combos", 11, 12),
        ("trinket1_combos", 13, 14),
        ("weapon1_combos", 16, 17),
    ]:
        combo = combos.get(combo_key)
        if not combo or not isinstance(combo, dict):
            continue
        first = combo.get("first_item_id")
        second = combo.get("second_item_id")
        if first and first > 0:
            raw_items[slot1] = first
        if second and second > 0:
            raw_items[slot2] = second

    # Resolve all items via Wowhead XML API in parallel
    filled: dict[int, BiSItem] = {}

    def _fetch_pvp(slot_and_id):
        equip_slot, item_id = slot_and_id
        return equip_slot, item_id, get_item_info(item_id)

    with ThreadPoolExecutor(max_workers=8) as pool:
        for equip_slot, item_id, info in pool.map(_fetch_pvp, raw_items.items()):
            if not info:
                continue
            filled[equip_slot] = BiSItem(
                slot=equip_slot,
                item_id=item_id,
                name=info["name"],
                source="PvP",
                quality=info["quality"],
                ilvl=info.get("ilvl", 0),
                bonus="",
            )

    print(f"  [u.gg PvP] {len(filled)}/{len(ALL_EQUIP_SLOTS)} slots filled")
    return sorted(filled.values(), key=lambda x: x.slot)


# ──────────────────────────────────────────────────────────────────────
# Orchestration
# ──────────────────────────────────────────────────────────────────────

def scrape_spec(cls_slug: str, spec: str, browser) -> dict[str, list[BiSItem]]:
    result = {"raid": [], "mythicplus": [], "pvp": []}

    # ── Launch PvP (u.gg) in background while Wowhead scrapes ──
    pvp_pool = ThreadPoolExecutor(max_workers=1)
    pvp_future = pvp_pool.submit(fetch_ugg_pvp, cls_slug, spec)

    # ── Main BiS page (Wowhead + Playwright) ──
    page_data = scrape_page(wowhead_bis(cls_slug, spec), browser)
    all_items = page_data.get("allItems", [])
    sections = page_data.get("sections", [])
    print(f"  Page: {len(all_items)} items, {len(sections)} sections")

    # Resolve ALL items in parallel
    print(f"  Resolving {len(all_items)} items via XML API...")
    all_resolved = resolve_items(all_items)
    print(f"  => {len(all_resolved)} slots filled")

    # Try section-specific lists
    for sec in sections:
        ct = sec["type"]
        if ct in ("raid", "mythicplus") and sec["items"]:
            sec_resolved = resolve_items(sec["items"])
            if len(sec_resolved) >= 5:
                result[ct] = sec_resolved
                print(f"  Section '{ct}': {len(sec_resolved)} slots")

    # Fill raid/M+ from allItems (no duplicate item IDs)
    for ct in ("raid", "mythicplus"):
        if not result[ct]:
            result[ct] = list(all_resolved)
        else:
            existing_slots = {i.slot for i in result[ct]}
            existing_ids = {i.item_id for i in result[ct]}
            for item in all_resolved:
                if item.slot not in existing_slots and item.item_id not in existing_ids:
                    result[ct].append(item)
                    existing_slots.add(item.slot)
                    existing_ids.add(item.item_id)
            result[ct].sort(key=lambda x: x.slot)

    # ── Collect PvP result ──
    try:
        pvp_result = pvp_future.result(timeout=120)
        result["pvp"] = pvp_result if pvp_result else []
    except Exception as e:
        print(f"  PvP future error: {e}")
    pvp_pool.shutdown(wait=False)

    if not result["pvp"]:
        print("  PvP: u.gg returned no data, using raid BiS as fallback")
        result["pvp"] = list(all_resolved)

    # ── Check for missing slots ──
    for ct in CONTENT_TYPES:
        filled_slots = {i.slot for i in result[ct]}
        missing = set(ALL_EQUIP_SLOTS) - filled_slots
        if missing:
            print(f"  {ct} missing slots: {sorted(missing)}")

    # Summary
    for ct in CONTENT_TYPES:
        n = len(result[ct])
        total = len(ALL_EQUIP_SLOTS)
        status = "OK" if n >= total else f"INCOMPLETE ({total - n} missing)"
        print(f"  => {ct}: {n}/{total} {status}")

    return result


def _scrape_class(cls_slug: str, cls_info: dict, filter_spec=None) -> tuple[str, dict]:
    """Scrape all specs for one class in its own browser. Runs in a thread."""
    wow_cls = cls_info["wow"]
    specs_data = {}

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)

        for spec in cls_info["specs"]:
            if filter_spec and spec.lower() != filter_spec.lower():
                continue

            print(f"  [{wow_cls}] {spec} - starting...")
            specs_data[spec] = scrape_spec(cls_slug, spec, browser)
            save_cache()

            filled = {ct: len(specs_data[spec][ct]) for ct in CONTENT_TYPES}
            print(f"  [{wow_cls}] {spec} - DONE  raid={filled['raid']} m+={filled['mythicplus']} pvp={filled['pvp']}")

        browser.close()

    return wow_cls, specs_data


def scrape_all(filter_class=None, filter_spec=None) -> dict:
    all_data = {}

    # Build list of classes to scrape
    jobs = []
    for cls_slug, cls_info in CLASSES.items():
        if filter_class and cls_slug != filter_class:
            continue
        jobs.append((cls_slug, cls_info))

    max_workers = min(len(jobs), 3)
    print(f"[PARALLEL] {len(jobs)} classes, {max_workers} concurrent browsers\n")

    if len(jobs) == 1:
        wow_cls, specs_data = _scrape_class(jobs[0][0], jobs[0][1], filter_spec)
        all_data[wow_cls] = specs_data
    else:
        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            futures = {
                pool.submit(_scrape_class, slug, info, filter_spec): slug
                for slug, info in jobs
            }
            for future in as_completed(futures):
                slug = futures[future]
                try:
                    wow_cls, specs_data = future.result()
                    all_data[wow_cls] = specs_data
                    print(f"  === {wow_cls} COMPLETE ===")
                except Exception as e:
                    print(f"  === {slug} FAILED: {e} ===")

    return all_data


# ──────────────────────────────────────────────────────────────────────
# Lua generation
# ──────────────────────────────────────────────────────────────────────

def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def generate_lua(data: dict) -> str:
    lines = [
        "----------------------------------------------------------------------",
        "-- BiSGuide - Data (auto-generated by scraper.py v3)",
        "-- Wowhead XML API + Playwright",
        "----------------------------------------------------------------------",
        "",
        "BiSGuideData = {",
    ]

    for wow_cls in sorted(data):
        specs = data[wow_cls]
        lines.append(f'    ["{wow_cls}"] = {{')
        for spec_name in sorted(specs):
            spec_data = specs[spec_name]
            lines.append(f'        ["{esc(spec_name)}"] = {{')
            for ct in CONTENT_TYPES:
                items = spec_data.get(ct, [])
                lines.append(f'            ["{ct}"] = {{')
                for item in items:
                    src = esc(item.source) if isinstance(item, BiSItem) else esc(item.get("source", ""))
                    nm = esc(item.name) if isinstance(item, BiSItem) else esc(item.get("name", ""))
                    sid = item.slot if isinstance(item, BiSItem) else item.get("slot", 0)
                    iid = item.item_id if isinstance(item, BiSItem) else item.get("item_id", 0)
                    q = item.quality if isinstance(item, BiSItem) else item.get("quality", 4)
                    il = item.ilvl if isinstance(item, BiSItem) else item.get("ilvl", 0)
                    bn = esc(item.bonus) if isinstance(item, BiSItem) else esc(item.get("bonus", ""))
                    lines.append(
                        f'                {{slot = {sid}, itemId = {iid}, '
                        f'name = "{nm}", source = "{src}", quality = {q}, ilvl = {il}, bonus = "{bn}"}},'
                    )
                lines.append("            },")
            lines.append("        },")
        lines.append("    },")

    lines.append("}")
    lines.append("")
    return "\n".join(lines)


# ──────────────────────────────────────────────────────────────────────
# Parse existing Data.lua (for --pvp-only mode)
# ──────────────────────────────────────────────────────────────────────

def parse_existing_data(lua_path: str) -> dict:
    """Parse existing Data.lua line-by-line into the scraper's data structure."""
    lines = Path(lua_path).read_text("utf-8").splitlines()
    data = {}

    item_re = re.compile(
        r'slot\s*=\s*(\d+),\s*itemId\s*=\s*(\d+),\s*name\s*=\s*"([^"]*)",\s*'
        r'source\s*=\s*"([^"]*)",\s*quality\s*=\s*(\d+),\s*ilvl\s*=\s*(\d+),\s*'
        r'bonus\s*=\s*"([^"]*)"'
    )

    valid_classes = {c["wow"] for c in CLASSES.values()}
    cur_class = cur_spec = cur_ct = None

    for line in lines:
        stripped = line.strip()

        # Detect class: ["DEATHKNIGHT"] = {
        m = re.match(r'\["(\w+)"\]\s*=\s*\{', stripped)
        if m and m.group(1) in valid_classes:
            cur_class = m.group(1)
            data[cur_class] = {}
            cur_spec = cur_ct = None
            continue

        # Detect spec: ["Unholy"] = {
        if cur_class and not cur_ct:
            m = re.match(r'\["([^"]+)"\]\s*=\s*\{', stripped)
            if m and m.group(1) not in CONTENT_TYPES and m.group(1) not in valid_classes:
                cur_spec = m.group(1)
                data[cur_class][cur_spec] = {}
                continue

        # Detect content type: ["raid"] = {
        if cur_spec:
            m = re.match(r'\["(\w+)"\]\s*=\s*\{', stripped)
            if m and m.group(1) in CONTENT_TYPES:
                cur_ct = m.group(1)
                data[cur_class][cur_spec][cur_ct] = []
                continue

        # Detect item row
        if cur_ct:
            m = item_re.search(line)
            if m:
                data[cur_class][cur_spec][cur_ct].append(BiSItem(
                    slot=int(m.group(1)),
                    item_id=int(m.group(2)),
                    name=m.group(3),
                    source=m.group(4),
                    quality=int(m.group(5)),
                    ilvl=int(m.group(6)),
                    bonus=m.group(7),
                ))
                continue

        # Closing brace resets content type
        if cur_ct and stripped == "},":
            cur_ct = None

    # Deduplicate: keep first item per slot (BiS priority)
    for cls in data.values():
        for spec in cls.values():
            for ct in CONTENT_TYPES:
                items = spec.get(ct, [])
                seen_slots: set[int] = set()
                deduped = []
                for item in items:
                    if item.slot not in seen_slots:
                        seen_slots.add(item.slot)
                        deduped.append(item)
                spec[ct] = deduped

    return data


def pvp_only_update(data_path: str, filter_class=None, filter_spec=None) -> dict:
    """Load existing Data.lua, re-fetch only PvP from u.gg, return merged data."""
    data = parse_existing_data(data_path)
    print(f"Loaded {sum(len(s) for s in data.values())} specs from existing Data.lua\n")

    jobs = []
    for cls_slug, cls_info in CLASSES.items():
        if filter_class and cls_slug != filter_class:
            continue
        wow_cls = cls_info["wow"]
        if wow_cls not in data:
            print(f"  [SKIP] {wow_cls} not in existing Data.lua")
            continue
        for spec in cls_info["specs"]:
            if filter_spec and spec.lower() != filter_spec.lower():
                continue
            if spec not in data[wow_cls]:
                continue
            jobs.append((cls_slug, wow_cls, spec))

    print(f"[PVP-ONLY] Fetching u.gg PvP for {len(jobs)} specs...\n")

    def _fetch_one(job):
        cls_slug, wow_cls, spec = job
        print(f"  [{wow_cls}] {spec} PvP...")
        pvp = fetch_ugg_pvp(cls_slug, spec)
        if pvp:
            print(f"  [{wow_cls}] {spec} PvP: {len(pvp)} items")
        else:
            print(f"  [{wow_cls}] {spec} PvP: no data, keeping existing")
        return wow_cls, spec, pvp

    with ThreadPoolExecutor(max_workers=4) as pool:
        for wow_cls, spec, pvp in pool.map(_fetch_one, jobs):
            if pvp:
                data[wow_cls][spec]["pvp"] = pvp

    return data


# ──────────────────────────────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="BiSGuide Scraper v3")
    parser.add_argument("--class", dest="wow_class")
    parser.add_argument("--spec")
    parser.add_argument("--output", "-o")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--pvp-only", action="store_true",
                        help="Only re-fetch PvP from u.gg, keep existing raid/M+ data")
    args = parser.parse_args()

    fc = args.wow_class.lower() if args.wow_class else None
    if fc and fc not in CLASSES:
        print(f"Unknown class: {fc}\nValid: {', '.join(CLASSES)}")
        sys.exit(1)

    fs = args.spec
    if fs and fc:
        valid = [s.lower() for s in CLASSES[fc]["specs"]]
        if fs.lower() not in valid:
            print(f"Unknown spec '{fs}'\nValid: {', '.join(CLASSES[fc]['specs'])}")
            sys.exit(1)

    out = args.output or str(Path(__file__).parent.parent / "Data.lua")

    print("=" * 60)
    if args.pvp_only:
        print("BiSGuide Scraper v3 — PvP-only update (u.gg)")
    else:
        print("BiSGuide Scraper v3 (XML API + Playwright)")
    print(f"Target: {fc or 'ALL'}" + (f" / {fs}" if fs else ""))
    print("=" * 60)

    load_cache()

    if args.pvp_only:
        data = pvp_only_update(out, filter_class=fc, filter_spec=fs)
    else:
        data = scrape_all(filter_class=fc, filter_spec=fs)

    save_cache()

    lua = generate_lua(data)
    if args.dry_run:
        print("\n" + lua)
    else:
        Path(out).write_text(lua, "utf-8")
        print(f"\nData.lua => {out}")

    total = 0
    for cls, specs in data.items():
        for spec, cts in specs.items():
            for ct in CONTENT_TYPES:
                n = len(cts.get(ct, []))
                total += n
    print(f"Total: {total} items across {len(ALL_EQUIP_SLOTS)} slots x specs")


if __name__ == "__main__":
    main()
