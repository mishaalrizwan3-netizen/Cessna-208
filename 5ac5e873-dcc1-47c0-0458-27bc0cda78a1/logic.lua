--=============================================================================
-- CAUTION AND WARNING PANEL (CAS)
-- Does NOT read from the aircraft. Warnings show from multiple conditions
-- on the side panel only (battery on, GEN, ALT, fuel boost, starter, etc.)
-- regardless of which aircraft is loaded. SI variables + L:CAS_* from logic.lua.
-- In Air Manager: add the SIDE PANEL instrument before this CAS so SI vars exist.
--
-- Annunciators follow Cessna 208B Section 4 Normal Procedures, Before Takeoff
-- (Standby Power checklist): White STBY PWR ON (alt on, gen off); Amber
-- GENERATOR OFF (gen tripped); Amber STBY PWR INOP (STBY ALT PWR switch OFF).
--=============================================================================

-------------------------
-- PANEL CONFIG
-------------------------
local TOTAL_WIDTH = 270  -- Total instrument width
local TOTAL_HEIGHT = 300  -- Total instrument height
local PANEL_WIDTH  = 135  -- CAS panel width (left side)
local PANEL_GAP    = 10   -- Space between CAS panel and buttons
local BUTTON_PANEL_WIDTH = TOTAL_WIDTH - PANEL_WIDTH - PANEL_GAP  -- Right-side button panel width
local MAX_HEIGHT   = 280  -- Max height for CAS panel
local TOP_MARGIN   = 10
local LEFT_MARGIN  = 5
local HEADING_HEIGHT = 22

local LINE_HEIGHT  = 18
local LINE_SPACING = 3

local DEFAULT_HEIGHT = 126  -- Height for heading + 4 warnings (min size)

-------------------------
-- STATE
-------------------------
local cautions_visible = false
local cas_panel_visible = false
local cas_visibility_timer = nil
local current_height = DEFAULT_HEIGHT
local caution_order = {}  -- Track order in which cautions are activated

-- Button configuration (right side)
local BUTTON_WIDTH = 48
local BUTTON_HEIGHT = 26
local BUTTON_SPACING = 6
local BUTTON_START_X = PANEL_WIDTH + PANEL_GAP + 5  -- Start a bit inside the right panel
local BUTTON_START_Y = 15   -- Slightly below top for better alignment
local BUTTONS_PER_ROW = 3
local BUTTON_TEXT_SIZE = 15

-------------------------
-- BACKGROUND & HEADING
-------------------------
-- Left CAS text panel (this is what grows/shrinks)
img_text_panel = img_add("black1.png", 0, 0, PANEL_WIDTH, DEFAULT_HEIGHT)

-- Right button panel (fixed size)
img_button_panel = img_add("black1.png", PANEL_WIDTH + PANEL_GAP, 0, BUTTON_PANEL_WIDTH, TOTAL_HEIGHT)

local cautions = {
    -- 1: VOLTAGE LOW (Red)
    {text="VOLTAGE LOW", color="red", weight="bold", visible=false, index=1, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 2: OIL PRESS LOW (Red)
    {text="OIL PRESS LOW", color="red", weight="bold", visible=false, index=2, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 3: FUEL PRESS LOW (Yellow)
    {text="FUEL PRESS LOW", color="yellow", weight="bold", visible=false, index=3, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 4: ENGINE FIRE (Red)
    {text="ENGINE FIRE", color="red", weight="bold", visible=false, index=4, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 5: FUEL SELECT OFF (Red)
    {text="FUEL SELECT OFF", color="red", weight="bold", visible=false, index=5, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 6: FUEL BOOST ON (Yellow)
    {text="FUEL BOOST ON", color="yellow", weight="bold", visible=false, index=6, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 7: IGNITION ON (White)
    {text="IGNITION ON", color="white", weight="bold", visible=false, index=7, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 8: STARTER ON (Yellow)
    {text="STARTER ON", color="yellow", weight="bold", visible=false, index=8, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 9: GENERATOR OFF (Yellow)
    {text="GENERATOR OFF", color="yellow", weight="bold", visible=false, index=9, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 10: STBY PWR ON (White)
    {text="STBY PWR ON", color="white", weight="bold", visible=false, index=10, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 11: GENERATOR OVERHEAT (Yellow)
    {text="GENERATR OVRHT", color="red", weight="bold", visible=false, index=11, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 12: ALTERNATOR OVERHEAT (Yellow)
    {text="ALTNR OVHT", color="yellow", weight="bold", visible=false, index=12, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 13: STBY PWR INOP (Yellow)
    {text="STBY PWR INOP", color="yellow", weight="bold", visible=false, index=13, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 14: L FUEL LOW (Yellow)
    {text="L FUEL LOW", color="red", weight="bold", visible=false, index=14, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 15: R FUEL LOW (Yellow)
    {text="R FUEL LOW", color="red", weight="bold", visible=false, index=15, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 16: L-R FUEL LOW (Yellow)
    {text="L-R FUEL LOW", color="red", weight="bold", visible=false, index=16, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 17: EMER PWR LVR (Yellow)
    {text="EMER PWR LVR", color="yellow", weight="bold", visible=false, index=17, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 18: RSVR FUEL LOW (Red) — triggers if either tank < 82.5 gal
    {text="RSVR FUEL LOW", color="red", weight="bold", visible=false, index=18, sim_triggered=false, manual_override=false, acknowledged=false},
    -- 19: VOLTAGE HIGH (Red)
    {text="VOLTAGE HIGH", color="red", weight="bold", visible=false, index=19, sim_triggered=false, manual_override=false, acknowledged=false},
}


-------------------------
-- CREATE TEXT ELEMENTS (one per caution per position)
-------------------------
-- We support up to 20 lines (all cautions visible)
local MAX_DISPLAY_POSITIONS = 20
local display_texts = {}  -- display_texts[position][caution_index] = text_element
local display_blocks = {} -- display_blocks[position][caution_index] = background block (for red cautions)
local blink_on = true     -- global blink phase (on/off)
local blink_timer = nil   -- handle for blink timer

for pos = 1, MAX_DISPLAY_POSITIONS do
    display_texts[pos] = {}
    display_blocks[pos] = {}  -- keeping table to avoid nil errors elsewhere
    local y = TOP_MARGIN + HEADING_HEIGHT + LINE_SPACING + (pos - 1) * (LINE_HEIGHT + LINE_SPACING)
    for i, c in ipairs(cautions) do
        local txt = txt_add(
            "",
            string.format(
                "font:arial/ARIALBD.TTF; size:15.5; color:%s; halign:center; valign:center;",
                c.color
            ),
            LEFT_MARGIN, y, PANEL_WIDTH - LEFT_MARGIN * 2, LINE_HEIGHT
        )
        display_texts[pos][i] = txt
    end
end

-- CAS heading (created after cautions so it stays visible on top)
txt_heading = txt_add(
    "CAS",
    "font:arial/ARIALBD.TTF; size:15.5; color:white; halign:center;",
    0, TOP_MARGIN, PANEL_WIDTH, HEADING_HEIGHT
)

-------------------------
-- PANEL SIZE LOGIC
-------------------------
local function calculate_height()
    -- Only count visible cautions
    local visible_count = 0
    for _, idx in ipairs(caution_order) do
        local c = cautions[idx]
        if c and c.visible then
            visible_count = visible_count + 1
        end
    end
    
    -- h = margins + heading + gaps between visible lines
    local h = TOP_MARGIN + HEADING_HEIGHT + LINE_SPACING +
              (visible_count * LINE_HEIGHT) + ((visible_count - 1) * LINE_SPACING) +
              TOP_MARGIN

    -- Return calculated height, clamped by MAX_HEIGHT. 
    -- No DEFAULT_HEIGHT floor so it shrinks to just the heading when empty.
    return math.min(math.max(h, 40), MAX_HEIGHT)
end

local function reposition_cautions()
    -- Guard: don't show anything if panel is battery is OFF
    if not cas_panel_visible then
        for pos = 1, MAX_DISPLAY_POSITIONS do
            for i = 1, #cautions do
                if display_texts[pos] and display_texts[pos][i] then txt_set(display_texts[pos][i], "") end
            end
        end
        return
    end

    -- Clear all display positions
    for pos = 1, MAX_DISPLAY_POSITIONS do
        for i = 1, #cautions do
            if display_texts[pos] and display_texts[pos][i] then
                txt_set(display_texts[pos][i], "")
            end
        end
    end

    -- Priority grouping: RED > YELLOW > WHITE
    local reds, yellows, whites = {}, {}, {}
    for _, idx in ipairs(caution_order) do
        local c = cautions[idx]
        if c and c.visible then
            if c.color == "red" then table.insert(reds, idx)
            elseif c.color == "yellow" then table.insert(yellows, idx)
            else table.insert(whites, idx) end
        end
    end

    -- Populate from top down
    local display_pos = 1
    local function render_group(list)
        for _, idx in ipairs(list) do
            local c = cautions[idx]
            if c and c.visible and display_pos <= MAX_DISPLAY_POSITIONS then
                local txt_id = display_texts[display_pos] and display_texts[display_pos][idx]
                if txt_id then
                    txt_set(txt_id, c.text)
                end
                display_pos = display_pos + 1
            end
        end
    end

    render_group(reds)
    render_group(yellows)
    render_group(whites)
end

local function update_panel()
    -- Recalculate and apply dynamic height of left panel
    current_height = calculate_height()
    
    -- Calculate Y offset to anchor to bottom (grows upwards)
    local y_offset = TOTAL_HEIGHT - current_height
    
    -- Resize and move background to match text height
    if img_text_panel then
        img_move(img_text_panel, 0, y_offset, PANEL_WIDTH, current_height)
    end

    -- Move heading to top of the visible panel
    if txt_heading then
        move(txt_heading, 0, y_offset + TOP_MARGIN, PANEL_WIDTH, HEADING_HEIGHT)
    end

    -- Update the text lines: move all text buckets to current offsets
    for pos = 1, MAX_DISPLAY_POSITIONS do
        local y = y_offset + TOP_MARGIN + HEADING_HEIGHT + LINE_SPACING + (pos - 1) * (LINE_HEIGHT + LINE_SPACING)
        for i = 1, #cautions do
            local id = display_texts[pos] and display_texts[pos][i]
            if id then
                move(id, LEFT_MARGIN, y, PANEL_WIDTH - LEFT_MARGIN * 2, LINE_HEIGHT)
            end
        end
    end

    -- Update the text contents according to current order
    reposition_cautions()
end

-- Direct update (no timer coalescing — ensures warnings always render)
local function schedule_update_panel()
    update_panel()
end

-------------------------
-- VISIBILITY FUNCTIONS
-------------------------
local function update_caution_display(index)
    local c = cautions[index]
    if not c then return end

    -- Visible if sim triggers it OR manually overridden to show
    local new_visible = c.sim_triggered or c.manual_override

    if new_visible ~= c.visible then
        if new_visible then
            -- when a caution becomes visible again, clear its ack
            c.acknowledged = false
            -- Standardize style for all active cautions
            for pos = 1, MAX_DISPLAY_POSITIONS do
                local id = display_texts[pos] and display_texts[pos][index]
                if id then
                    txt_style(id, string.format(
                        "font:arial/ARIALBD.TTF; size:15.5; color:%s; halign:center; valign:center;",
                        c.color
                    ))
                end
            end
        end
        c.visible = new_visible

        if new_visible then
            -- Add to order if not already there
            local found = false
            for _, idx in ipairs(caution_order) do
                if idx == index then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(caution_order, index)
            end
        else
            -- Remove from order
            for i = #caution_order, 1, -1 do
                if caution_order[i] == index then
                    table.remove(caution_order, i)
                    break
                end
            end
        end

        -- Global state: are any cautions visible?
        local any_visible = false
        for _, caution in ipairs(cautions) do
            if caution.visible then
                any_visible = true
                break
            end
        end
        cautions_visible = any_visible

        schedule_update_panel()
    end
end

local function set_caution_visibility(index, should_show, from_sim)
    local c = cautions[index]
    if not c then return end

    if from_sim then
        c.sim_triggered = should_show
        -- When panel sends hide (0), clear manual_override so the caution actually hides
        if not should_show then
            c.manual_override = false
        end
    else
        c.manual_override = should_show
    end

    update_caution_display(index)
end

local function show_all()
    caution_order = {}  -- Reset order
    for i, c in ipairs(cautions) do
        c.manual_override = true
        update_caution_display(i)
    end
end

local function hide_all()
    for i, c in ipairs(cautions) do
        c.manual_override = false  -- Sim triggers still apply
        update_caution_display(i)
    end
end

local function toggle_all()
    if cautions_visible then
        hide_all()
    else
        show_all()
    end
end

local function toggle_by_color(color)
    for i, c in ipairs(cautions) do
        if c.color == color then
            c.manual_override = not c.manual_override
            update_caution_display(i)
        end
    end
end

local function toggle_caution(index)
    local c = cautions[index]
    if c then
        c.manual_override = not c.manual_override
        update_caution_display(index)
    end
end

-------------------------
-- ACKNOWLEDGE ALL CAUTIONS (stop red blinking, restore original colors)
-------------------------
local function acknowledge_all_cautions()
    for _, c in ipairs(cautions) do
        if c.visible then
            c.acknowledged = true
            -- switch acknowledged cautions back to their original text color (redundant but kept for consistency)
            for pos = 1, MAX_DISPLAY_POSITIONS do
                local id = display_texts[pos] and display_texts[pos][c.index]
                if id then
                    txt_style(id, string.format(
                        "font:ARIALBD.TTF; size:15.5; color:%s; halign:center; valign:center;",
                        c.color
                    ))
                end
            end
        end
    end
    reposition_cautions()
end

-------------------------
-- BLINK TIMER (Disabled for static text)
-------------------------

-------------------------
-- KEYBOARD CONTROLS
-------------------------
if key_add then
    pcall(function()
        key_add("cas_toggle", "C", nil, function(d)
            if d == 1 then
                toggle_all()
            end
        end)
    end)

    pcall(function()
        key_add("cas_toggle_f1", "F1", nil, function(d)
            if d == 1 then toggle_all() end
        end)
    end)

    pcall(function()
        key_add("cas_red", "R", nil, function(d)
            if d == 1 then toggle_by_color("red") end
        end)
    end)

    pcall(function()
        key_add("cas_yellow", "Y", nil, function(d)
            if d == 1 then toggle_by_color("yellow") end
        end)
    end)

    pcall(function()
        key_add("cas_white", "W", nil, function(d)
            if d == 1 then toggle_by_color("white") end
        end)
    end)
end

-------------------------
-- CAS INPUT (side panel ↔ CAS, same panel)
-------------------------
-- Side panel (logic.lua) creates SI variables and writes 1=show / 0=hide.
-- CAS subscribes to SI variables so warnings show on button click (works without sim).
--  Index  Caution         SI variable name
--  1     ENGINE FIRE     CAS_ENGINE_FIRE
--  2     OIL PRESS LOW   CAS_OIL_PRESS_LOW
--  ...   (see CAS_SI_NAMES in logic.lua)
-------------------------
-- CAS SUBSCRIPTIONS (SI + L-vars so either path can deliver)
-------------------------
local CAS_SI_NAMES = {
    "CAS_VOLTAGE_LOW",
    "CAS_OIL_PRESS_LOW",
    "CAS_FUEL_PRESS_LOW",
    "CAS_ENGINE_FIRE",
    "CAS_FUEL_SELECT_OFF",
    "CAS_FUEL_BOOST_ON",
    "CAS_IGNITION_ON",
    "CAS_STARTER_ON",
    "CAS_GENERATOR_OFF",
    "CAS_STBY_PWR_ON",
    "CAS_GENERATOR_OVERHEAT",
    "CAS_ALTERNATOR_OVERHEAT",
    "CAS_STBY_PWR_INOP",
    "CAS_FUEL_LOW_L",
    "CAS_FUEL_LOW_R",
    "CAS_FUEL_LOW_LR",
    "CAS_EMER_PWR_LVR",
    "CAS_RSVR_FUEL_LOW",
    "CAS_VOLTAGE_HIGH",
}

local function on_cas_value(idx, val)
    if val == nil then return end
    -- Treat any non-zero as "show" (handles INT 1, Number 1.0, string "1", or type quirks)
    local show = (type(val) == "number" and val ~= 0) or (val == true) or (val == 1) or (tostring(val) == "1")
    set_caution_visibility(idx, show, true)
end

-- Subscribe to SI variables (same-panel, works without sim)
if si_variable_subscribe then
    for i, name in ipairs(CAS_SI_NAMES) do
        local idx = i
        si_variable_subscribe(name, "INT", function(val) on_cas_value(idx, val) end)
    end
end

-- L-vars as backup delivery path (through simconnect, for when SI isn't available)
local CAS_LVARS = {
    "L:CAS_VOLTAGE_LOW",
    "L:CAS_OIL_PRESS_LOW",
    "L:CAS_FUEL_PRESS_LOW",
    "L:CAS_ENGINE_FIRE",
    "L:CAS_FUEL_SELECT_OFF",
    "L:CAS_FUEL_BOOST_ON",
    "L:CAS_IGNITION_ON",
    "L:CAS_STARTER_ON",
    "L:CAS_GENERATOR_OFF",
    "L:CAS_STBY_PWR_ON",
    "L:CAS_GENERATOR_OVERHEAT",
    "L:CAS_ALTERNATOR_OVERHEAT",
    "L:CAS_STBY_PWR_INOP",
    "L:CAS_FUEL_LOW_L",
    "L:CAS_FUEL_LOW_R",
    "L:CAS_FUEL_LOW_LR",
    "L:CAS_EMER_PWR_LVR",
    "L:CAS_RSVR_FUEL_LOW",
    "L:CAS_VOLTAGE_HIGH",
}
if fsx_variable_subscribe then
    for i, lvar in ipairs(CAS_LVARS) do
        local idx = i
        fsx_variable_subscribe(lvar, "Number", function(val) on_cas_value(idx, val) end)
    end
end

-------------------------------------------------
-- ADDITIONAL ANNUNCIATIONS (placeholders only)
-- These are examples for other CAS messages from
-- the POH tables you sent. They are commented
-- out until you decide exact L:vars / logic.
-------------------------------------------------

--========================
-- RED WARNINGS (examples)
--========================

-- VOLTAGE HIGH
-- fsx_variable_subscribe("ELECTRICAL MAIN BUS VOLTAGE", "Volts",
--     function(volts)
--         if volts == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_VOLTAGE_HIGH>, volts > 29, true)
--     end
-- )

-- RSERV FUEL LOW
-- fsx_variable_subscribe("L:RSVR_FUEL_QTY", "Gallons",
--     function(gal)
--         if gal == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_RSVR_FUEL_LOW>, gal < 10, true)
--     end
-- )

-- BATTERY OVHT
-- fsx_variable_subscribe("L:BATTERY_OVHT", "Bool",
--     function(on)
--         if on == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_BATTERY_OVHT>, on == 1 or on == true, true)
--     end
-- )

-- EMER PWR LVR
-- fsx_variable_subscribe("L:EMER_PWR_LVR", "Bool",
--     function(on)
--         if on == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_EMER_PWR_LVR>, on == 1 or on == true, true)
--     end
-- )

--========================
-- YELLOW CAUTIONS (examples)
--========================

-- FUEL BOOST ON (alternate L:var example)
-- fsx_variable_subscribe("L:FUEL_BOOST_ON", "Bool",
--     function(on)
--         if on == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_FUEL_BOOST_ON>, on == 1 or on == true, true)
--     end
-- )

-- DOOR UNLATCHED
-- fsx_variable_subscribe("L:DOOR_UNLATCHED", "Bool",
--     function(open)
--         if open == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_DOOR_UNLATCHED>, open == 1 or open == true, true)
--     end
-- )

-- BATTERY HOT
-- fsx_variable_subscribe("L:BATTERY_HOT", "Bool",
--     function(on)
--         if on == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_BATTERY_HOT>, on == 1 or on == true, true)
--     end
-- )

-- PROP DE-ICE
-- fsx_variable_subscribe("L:PROP_DEICE", "Bool",
--     function(on)
--         if on == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_PROP_DEICE>, on == 1 or on == true, true)
--     end
-- )

--========================
-- WHITE ADVISORIES (examples)
--========================

-- SPD NOT AVAIL
-- fsx_variable_subscribe("L:SPD_NOT_AVAIL", "Bool",
--     function(on)
--         if on == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_SPD_NOT_AVAIL>, on == 1 or on == true, true)
--     end
-- )

-- ETM EXCEED
-- fsx_variable_subscribe("L:ETM_EXCEED", "Bool",
--     function(on)
--         if on == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_ETM_EXCEED>, on == 1 or on == true, true)
--     end
-- )

-- FAN FAIL (generic example)
-- fsx_variable_subscribe("L:PFD1_FAN_FAIL", "Bool",
--     function(on)
--         if on == nil then return end
--         -- set_caution_visibility(<INDEX_FOR_PFD1_FAN_FAIL>, on == 1 or on == true, true)
--     end
-- )

-------------------------
-- BATTERY-DRIVEN PANEL VISIBILITY
-------------------------
local function set_cas_panel_visible(show)
    cas_panel_visible = show
    visible(img_text_panel, show)
    visible(img_button_panel, show)
    visible(txt_heading, show)
    for pos = 1, MAX_DISPLAY_POSITIONS do
        for i = 1, #cautions do
            if display_texts[pos] and display_texts[pos][i] then
                visible(display_texts[pos][i], show)
            end
            if display_blocks[pos] and display_blocks[pos][i] then
                visible(display_blocks[pos][i], false)
            end
        end
    end
    if show then
        update_panel()
    end
end

local function handle_battery_visibility(is_on)
    -- Stop any existing timer
    if cas_visibility_timer ~= nil then
        timer_stop(cas_visibility_timer)
        cas_visibility_timer = nil
    end

    if is_on then
        -- Powering UP: Show immediately
        set_cas_panel_visible(true)
        -- Force a re-render after a short delay to catch any SI/L-var timing issues
        if timer_start then
            cas_visibility_timer = timer_start(300, function()
                cas_visibility_timer = nil
                update_panel()
            end)
        end
    else
        -- Powering DOWN: Hide immediately
        set_cas_panel_visible(false)
    end
end

-- Primary: SI variable (same-panel, instant delivery — matches CAS caution subscription pattern)
if si_variable_subscribe then
    si_variable_subscribe("CAS_BATTERY_POWER", "INT", function(v)
        handle_battery_visibility(v == 1)
    end)
end

-- Fallback: L-var (through SimConnect, for when SI isn't available)
fsx_variable_subscribe("L:C208_BATTERY_SWITCH", "Number", function(v)
    handle_battery_visibility(v == 1)
end)

-------------------------
-- INIT
-------------------------
hide_all()
set_cas_panel_visible(false)  -- Start hidden until battery is turned on








