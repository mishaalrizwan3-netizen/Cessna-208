--=============================================================================
-- SIDE PANEL — Cessna 208
--=============================================================================
-- This script handles everything from engine gauges to the clickable button 
-- panel (Battery, GEN, ALT, etc.). It supports two instances in one panel:
--   Instance A: Side panel + Button panel (Main)
--   Instance B: Side panel only (Remote)
--=============================================================================
-- 0. GLOBAL API SAFEGUARDS (Prevents "Argument 3 is nil" crashes)
--=============================================================================
local original_fsx_variable_write = fsx_variable_write
fsx_variable_write = function(name, unit, value)
    if value == nil then
        -- print("DEBUG ALERT: Attempted to write NIL to " .. tostring(name) .. ". Redirecting to 0.")
        value = 0
    end
    if original_fsx_variable_write then
        original_fsx_variable_write(name, unit, value)
    end
end
--=============================================================================
-- PREPAR3D TURBOPROP ENGINE GAUGES
--=============================================================================
-- This gauge displays three engine parameters:
--   1. TRQ (Torque) - in foot-pounds
--   2. ITT (Inter Turbine Temperature) - in Celsius (converted from Rankine)
--   3. Ng (N1 - Low Pressure Compressor Speed) - in percent
--
-- TESTING IN PREPAR3D:
--   1. Make sure Air Manager is connected to Prepar3D
--   2. Load a turboprop aircraft (e.g., Cessna 208 Caravan, King Air, etc.)
--   3. Start the engine and watch the gauges
--   4. Check Air Manager console/log for debug output:
--      - "TRQ received: [value]"
--      - "ITT received (Rankine): [value]"
--      - "ITT converted (Celsius): [value]"
--   5. If values are nil or 0, the variable names may need adjustment
--   6. Once working, comment out the print() statements to disable debug output
--
--=============================================================================
--=============================================================================
-- 1. BACKGROUND AND NEEDLES SETUP
--=============================================================================
-- Panel visibility: driven only by L:PANEL_VISIBLE (0 = hidden, 1 = visible).
-- We run this SAME script twice (two instances) in one Air Manager panel:
--   Instance A: shows when L:PANEL_VISIBLE == 1 (the "main" with button panel)
--   Instance B: shows when L:PANEL_VISIBLE == 0 (the "remote" without button panel)
local my_instance = "A"
if si_variable_create then
    local ok, id = pcall(si_variable_create, "C208_SIDE_INSTANCE_A_CLAIMED", "BOOL", false)
    if ok and id ~= nil then
        local claimed = si_variable_read and si_variable_read(id) or false
        if not claimed then
            if si_variable_write then pcall(si_variable_write, id, true) end
            my_instance = "A"
        else
            my_instance = "B"
        end
    end
end
local function am_i_visible(lpanel_value)
    if my_instance == "A" then return lpanel_value == 1
    else return lpanel_value == 0 end
end
local current_lpanel_visible = 1
local panel_visible = am_i_visible(current_lpanel_visible)

-- Layout: like CAS.lua — side panel full width, gap, then button panel on the right (no overlap)
local MAIN_PANEL_WIDTH = 143
local MAIN_PANEL_HEIGHT = 646
local PANEL_GAP = 10
-- Button panel: two columns so more buttons can be added (col1 = left, col2 = right)
local LIGHT_BUTTON_PANEL_WIDTH = 184   -- 6 + 83 + 6 + 83 + 6 (margin, col1, gap, col2, margin)
local LIGHT_BUTTON_PANEL_HEIGHT = 820  -- taller than main panel to fit more buttons (main panel = 620)
local LIGHT_BUTTON_PANEL_X = MAIN_PANEL_WIDTH + PANEL_GAP  -- 153; button space to the right of side panel
-- Total instrument size: width = MAIN_PANEL_WIDTH + PANEL_GAP + LIGHT_BUTTON_PANEL_WIDTH = 337, height = LIGHT_BUTTON_PANEL_HEIGHT (set in Air Manager)

-- CAS: create SI variables FIRST so they exist before CAS instrument subscribes (panel load order).
-- Add this side-panel instrument to the panel BEFORE the CAS instrument.
gen_switch_on = false   -- OFF until Ng >= 35% (then auto-on)
alt_switch_on = false
battery_switch_on = false
fuel_boost_on = false
fuel_press = 0
boost_switch = 0
fuel_low_latch = false
engine_on = false
starter_switch_on = false
ignition_switch_on = false
generator_switch_on = true -- default to ON position at start
standby_power_switch_on = true -- default to ON position at start
fuel_condition_lever_pos = 0 -- 0=cutoff
ng_offset = 0
live_ng_value = 0
current_bus_volts = 0
current_bat_amps = 0
fuel_qty_left_lbs = 0
fuel_qty_right_lbs = 0
fuel_qty_left_gal = 0
fuel_qty_right_gal = 0
test_fire_detect_on = false
test_fuel_select_off_on = false
bleed_heat_on = false
cabin_heat_mix_gnd = false
fuel_oil_shutoff_on = false
emergency_power_lever_front = false
standby_power_switch_on = false -- initialized to false as it was originally

-- ENGINE STATE
live_ng_value = 0
ng_offset = 0
live_oil_pressure_psi = 0
fuel_pressure_psi = 0
fuel_qty_left_lbs = 0
fuel_qty_right_lbs = 0
fuel_qty_left_gal = 0    -- gallons (for RSVR FUEL LOW threshold)
fuel_qty_right_gal = 0   -- gallons
fuel_auto_boost_active = false
fuel_condition_lever_pos = 0
FUEL_PRESS_LOW_PSI  = 4.75
FUEL_PRESS_HIGH_PSI = 10.0
OIL_PRESS_LOW_PSI = 40.0
OIL_PRESS_STARTER_ON_PSI = 20.0

current_alt_amps  = 0

-- Table-Based Electrical Logic Variables
battery_charge = 1.0       -- 0.0 (empty) to 1.0 (full)
BATTERY_CHARGE_RATE = 0.0005 -- recharge rate per 500ms
BATTERY_DRAIN_RATE  = 0.0001 -- basic drain rate per 500ms

local CAS_SI_NAMES_EARLY = {
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
    "CAS_RSVR_FUEL_LOW",   -- index 18
    "CAS_VOLTAGE_HIGH",    -- index 19
}
cas_si_ids = {}
if si_variable_create then
    for i = 1, #CAS_SI_NAMES_EARLY do
        local ok, id = pcall(si_variable_create, CAS_SI_NAMES_EARLY[i], "INT", 0)
        cas_si_ids[i] = (ok and id ~= nil) and id or nil
    end
    -- Battery power SI variable so CAS panel can show/hide based on battery state
    local ok_bat, id_bat = pcall(si_variable_create, "CAS_BATTERY_POWER", "INT", 0)
    cas_battery_si_id = (ok_bat and id_bat ~= nil) and id_bat or nil
end
-- CAS state (global so button callbacks can use it before CAS CONNECTION section runs)
cas_fictitious = {}
sim_cas = {}
for i = 1, 47 do cas_fictitious[i] = 0; sim_cas[i] = 0 end

-- Main background: side panel only (no overlap)
local img_side_panel_bg = img_add("sidePanel.png", 0, 0, MAIN_PANEL_WIDTH, MAIN_PANEL_HEIGHT)

-- Light button panel created later (after gauges/overlay) so it draws on top and stays visible
local img_light_button_panel

-- TRQ: Small 15x15 pointer for orbital movement along the arc
img_trq = img_add("pointer.png", 71.5 - 7.5, 105 - 7.5, 15, 15)

-- ITT: Small 15x15 pointer for orbital movement along the arc
img_itt = img_add("pointer.png", 71.5 - 7.5, 175 - 7.5, 15, 15)

-- Ng: Small 15x15 pointer for orbital movement along the arc
img_ng  = img_add("pointer.png", 20 - 7.5, 265 - 7.5, 15, 15)

-- Oil Pressure: Small 15x15 pointer for linear movement
img_oil_pres = img_add("pointer1.png", 71.5 - 7.5, 330 - 7.5, 15, 15)

-- Oil Temperature: Small 15x15 pointer for linear movement
img_oil_temp = img_add("pointer1.png", 16 - 7.5, 385 - 7.5, 15, 15)

-- Fuel Quantity Left: Small 15x15 pointer for vertical movement
img_fuel_qty_left = img_add("pointerleft.png", 25 - 7.5, 530 - 7.5, 15, 15)

-- Fuel Quantity Right: Small 15x15 pointer for vertical movement
img_fuel_qty_right = img_add("pointerright.png", 115 - 7.5, 530 - 7.5, 15, 15)   

-- Numeric readouts (positions tuned for 143px-wide side panel)
txt_trq = txt_add("0", "size:20; color: white; halign:right; weight:bold;", 95, 95, 40, 24)
txt_itt = txt_add("0", "size:20; color: white; halign:right; weight:bold;", 95, 175, 40, 24)
txt_ng  = txt_add("0.0", "size:20; color: white; halign:right; weight:bold;", 86, 246, 55, 24)

-- Prop RPM digital display
txt_prop_rpm = txt_add("0", "size:20; color: white; halign:right;", 95, 280, 40, 24)

--=============================================================================
-- OVERLAY PANEL (Below PROP RPM - Toggle with Button)
--=============================================================================
local overlay_visible = false
local OVERLAY_START_Y = 310  -- Start below PROP RPM (280 + 30)
local OVERLAY_LINE_HEIGHT = 18
local OVERLAY_SPACING = 2

-- Store current values for restoration when overlay is hidden
local current_bat_amps = 0
local current_bus_volts = 0.0

img_overlay_bg = img_add("overlay.png", -200, OVERLAY_START_Y, 143, 300)
local has_overlay_bg = img_overlay_bg ~= nil  -- overlay image is optional; guard all uses

-- Only create text elements for dynamic values (numbers that change)
txt_overlay_qty_l_val = txt_add("0", "size:17; color:white; halign:right;", 75, OVERLAY_START_Y + 25, 65, OVERLAY_LINE_HEIGHT)
txt_overlay_qty_r_val = txt_add("0", "size:17; color:white; halign:right;", 75, OVERLAY_START_Y + 45, 65, OVERLAY_LINE_HEIGHT)
txt_overlay_fflow_val = txt_add("0", "size:17; color:white; halign:right;", 75, OVERLAY_START_Y + 69, 65, OVERLAY_LINE_HEIGHT)
txt_overlay_lb_rem_val = txt_add("0.0", "size:17; color:white; halign:right;", 75, OVERLAY_START_Y + 125, 65, OVERLAY_LINE_HEIGHT)
txt_overlay_lb_used_val = txt_add("0.0", "size:17; color:white; halign:right;", 75, OVERLAY_START_Y + 145, 65, OVERLAY_LINE_HEIGHT)
txt_overlay_gen_amps_val = txt_add("0", "size:17; color:white; halign:right;", 75, OVERLAY_START_Y + 190, 65, OVERLAY_LINE_HEIGHT)
txt_overlay_alt_amps_val = txt_add("0", "size:17; color:white; halign:right;", 75, OVERLAY_START_Y + 210, 65, OVERLAY_LINE_HEIGHT)
txt_overlay_bat_amps_val = txt_add("0", "size:17; color:white; halign:right;", 75, OVERLAY_START_Y + 230, 65, OVERLAY_LINE_HEIGHT)
txt_overlay_bus_volts_val = txt_add("0.0", "size:17; color:white; halign:right;", 75, OVERLAY_START_Y + 250, 65, OVERLAY_LINE_HEIGHT)

-- Hide all value text elements initially
txt_set(txt_overlay_qty_l_val, "")
txt_set(txt_overlay_qty_r_val, "")
txt_set(txt_overlay_fflow_val, "")
txt_set(txt_overlay_lb_rem_val, "")
txt_set(txt_overlay_lb_used_val, "")
txt_set(txt_overlay_gen_amps_val, "")
txt_set(txt_overlay_alt_amps_val, "")
txt_set(txt_overlay_bat_amps_val, "")
txt_set(txt_overlay_bus_volts_val, "")

-- Apply current overlay + panel state to visuals
function apply_overlay_state()
    if panel_visible and overlay_visible then
        -- Show overlay background and digits (if the image exists)
        if has_overlay_bg then
            visible(img_overlay_bg, true)
            img_move(img_overlay_bg, 0, OVERLAY_START_Y, 143, 300)
        end
        -- Make overlay text elements visible (they will be updated by subscriptions)
        if txt_overlay_qty_l_val then visible(txt_overlay_qty_l_val, true) end
        if txt_overlay_qty_r_val then visible(txt_overlay_qty_r_val, true) end
        if txt_overlay_fflow_val then visible(txt_overlay_fflow_val, true) end
        if txt_overlay_lb_rem_val then visible(txt_overlay_lb_rem_val, true) end
        if txt_overlay_lb_used_val then visible(txt_overlay_lb_used_val, true) end
        if txt_overlay_gen_amps_val then visible(txt_overlay_gen_amps_val, true) end
        if txt_overlay_alt_amps_val then visible(txt_overlay_alt_amps_val, true) end
        if txt_overlay_bat_amps_val then visible(txt_overlay_bat_amps_val, true) end
        if txt_overlay_bus_volts_val then visible(txt_overlay_bus_volts_val, true) end
        if txt_overlay_qty_l_val then txt_set(txt_overlay_qty_l_val, "0") end
        if txt_overlay_qty_r_val then txt_set(txt_overlay_qty_r_val, "0") end
        if txt_overlay_fflow_val then txt_set(txt_overlay_fflow_val, "0") end
        if txt_overlay_lb_rem_val then txt_set(txt_overlay_lb_rem_val, "0.0") end
        if txt_overlay_lb_used_val then txt_set(txt_overlay_lb_used_val, "0.0") end
        if txt_overlay_gen_amps_val then txt_set(txt_overlay_gen_amps_val, "0") end
        if txt_overlay_alt_amps_val then txt_set(txt_overlay_alt_amps_val, "0") end
        if txt_overlay_bat_amps_val then txt_set(txt_overlay_bat_amps_val, string.format("%d", math.floor(current_bat_amps + 0.5))) end
        if txt_overlay_bus_volts_val then txt_set(txt_overlay_bus_volts_val, string.format("%.1f", current_bus_volts)) end
        -- Hide underlying base digits so they don’t overlap
        if txt_oil_pres then txt_set(txt_oil_pres, "") end
        if txt_oil_temp then txt_set(txt_oil_temp, "") end
        if txt_fuel_flow then txt_set(txt_fuel_flow, "") end
        if txt_bat_amps then txt_set(txt_bat_amps, "") end
        if txt_bus_volts then txt_set(txt_bus_volts, "") end
        -- Hide needles under overlay area
        if img_oil_pres then visible(img_oil_pres, false) end
        if img_oil_temp then visible(img_oil_temp, false) end
        if img_fuel_qty_left then visible(img_fuel_qty_left, false) end
        if img_fuel_qty_right then visible(img_fuel_qty_right, false) end
    else
        -- Hide overlay background and digits (use visible() so text nodes are fully hidden)
        if has_overlay_bg then
            if img_overlay_bg then visible(img_overlay_bg, false) end
            if img_overlay_bg then img_move(img_overlay_bg, -200, OVERLAY_START_Y, 143, 300) end
        end
        if txt_overlay_qty_l_val then visible(txt_overlay_qty_l_val, false) end
        if txt_overlay_qty_r_val then visible(txt_overlay_qty_r_val, false) end
        if txt_overlay_fflow_val then visible(txt_overlay_fflow_val, false) end
        if txt_overlay_lb_rem_val then visible(txt_overlay_lb_rem_val, false) end
        if txt_overlay_lb_used_val then visible(txt_overlay_lb_used_val, false) end
        if txt_overlay_gen_amps_val then visible(txt_overlay_gen_amps_val, false) end
        if txt_overlay_alt_amps_val then visible(txt_overlay_alt_amps_val, false) end
        if txt_overlay_bat_amps_val then visible(txt_overlay_bat_amps_val, false) end
        if txt_overlay_bus_volts_val then visible(txt_overlay_bus_volts_val, false) end
        if txt_overlay_qty_l_val then txt_set(txt_overlay_qty_l_val, "") end
        if txt_overlay_qty_r_val then txt_set(txt_overlay_qty_r_val, "") end
        if txt_overlay_fflow_val then txt_set(txt_overlay_fflow_val, "") end
        if txt_overlay_lb_rem_val then txt_set(txt_overlay_lb_rem_val, "") end
        if txt_overlay_lb_used_val then txt_set(txt_overlay_lb_used_val, "") end
        if txt_overlay_gen_amps_val then txt_set(txt_overlay_gen_amps_val, "") end
        if txt_overlay_alt_amps_val then txt_set(txt_overlay_alt_amps_val, "") end
        if txt_overlay_bat_amps_val then txt_set(txt_overlay_bat_amps_val, "") end
        if txt_overlay_bus_volts_val then txt_set(txt_overlay_bus_volts_val, "") end
        -- Restore base digits if panel is visible
        if panel_visible then
            if txt_oil_pres then txt_set(txt_oil_pres, "0") end
            if txt_oil_temp then txt_set(txt_oil_temp, "0") end
            if txt_fuel_flow then txt_set(txt_fuel_flow, "0") end
            if txt_bat_amps then txt_set(txt_bat_amps, string.format("%d", math.floor(current_bat_amps + 0.5))) end
            if txt_bus_volts then txt_set(txt_bus_volts, string.format("%.1f", current_bus_volts)) end
            -- Show needles again
            if img_oil_pres then visible(img_oil_pres, true) end
            if img_oil_temp then visible(img_oil_temp, true) end
            if img_fuel_qty_left then visible(img_fuel_qty_left, true) end
            if img_fuel_qty_right then visible(img_fuel_qty_right, true) end
        end
    end
end

-- Toggle overlay logical state and re-apply visuals
function toggle_overlay()
    overlay_visible = not overlay_visible
    apply_overlay_state()
    if si_overlay_visible then si_variable_write(si_overlay_visible, overlay_visible) end
    fsx_variable_write("L:C208_OVERLAY_VISIBLE", "Bool", overlay_visible)
end

-- Button to toggle overlay (click PROP RPM area)
button_add(nil, nil, 95, 280, 40, 24,
    function()
        toggle_overlay()
    end,
    nil
)

--=============================================================================
-- PANEL VISIBILITY — toggle view of main and remote (driven by L:PANEL_VISIBLE)
--=============================================================================
-- Main (Instance A) visible when L:PANEL_VISIBLE == 1. Remote (Instance B) when == 0.
-- Toggle via: click top-left 40x40, BU0836X button 1, or L:PANEL_VISIBLE write.
-- Both instruments must be in the SAME Air Manager panel to sync.
-- Apply current panel_visible state to visuals (show or move all images/text off-screen)
function apply_panel_visibility()
    if panel_visible then
        -- Show background
        if img_side_panel_bg then visible(img_side_panel_bg, true) end
        -- Show all pointers and restore to original positions
        if img_trq then visible(img_trq, true) end
        if img_itt then visible(img_itt, true) end
        if img_ng then visible(img_ng, true) end
        if img_oil_pres then visible(img_oil_pres, true) end
        if img_oil_temp then visible(img_oil_temp, true) end
        if img_fuel_qty_left then visible(img_fuel_qty_left, true) end
        if img_fuel_qty_right then visible(img_fuel_qty_right, true) end
        if img_trq then img_move(img_trq, 71.5 - 7.5, 105 - 7.5, 15, 15) end
        if img_itt then img_move(img_itt, 71.5 - 7.5, 175 - 7.5, 15, 15) end
        if img_ng then img_move(img_ng, 20 - 7.5, 265 - 7.5, 15, 15) end
        if img_oil_pres then img_move(img_oil_pres, 71.5 - 7.5, 330 - 7.5, 15, 15) end
        if img_oil_temp then img_move(img_oil_temp, 16 - 7.5, 385 - 7.5, 15, 15) end
        if img_fuel_qty_left then img_move(img_fuel_qty_left, 25 - 7.5, 530 - 7.5, 15, 15) end
        if img_fuel_qty_right then img_move(img_fuel_qty_right, 115 - 7.5, 530 - 7.5, 15, 15) end
        if txt_trq then visible(txt_trq, true) end
        if txt_itt then visible(txt_itt, true) end
        if txt_ng then visible(txt_ng, true) end
        if txt_prop_rpm then visible(txt_prop_rpm, true) end
        if txt_oil_pres then visible(txt_oil_pres, true) end
        if txt_oil_temp then visible(txt_oil_temp, true) end
        if txt_fuel_flow then visible(txt_fuel_flow, true) end
        if txt_bat_amps then visible(txt_bat_amps, true) end
        if txt_bus_volts then visible(txt_bus_volts, true) end
        if txt_trq then txt_set(txt_trq, "0") end
        if txt_itt then txt_set(txt_itt, "0") end
        if txt_ng then txt_set(txt_ng, "0.0") end
        if txt_prop_rpm then txt_set(txt_prop_rpm, "0") end
        if txt_oil_pres then txt_set(txt_oil_pres, "0") end
        if txt_oil_temp then txt_set(txt_oil_temp, "0") end
        if txt_fuel_flow then txt_set(txt_fuel_flow, "0") end
        if txt_bat_amps then txt_set(txt_bat_amps, "0") end
        if txt_bus_volts then txt_set(txt_bus_volts, "0.0") end
        -- Hide soft button panel on both main and remote: no soft buttons visible
        if img_light_button_panel then visible(img_light_button_panel, false) end
        if txt_light_heading then visible(txt_light_heading, false) end
        if txt_light_1 then visible(txt_light_1, false) end
        if txt_light_2 then visible(txt_light_2, false) end
        if txt_light_3 then visible(txt_light_3, false) end
        if txt_cas_battery then visible(txt_cas_battery, false) end
        if txt_cas_gen then visible(txt_cas_gen, false) end
        if txt_cas_alt then visible(txt_cas_alt, false) end
        if txt_cas_fuel then visible(txt_cas_fuel, false) end
        if txt_ignition then visible(txt_ignition, false) end
        if txt_cas_starter then visible(txt_cas_starter, false) end
        if txt_fuel_tank_left then visible(txt_fuel_tank_left, false) end
        if txt_fuel_tank_right then visible(txt_fuel_tank_right, false) end
        if txt_cond_lever then visible(txt_cond_lever, false) end
        if txt_temp_ctrl then visible(txt_temp_ctrl, false) end
        if txt_bleed_heat then visible(txt_bleed_heat, false) end
        if txt_cabin_heat_mix then visible(txt_cabin_heat_mix, false) end
        if txt_fuel_oil_shutoff then visible(txt_fuel_oil_shutoff, false) end
        if txt_emerge_pwr_lever then visible(txt_emerge_pwr_lever, false) end
        if txt_cas_test_fire then visible(txt_cas_test_fire, false) end
        if txt_cas_test_fuel_sel then visible(txt_cas_test_fuel_sel, false) end
        if overlay_visible then
            if has_overlay_bg then
                img_move(img_overlay_bg, 0, OVERLAY_START_Y, 143, 300)
            end
            if txt_overlay_qty_l_val then txt_set(txt_overlay_qty_l_val, "0") end
            if txt_overlay_qty_r_val then txt_set(txt_overlay_qty_r_val, "0") end
            if txt_overlay_fflow_val then txt_set(txt_overlay_fflow_val, "0") end
            if txt_overlay_lb_rem_val then txt_set(txt_overlay_lb_rem_val, "0.0") end
            if txt_overlay_lb_used_val then txt_set(txt_overlay_lb_used_val, "0.0") end
            if txt_overlay_gen_amps_val then txt_set(txt_overlay_gen_amps_val, "0") end
            if txt_overlay_alt_amps_val then txt_set(txt_overlay_alt_amps_val, "0") end
            if txt_overlay_bat_amps_val then txt_set(txt_overlay_bat_amps_val, string.format("%d", math.floor(current_bat_amps + 0.5))) end
            if txt_overlay_bus_volts_val then txt_set(txt_overlay_bus_volts_val, string.format("%.1f", current_bus_volts)) end
            if txt_oil_pres then txt_set(txt_oil_pres, "") end
            if txt_oil_temp then txt_set(txt_oil_temp, "") end
            if txt_fuel_flow then txt_set(txt_fuel_flow, "") end
            if txt_bat_amps then txt_set(txt_bat_amps, "") end
            if txt_bus_volts then txt_set(txt_bus_volts, "") end
        end
    else
        if img_side_panel_bg then visible(img_side_panel_bg, false) end
        -- Hide all pointers when panel is hidden
        if img_trq then visible(img_trq, false) end
        if img_itt then visible(img_itt, false) end
        if img_ng then visible(img_ng, false) end
        if img_oil_pres then visible(img_oil_pres, false) end
        if img_oil_temp then visible(img_oil_temp, false) end
        if img_fuel_qty_left then visible(img_fuel_qty_left, false) end
        if img_fuel_qty_right then visible(img_fuel_qty_right, false) end
        if img_trq then img_move(img_trq, -200, -200, 15, 15) end
        if img_itt then img_move(img_itt, -200, -200, 15, 15) end
        if img_ng then img_move(img_ng, -200, -200, 15, 15) end
        if img_oil_pres then img_move(img_oil_pres, -200, -200, 15, 15) end
        if img_oil_temp then img_move(img_oil_temp, -200, -200, 15, 15) end
        if img_fuel_qty_left then img_move(img_fuel_qty_left, -200, -200, 15, 15) end
        if img_fuel_qty_right then img_move(img_fuel_qty_right, -200, -200, 15, 15) end
        if txt_trq then visible(txt_trq, false) end
        if txt_itt then visible(txt_itt, false) end
        if txt_ng then visible(txt_ng, false) end
        if txt_prop_rpm then visible(txt_prop_rpm, false) end
        if txt_oil_pres then visible(txt_oil_pres, false) end
        if txt_oil_temp then visible(txt_oil_temp, false) end
        if txt_fuel_flow then visible(txt_fuel_flow, false) end
        if txt_bat_amps then visible(txt_bat_amps, false) end
        if txt_bus_volts then visible(txt_bus_volts, false) end
        if txt_trq then txt_set(txt_trq, "") end
        if txt_itt then txt_set(txt_itt, "") end
        if txt_ng then txt_set(txt_ng, "") end
        if txt_prop_rpm then txt_set(txt_prop_rpm, "") end
        if txt_oil_pres then txt_set(txt_oil_pres, "") end
        if txt_oil_temp then txt_set(txt_oil_temp, "") end
        if txt_fuel_flow then txt_set(txt_fuel_flow, "") end
        if txt_bat_amps then txt_set(txt_bat_amps, "") end
        if txt_bus_volts then txt_set(txt_bus_volts, "") end
        if img_light_button_panel then visible(img_light_button_panel, false) end
        if txt_light_heading then visible(txt_light_heading, false) end
        if txt_light_1 then visible(txt_light_1, false) end
        if txt_light_2 then visible(txt_light_2, false) end
        if txt_light_3 then visible(txt_light_3, false) end
        if txt_cas_battery then visible(txt_cas_battery, false) end
        if txt_cas_gen then visible(txt_cas_gen, false) end
        if txt_cas_alt then visible(txt_cas_alt, false) end
        if txt_cas_fuel then visible(txt_cas_fuel, false) end
        if txt_ignition then visible(txt_ignition, false) end
        if txt_cas_starter then visible(txt_cas_starter, false) end
        if txt_fuel_tank_left then visible(txt_fuel_tank_left, false) end
        if txt_fuel_tank_right then visible(txt_fuel_tank_right, false) end
        if txt_cond_lever then visible(txt_cond_lever, false) end
        if txt_temp_ctrl then visible(txt_temp_ctrl, false) end
        if txt_bleed_heat then visible(txt_bleed_heat, false) end
        if txt_cabin_heat_mix then visible(txt_cabin_heat_mix, false) end
        if txt_fuel_oil_shutoff then visible(txt_fuel_oil_shutoff, false) end
        if txt_emerge_pwr_lever then visible(txt_emerge_pwr_lever, false) end
        if txt_cas_test_fire then visible(txt_cas_test_fire, false) end
        if txt_cas_test_fuel_sel then visible(txt_cas_test_fuel_sel, false) end
        -- Hide overlay and all overlay digits (visible() hides text nodes fully)
        if has_overlay_bg then
            if img_overlay_bg then visible(img_overlay_bg, false) end
            if img_overlay_bg then img_move(img_overlay_bg, -200, OVERLAY_START_Y, 143, 300) end
        end
        if txt_overlay_qty_l_val then visible(txt_overlay_qty_l_val, false) end
        if txt_overlay_qty_r_val then visible(txt_overlay_qty_r_val, false) end
        if txt_overlay_fflow_val then visible(txt_overlay_fflow_val, false) end
        if txt_overlay_lb_rem_val then visible(txt_overlay_lb_rem_val, false) end
        if txt_overlay_lb_used_val then visible(txt_overlay_lb_used_val, false) end
        if txt_overlay_gen_amps_val then visible(txt_overlay_gen_amps_val, false) end
        if txt_overlay_alt_amps_val then visible(txt_overlay_alt_amps_val, false) end
        if txt_overlay_bat_amps_val then visible(txt_overlay_bat_amps_val, false) end
        if txt_overlay_bus_volts_val then visible(txt_overlay_bus_volts_val, false) end
        if txt_overlay_qty_l_val then txt_set(txt_overlay_qty_l_val, "") end
        if txt_overlay_qty_r_val then txt_set(txt_overlay_qty_r_val, "") end
        if txt_overlay_fflow_val then txt_set(txt_overlay_fflow_val, "") end
        if txt_overlay_lb_rem_val then txt_set(txt_overlay_lb_rem_val, "") end
        if txt_overlay_lb_used_val then txt_set(txt_overlay_lb_used_val, "") end
        if txt_overlay_gen_amps_val then txt_set(txt_overlay_gen_amps_val, "") end
        if txt_overlay_alt_amps_val then txt_set(txt_overlay_alt_amps_val, "") end
        if txt_overlay_bat_amps_val then txt_set(txt_overlay_bat_amps_val, "") end
        if txt_overlay_bus_volts_val then txt_set(txt_overlay_bus_volts_val, "") end
    end
    apply_overlay_state()
end

-- Toggle L:PANEL_VISIBLE (0 <-> 1). Both instruments must be in the SAME panel to sync.
function toggle_panel_visible()
    local new_val = 1 - (current_lpanel_visible or 1)
    fsx_variable_write("L:PANEL_VISIBLE", "Number", new_val)
    current_lpanel_visible = new_val
    panel_visible = am_i_visible(new_val)
    apply_panel_visibility()
end

--=============================================================================
-- BU0836X JOYSTICK BUTTON SUPPORT
--=============================================================================
-- Support for BU0836X interface button to toggle overlay
print("Registering BU0836X JOYSTICK BUTTON for overlay toggle...")

-- Method 1: Direct hardware button (if Air Manager detects BU0836X as joystick)
-- The BU0836X typically appears as JOYSTICK_1, JOYSTICK_2, etc. in Air Manager
-- Check Air Manager Hardware tab to find your joystick ID
-- Button numbers start from 0 (BUTTON_0, BUTTON_1, BUTTON_2, etc.)

-- Uncomment and modify ONE of these lines with your button number:
-- Replace BUTTON_0 with your desired button (BUTTON_1, BUTTON_2, etc.)
-- Replace JOYSTICK_1 with your actual joystick ID if different

-- Example for button 1 on joystick 1:
-- hw_button_add("JOYSTICK_1_BUTTON_1", function() toggle_overlay() end)

-- Example for button 5 on joystick 1:
-- hw_button_add("JOYSTICK_1_BUTTON_5", function() toggle_overlay() end)

-- Try to auto-detect common joystick IDs
-- In Air Manager 5, check Hardware tab to find your BU0836X joystick ID
local joystick_detected = false

-- Method: Try common joystick IDs and button numbers
-- You can modify these to match your setup
local joystick_ids = {"JOYSTICK_1", "JOYSTICK_2", "JOYSTICK_3"}
local button_numbers = {0, 1, 2, 3, 4, 5}  -- Try buttons 0-5

for _, joy_id in ipairs(joystick_ids) do
    if not joystick_detected then
        for _, btn_num in ipairs(button_numbers) do
            local success, err = pcall(function()
                if hw_button_add then
                    local button_id = joy_id .. "_BUTTON_" .. btn_num
                    hw_button_add(button_id, function() toggle_overlay() end)
                    print("BU0836X: Successfully registered " .. button_id)
                    joystick_detected = true
                    return true
                end
            end)
            if success and joystick_detected then
                break
            end
        end
    end
end

if not joystick_detected then
    print("BU0836X: Direct hardware button not auto-detected")
    print("BU0836X: Use Air Manager 5 Hardware tab to configure:")
    print("BU0836X:   1. Go to Hardware tab")
    print("BU0836X:   2. Find your BU0836X joystick")
    print("BU0836X:   3. Add button and set it to write L:OverlayToggleButton = 1")
    print("BU0836X: Or manually uncomment/modify hw_button_add line below")
    
    -- Manual setup - uncomment and modify this line with your joystick ID and button:
    -- hw_button_add("JOYSTICK_1_BUTTON_1", function() toggle_overlay() end)
end

-- Method 2: L-variable subscription (works with FSUIPC or other systems)
-- FSUIPC can map BU0836X button to write to L:OverlayToggleButton
local last_button_state = 0
fsx_variable_subscribe("L:OverlayToggleButton", "Number",
    function(button_value)
        if button_value == nil or button_value ~= button_value then return end
        
        -- Detect button press (transition from 0 to non-zero)
        if button_value ~= nil and button_value ~= 0 and last_button_state == 0 then
            toggle_overlay()
            -- Reset the button state to allow next press
            fsx_variable_write("L:OverlayToggleButton", "Number", 0)
        end
        
        last_button_state = button_value or 0
    end
)
print("BU0836X: L-variable method ready - map button to L:OverlayToggleButton in FSUIPC")
print("BU0836X: In FSUIPC Buttons tab, assign button to write 1 to L:OverlayToggleButton")

-- Oil Pressure digital display
txt_oil_pres = txt_add("0", "size:20; color: white; halign:right;", 95, 315, 40, 24)

-- Oil Temperature digital display
txt_oil_temp = txt_add("0", "size:20; color: white; halign:right;", 95, 360, 40, 24)

-- Fuel Flow (PPH) digital display
txt_fuel_flow = txt_add("0", "size:20; color: white; halign:right;", 95, 538, 40, 24)

-- Battery Amps digital display
txt_bat_amps = txt_add("0", "size:20; color: white; halign:right;", 95, 570, 40, 24)

-- Bus Volts digital display
txt_bus_volts = txt_add("0.0", "size:20; color: white; halign:right;", 95, 593, 40, 24)

--=============================================================================
-- LIGHTS state and get_light_load_amps (must be before ELECTRICAL BRIDGE callback)
--=============================================================================
-- Buttons work with or without Prepar3D. Custom amps per switch drive the electrical display.
--
-- What happens to GEN / ALT / BAT amps and BUS VOLTS when lights are on:
--   • Bus load amps = (sim bus amps or 0) + light load (beacon 5A + landing 3A + strobe 2A).
--   • Bus volts = (sim bus volts or 28.0) - (light_load_amps * 0.05). More lights = lower voltage.
--   • Active source (GEN / ALT / BAT) is chosen by sim switches; if GEN on → GEN carries load;
--     if ALT on (GEN off) → ALT carries load; else BAT carries load (discharge).
--   • GEN amps: when generator is active, shows total bus load (including lights).
--   • ALT amps: when alternator is active, shows total bus load (including lights).
--   • BAT amps: when battery is active, shows negative discharge (e.g. -5A beacon only, -10A all three).
--
local LIGHTS = {
    { name = "Beacon",          lvar = "TOGGLE_BEACON_LIGHTS",     amp_lvar = "L:C208_AMPS_BEACON",     amps = 1, is_sim = true },
    { name = "Landing Left",    lvar = "LANDING_LIGHTS_TOGGLE",    amp_lvar = "L:C208_AMPS_LANDING_L",   amps = 6, is_sim = true },
    { name = "Landing Right",   lvar = "LANDING_LIGHTS_TOGGLE",    amp_lvar = "L:C208_AMPS_LANDING_R",   amps = 6, is_sim = true },
    { name = "Taxi",            lvar = "TOGGLE_TAXI_LIGHTS",       amp_lvar = "L:C208_AMPS_TAXI",        amps = 4, is_sim = true },
    { name = "Strobe",          lvar = "STROBES_TOGGLE",           amp_lvar = "L:C208_AMPS_STROBE",      amps = 2, is_sim = true },
    { name = "Nav",             lvar = "TOGGLE_NAV_LIGHTS",        amp_lvar = "L:C208_AMPS_NAV",         amps = 1, is_sim = true },
    { name = "Cabin",           lvar = "TOGGLE_CABIN_LIGHTS",      amp_lvar = "L:C208_AMPS_CABIN",       amps = 2, is_sim = true },
    { name = "Avionics 1",      lvar = "L:ASD_SWITCH_AVIONICS_N01", amp_lvar = "L:C208_AMPS_AVIONICS_1",  amps = 13 },
    { name = "Avionics 2",      lvar = "L:ASD_SWITCH_AVIONICS_N02", amp_lvar = "L:C208_AMPS_AVIONICS_2",  amps = 15 },
    { name = "Anti-Ice Wing",   lvar = "TOGGLE_WING_LIGHTS",       amp_lvar = "L:C208_AMPS_ANTI_ICE_W",  amps = 4, is_sim = true },
    { name = "Stall Heat",      lvar = "PITOT_HEAT_TOGGLE",             amp_lvar = "L:C208_AMPS_STALL_HEAT",  amps = 10, is_sim = true },
    { name = "Windshield Heat", lvar = "L:WINDSHIELD_HEAT",        amp_lvar = "L:C208_AMPS_WIND_HEAT",   amps = 25 },
    { name = "Fuel Boost",      lvar = "L:ASD_SWITCH_FUEL_AUXBP",  amp_lvar = "L:C208_AMPS_FUEL_BOOST",  amps = 4 },
}
local light_on = {}
for i = 1, #LIGHTS do light_on[i] = false end

local function get_light_load_amps()
    local total = 0
    for i = 1, #LIGHTS do
        if light_on[i] then total = total + (LIGHTS[i].amps or 0) end
    end
    return total
end

--=============================================================================
-- ELECTRICAL SYSTEM OVERRIDE (Fictitious Simulation)
--=============================================================================
function apply_light_load_to_electrical()
    local light_load = get_light_load_amps()
    
    local volts = 0
    local bat_amps = 0
    local gen_amps = 0
    local alt_amps = 0
    
    if not battery_switch_on then
        volts = 0
        bat_amps = 0
        gen_amps = 0
        alt_amps = 0
    elseif starter_switch_on then
        -- Starter/Start phases from table
        if live_ng_value < 10 then
            -- Starter engaged: 18-22 V, -200 to -300 A
            volts = 20.0 
            bat_amps = -(250 + light_load)
        else
            -- Light-off / Ng rising: 20-24 V, -100 to -200 A
            volts = 22.0
            bat_amps = -(150 + light_load)
        end
        gen_amps = 0
        alt_amps = 0
    elseif gen_switch_on then
        -- Generator sources: 28 V range
        volts = 28.2 
        
        -- BAT Amps depends on charge state according to table ranges
        if battery_charge < 0.9 then
            -- Starter OFF (GEN comes online): +20 to +40 A
            bat_amps = 30
            volts = 28.3 
        elseif battery_charge < 0.98 then
            -- Stabilized idle (recharge reducing): +5 to +15 A
            bat_amps = 10
            volts = 28.0
        else
            -- Normal (fully charged or near full): 0 to +5 A
            bat_amps = 2
            volts = 28.0
        end
        
        -- GEN Amps = Recharge + System Load
        -- System load baseline is ~15-20A (Normal avionics) or 30-45A (Night/Lights)
        local system_load = 18 + light_load
        gen_amps = bat_amps + system_load
        alt_amps = 0
    elseif alt_switch_on then
        -- Standby alternator ON: ~27 V, BAT ~0
        volts = 27.0
        bat_amps = 0
        gen_amps = 0
        alt_amps = 15 + light_load -- 15A baseline
    else
        -- Battery Power Only (Engine OFF or GEN failure)
        if live_ng_value > 15 then
            -- GEN failure (battery only): 24 -> 22 V
            volts = 23.0
            bat_amps = -(15 + light_load)
        elseif light_load > 10 then
            -- Avionics ON (pre-start): 23.5 - 24.5 V, -10 to -20 A
            volts = 24.0
            bat_amps = -(15 + light_load)
        else
            -- Battery ON (engine OFF): 24.0 - 25.5 V, -5 to -15 A
            volts = 25.0
            bat_amps = -(7 + light_load)
        end
        gen_amps = 0
        alt_amps = 0
    end
    
    current_bus_volts = volts
    current_bat_amps = bat_amps
    current_gen_amps = gen_amps
    current_alt_amps = alt_amps
    
    -- Update UI
    if txt_bat_amps then
        if overlay_visible then
            if txt_overlay_bat_amps_val then txt_set(txt_overlay_bat_amps_val, string.format("%d", math.floor(bat_amps + 0.5))) end
        else
            txt_set(txt_bat_amps, string.format("%d", math.floor(bat_amps + 0.5)))
        end
    end
    
    if txt_bus_volts then
        if overlay_visible then
            if txt_overlay_bus_volts_val then txt_set(txt_overlay_bus_volts_val, string.format("%.1f", volts)) end
        else
            txt_set(txt_bus_volts, string.format("%.1f", volts))
        end
    end
    
    if txt_overlay_gen_amps_val then
        txt_set(txt_overlay_gen_amps_val, string.format("%d", math.floor(gen_amps + 0.5)))
    end
    
    if txt_overlay_alt_amps_val then
        txt_set(txt_overlay_alt_amps_val, string.format("%d", math.floor(alt_amps + 0.5)))
    end
    
    -- Sync L-vars
    if fsx_variable_write then
        pcall(fsx_variable_write, "L:BUS_VOLTS", "Volts", volts)
        pcall(fsx_variable_write, "L:BAT_AMPS", "Amperes", bat_amps)
        pcall(fsx_variable_write, "L:GEN_AMPS", "Amperes", gen_amps)
        pcall(fsx_variable_write, "L:ALT_AMPS", "Amperes", alt_amps)
    end
    
    -- Update CAS logic
    if write_cas_lvars then write_cas_lvars() end
end

--=============================================================================
-- 2. HELPER FUNCTIONS
--=============================================================================
-- Clamp value between min and max
function var_cap(value, min_val, max_val)
    if value < min_val then return min_val end
    if value > max_val then return max_val end
    return value
end

--=============================================================================
-- 3. GAUGE LOGIC FUNCTIONS
--=============================================================================

-- TORQUE GAUGE (Orbital Movement)
-- ENG TORQUE:1 follows approximately the dial scale (0..100 on the G1000).
-- Pointer slides along the green arc using orbital mathematics.
-- TRQ Orbital Configuration (Tuned for sidePanel.png)
local trq_center_x = 71   -- Dead center of the 143px panel
local trq_center_y = 70   -- The imaginary center of the top arc
local trq_radius   = 50   -- High radius to push pointer to the outer green line
local trq_display_torque = nil  -- smoothed display value

function new_trq_value(ftlb)
    if ftlb == nil or ftlb ~= ftlb then return end
    local torque = var_cap(ftlb, 0, 35000)

    -- Smooth the displayed torque so the needle moves gradually
    if trq_display_torque == nil then
        trq_display_torque = torque
    else
        local alpha = 0.15  -- smoothing factor (0..1), smaller = slower movement
        trq_display_torque = trq_display_torque + (torque - trq_display_torque) * alpha
    end

    -- Display the smoothed torque value (rounded)
    txt_set(txt_trq, string.format("%d", math.floor(trq_display_torque + 0.5)))

    -- For needle position: divide by 100, then scale to 0-100 range for angle calculation
    local needle_value = trq_display_torque / 100  -- Divide by 100 for needle
    local scaled_torque = (needle_value / 350) * 100  -- Scale to 0-100 for angle
    local angle_deg = -128 + (scaled_torque * 2.3) 
    
    local angle_rad = math.rad(angle_deg - 90)
    
    -- Centering: Subtract 7.5 (half of 15)
    local x = trq_center_x + (trq_radius * math.cos(angle_rad)) - 7.5
    local y = trq_center_y + (trq_radius * math.sin(angle_rad)) - 7.5
    
    img_move(img_trq, x, y)
    img_rotate(img_trq, angle_deg)
end

-- ITT GAUGE (Inter Turbine Temperature)
-- Calibration: 400°C = -115°, 600°C = -55°, 900°C = 110°
-- Input is in Rankine, convert to Celsius first
-- ITT Orbital Configuration (Tuned for sidePanel.png)
local itt_center_x = 71.5  -- Horizontal center of the 143px panel
local itt_center_y = 190   -- Vertical center for the ITT gauge arc (120 + 55)
local itt_radius   = 55    -- Radius distance to the ITT arc line (half of 110)
local itt_display_celsius = nil  -- smoothed ITT for gauge

function new_itt_value(rankine)
    -- Check if value is valid
    if rankine == nil or rankine ~= rankine then  -- Check for nil or NaN
        print("ITT: Invalid value (nil or NaN)")
        return
    end
    
    -- Convert Rankine to Celsius: C = (R - 491.67) * 5/9
    local celsius = (rankine - 491.67) * 0.5555555556

    -- Smooth the displayed ITT so the needle moves gradually
    if itt_display_celsius == nil then
        itt_display_celsius = celsius
    else
        -- Slower rise when target is high (e.g. hot start 910°C) so needle doesn't jump
        local alpha = (celsius > 700) and 0.08 or 0.20
        itt_display_celsius = itt_display_celsius + (celsius - itt_display_celsius) * alpha
    end

    -- Update numeric text (nearest integer Celsius) from smoothed value
    txt_set(txt_itt, string.format("%d", math.floor(itt_display_celsius + 0.5)))
    
    -- Clamp value to valid range (allow wider range for safety)
    local temp = var_cap(itt_display_celsius, 0, 1200)
    
    -- Piecewise linear interpolation using clock positions
    -- 0°C = 8.5 o'clock = -95°, 600°C = 11 o'clock = -30°, 700°C = 12 o'clock = 0°, 900°C = 2.7 o'clock = 81°
    local angle_deg

    if temp <= 600 then
        -- 0°C (-95°) → 600°C (-30°)
        angle_deg = -95 + (temp / 600) * 65
    elseif temp <= 700 then
        -- 600°C (-30°) → 700°C (0°)
        angle_deg = -30 + ((temp - 600) / 100) * 30
    elseif temp <= 800 then
        -- 700°C (0°) → 800°C (30°)
        angle_deg = 0 + ((temp - 700) / 100) * 30
    elseif temp <= 900 then
        -- 800°C (30°) → 900°C (60°)
        angle_deg = 30 + ((temp - 800) / 100) * 30
    else
        -- Above 900°C: pointer just after 900 to show 1090°C (starter-on); gentle slope so 1090 sits just past 900
        -- 900°C = 60°; 1090°C = 65° (just after 900)
        angle_deg = 60 + (temp - 900) * (5 / 190)
    end
    
    -- Trigonometry for sliding movement
    -- Offset by -90 to align Lua's math circle with the vertical gauge
    local angle_rad = math.rad(angle_deg - 90)
    
    -- Calculate X and Y positions
    -- Subtract 7.5 to center the 15x15 pointer image on the path
    local x = itt_center_x + (itt_radius * math.cos(angle_rad)) - 7.5
    local y = itt_center_y + (itt_radius * math.sin(angle_rad)) - 7.5
    
    -- Move and Rotate
    img_move(img_itt, x, y)
    img_rotate(img_itt, angle_deg)
end

-- Ng GAUGE (N1 / % RPM)
-- Calibration: 12% = -125°, 50% = -60°, 100% = 115°
-- Ng Orbital Configuration (Tuned for sidePanel.png)
local ng_center_x = 71.5  -- Horizontal center of the 143px panel
local ng_center_y = 253   -- Vertical center for the Ng gauge arc
local ng_radius   = 53    -- Radius distance to the Ng arc line
local ng_display_n1 = nil  -- smoothed N1 for gauge

function new_ng_value(percent)
    -- Guard against nil / NaN
    if percent == nil or percent ~= percent then return end

    -- Clamp to 0-100 range (as per requirements for offset system)
    local n1_target = var_cap(percent, 0, 100)

    -- Smooth the displayed N1 so the needle moves gradually
    if ng_display_n1 == nil then
        ng_display_n1 = n1_target
    else
        local alpha = 0.18  -- smoothing factor (0..1)
        ng_display_n1 = ng_display_n1 + (n1_target - ng_display_n1) * alpha
    end

    txt_set(txt_ng, string.format("%.1f", ng_display_n1))

    -- Calibration points for N1 (%) and corresponding angles (°)
    local n1_points = {0, 12, 50, 60, 75, 80, 90, 100}
    local angle_points = {-102, -90, -60, -40, 0, 15, 45, 64}  -- 100% slightly above 2 o'clock

    -- Interpolate angle
    local angle_deg = angle_points[#angle_points]  -- default last value
    for i = 1, #n1_points-1 do
        local x0, x1 = n1_points[i], n1_points[i+1]
        local y0, y1 = angle_points[i], angle_points[i+1]
        if ng_display_n1 >= x0 and ng_display_n1 <= x1 then
            angle_deg = y0 + (ng_display_n1 - x0) / (x1 - x0) * (y1 - y0)
            break
        end
    end

    -- Needle trigonometry
    local angle_rad = math.rad(angle_deg - 90)
    local x = ng_center_x + (ng_radius * math.cos(angle_rad)) - 7.5
    local y = ng_center_y + (ng_radius * math.sin(angle_rad)) - 7.5

    img_move(img_ng, x, y)
    img_rotate(img_ng, angle_deg)
end

-- PROP RPM DISPLAY (Digital only, no needle)
function new_prop_rpm_value(rpm)
    -- Guard against nil / NaN
    if rpm == nil or rpm ~= rpm then return end
    
    -- Round to nearest 10 (so last digit is always 0)
    local rounded_rpm = math.floor((rpm / 10) + 0.5) * 10
    
    -- Update numeric text
    txt_set(txt_prop_rpm, string.format("%d", rounded_rpm))
end

-- OIL PRESSURE GAUGE (Pointer and Digital Display - Linear Movement)
-- Oil Pressure Linear Configuration
-- Operating ranges: Min unsafe 0-40 PSI, Caution 40-85 PSI, Normal 85-105 PSI, Max 105 PSI
-- Green zone starts at X=86 (85 PSI)
local oil_pres_start_x = 44     -- Starting X position (0 PSI)
local oil_pres_end_x   = 105    -- Ending X position (approx 123 PSI based on scale)
local oil_pres_y       = 342    -- Y position (constant)

function new_oil_pressure_value(psf)
    -- Guard against nil / NaN
    if psf == nil or psf ~= psf then return end
    
    -- Convert PSF to PSI (1 PSI = 144 PSF)
    local psi = psf / 144
    
    -- Clamp value to gauge range (0-105 PSI, allow up to 120 for safety)
    local oil_pres = var_cap(psi, 0, 120)
    
    -- Update numeric text (round to nearest integer PSI) - only if overlay not visible
    if not overlay_visible then
        txt_set(txt_oil_pres, string.format("%d", math.floor(oil_pres + 0.5)))
    end
    
    -- Calculate X position: linear movement from start to end
    -- 0 PSI = start_x (44), 85 PSI = 86 (green zone start), ~123 PSI = end_x (105)
    -- Scale: 61 pixels for 0-123 PSI range
    local x = oil_pres_start_x + (oil_pres / 123) * (oil_pres_end_x - oil_pres_start_x)
    
    -- Y position stays constant
    local y = oil_pres_y
    
    -- Center the 15x15 pointer on the line
    x = x - 7.5
    y = y - 7.5
    
    -- Move pointer (no rotation needed for horizontal movement, but can keep at 0 or 90 degrees)
    img_move(img_oil_pres, x, y)
    img_rotate(img_oil_pres, 0)  -- Point straight up, or change to 90 for horizontal
end

-- OIL TEMPERATURE GAUGE (Pointer and Digital Display - Linear Movement)
-- Oil Temperature Linear Configuration
-- Operating ranges: Min -40°C, Normal +10°C to +99°C, Max +104°C
-- Green zone starts at X=55 (+10°C)
local oil_temp_start_x = 16     -- Starting X position (-40°C)
local oil_temp_end_x   = 124    -- Ending X position (approx +99°C based on scale)
local oil_temp_y       = 385    -- Y position (constant)

local oil_temp_display_celsius = nil  -- smoothed oil temp for gauge

function new_oil_temperature_value(rankine)
    -- Guard against nil / NaN
    if rankine == nil or rankine ~= rankine then return end
    
    -- Convert Rankine to Celsius: C = (R - 491.67) * 5/9
    local celsius = (rankine - 491.67) * 0.5555555556
    
    -- Clamp target to gauge range (-40°C to +110°C, allow margin)
    local target_c = var_cap(celsius, -40, 110)
    -- Smooth so needle doesn't jump (e.g. when hot start forces 104°C)
    if oil_temp_display_celsius == nil then
        oil_temp_display_celsius = target_c
    else
        local alpha = (target_c > 80) and 0.08 or 0.15  -- slower when rising to hot
        oil_temp_display_celsius = oil_temp_display_celsius + (target_c - oil_temp_display_celsius) * alpha
    end
    local oil_temp = oil_temp_display_celsius
    
    -- Update numeric text (round to nearest integer Celsius) - only if overlay not visible
    if not overlay_visible then
        txt_set(txt_oil_temp, string.format("%d", math.floor(oil_temp + 0.5)))
    end
    
    -- Calculate X position: linear movement from start to end
    -- -40°C = start_x (16), +10°C = 55 (green zone start), +99°C = end_x (124)
    -- Scale: 108 pixels for -40 to +99°C range (139°C total)
    -- Shift by +40 to make range 0-139, then divide by 139
    local x = oil_temp_start_x + ((oil_temp + 40) / 139) * (oil_temp_end_x - oil_temp_start_x)
    
    -- Y position stays constant
    local y = oil_temp_y
    
    -- Center the 15x15 pointer on the line
    x = x - 7.5
    y = y - 7.5
    
    -- Move pointer horizontally (no rotation needed, set to 0 or adjust as needed)
    img_move(img_oil_temp, x, y)
    img_rotate(img_oil_temp, 0)  -- Point straight up, change to 90 for horizontal orientation
end

-- FUEL FLOW DISPLAY (Digital only, no needle)
function new_fuel_flow_value(pph)
    -- Guard against nil / NaN
    if pph == nil or pph ~= pph then return end
    
    -- Update numeric text (round to nearest integer PPH) - only if overlay not visible
    if not overlay_visible then
        txt_set(txt_fuel_flow, string.format("%d", math.floor(pph + 0.5)))
    end
end

-- BATTERY AMPS DISPLAY (Digital only, no needle)
function new_bat_amps_value(amps)
    -- Guard against nil / NaN
    if amps == nil or amps ~= amps then return end
    
    -- Store current value
    current_bat_amps = amps
    
    -- Update numeric text (round to nearest integer Amps) - only if overlay not visible
    if not overlay_visible then
        txt_set(txt_bat_amps, string.format("%d", math.floor(amps + 0.5)))
    end
end

-- BUS VOLTS DISPLAY (Digital only, no needle)
function new_bus_volts_value(volts)
    -- Guard against nil / NaN
    if volts == nil or volts ~= volts then return end
    
    -- Store current value
    current_bus_volts = volts
    
    -- Update numeric text (one decimal place for Volts) - only if overlay not visible
    if not overlay_visible then
        txt_set(txt_bus_volts, string.format("%.1f", volts))
    end
end

-- FUEL QUANTITY L/R GAUGES (Pointer only, vertical). Scale 0–1105 LBS per tank (165 gal full = 1105 lb).
local FUEL_QTY_MAX_LBS = 1105  -- full tank per aircraft (165 gal each)
local FUEL_GAUGE_Y_BOTTOM = 530
local FUEL_GAUGE_Y_TOP = 440

function new_fuel_qty_left_value(lbs)
    if lbs == nil or lbs ~= lbs then return end
    local p = var_cap(lbs, 0, FUEL_QTY_MAX_LBS)
    local y = FUEL_GAUGE_Y_BOTTOM - (p / FUEL_QTY_MAX_LBS) * (FUEL_GAUGE_Y_BOTTOM - FUEL_GAUGE_Y_TOP)
    img_move(img_fuel_qty_left, 30 - 7.5, y - 7.5)
    img_rotate(img_fuel_qty_left, 0)
end

function new_fuel_qty_right_value(lbs)
    if lbs == nil or lbs ~= lbs then return end
    local p = var_cap(lbs, 0, FUEL_QTY_MAX_LBS)
    local y = FUEL_GAUGE_Y_BOTTOM - (p / FUEL_QTY_MAX_LBS) * (FUEL_GAUGE_Y_BOTTOM - FUEL_GAUGE_Y_TOP)
    img_move(img_fuel_qty_right, 115 - 7.5, y - 7.5)
    img_rotate(img_fuel_qty_right, 0)
end

--=============================================================================
-- A→L BRIDGES
--=============================================================================

--=============================================================================
-- GAUGE L-VARIABLES (all gauges write to L: for other instruments / sim)
--=============================================================================
--  TRQ          L:TRQ_FTLB           Foot pounds
--  ITT          L:ITT_CELSIUS        Celsius
--  Ng           L:NG_PERCENT         Percent (display)  L:NG_OFFSET  L:NG_LIVE
--  Prop RPM     L:PROP_RPM           Rpm
--  Oil press    L:OIL_PRESS_PSI      PSI
--  Oil temp     L:OIL_TEMP_CELSIUS   Celsius
--  Fuel flow    L:FUEL_FLOW_PPH      Pounds per hour
--  Fuel qty L   L:FUEL_QTY_LEFT_LBS  Pounds
--  Fuel qty R   L:FUEL_QTY_RIGHT_LBS Pounds
--  Fuel total   L:FUEL_TOTAL_LBS     Pounds (totalizer)
--  Fuel used    L:FUEL_USED_LBS      Pounds (totalizer used)
--  Bus volts    L:BUS_VOLTS          Volts
--  Gen amps     L:GEN_AMPS           Amperes
--  Alt amps     L:ALT_AMPS           Amperes
--  Bat amps     L:BAT_AMPS           Amperes
--=============================================================================

-- A->L Bridge for TRQ
fsx_variable_subscribe("ENG TORQUE:1", "Foot pounds",
    function(trq)
        if trq == nil or trq ~= trq then return end

        -- Write to L-variable
        fsx_variable_write("L:TRQ_FTLB", "Foot pounds", trq)

        -- Update gauge
        new_trq_value(trq)
    end
)

-- Starter-on gauge overrides: Ng >= 12%, oil indicated. ITT/FFlow behavior now tied to fuel condition lever.
local ITT_STARTER_ON_CELSIUS = 1090   -- ITT when starter on; pointer shows a little after 900°C
local ITT_1090_RANKINE = 1090 * 9/5 + 491.67  -- Rankine for 1090°C

-- A→L Bridge for ITT with Gauge Update
fsx_variable_subscribe(
    "TURB ENG ITT:1", "Rankine",
    function(ittR)
        -- Guard against nil / NaN
        if ittR == nil or ittR ~= ittR then return end

        -- When low-idle start spike is active, show ITT 1090°C for a short period
        if low_idle_itt_spike_active then
            fsx_variable_write("L:ITT_CELSIUS", "Celsius", ITT_STARTER_ON_CELSIUS)
            new_itt_value(ITT_1090_RANKINE)
            return
        end

        -- Bleed heat ON + temp control full on: hot start – ITT above 900°C, oil temp up, NG 54%
        if bleed_heat_on and temp_ctrl_percent >= 75 then
            local hot_itt_c = 920   -- above 900°C (red line)
            local hot_itt_r = (hot_itt_c * 9/5) + 491.67
            fsx_variable_write("L:ITT_CELSIUS", "Celsius", hot_itt_c)
            new_itt_value(hot_itt_r)
            return
        end

        -- Convert Rankine to Celsius: C = (R - 491.67) * 5/9
        local celsius = (ittR - 491.67) * 0.5555555556

        -- Write the Celsius value to an L-variable
        fsx_variable_write("L:ITT_CELSIUS", "Celsius", celsius)

        -- Update the gauge needle and text
        new_itt_value(ittR) 
    end
)

--=============================================================================
-- NG OFFSET SYSTEM (Persistent Offset with Smooth Animation)
--=============================================================================
print("Initializing NG OFFSET SYSTEM...")
-- One-time auto-on at Ng 35: when true, don't force gen/alt on so user can turn them off manually
local ng_35_auto_done = false

-- Persistent offset (starts at 0, persists until changed)
local ng_offset = 0

-- Animation variables
local animation_active = false
local animation_start_value = 0
local animation_target_value = 0
local animation_timer = nil
local current_displayed_value = 0  -- Track the actual displayed value

-- Function to calculate target display value (without animation)
-- When over 100, reduce offset so we sit at 100 and needle moves back as N1 drops (like Prepar3D)
local function calculate_target_display()
    local raw = live_ng_value + ng_offset
    if raw > 100 then
        ng_offset = 100 - live_ng_value
        if ng_offset < 0 then ng_offset = 0 end
        raw = 100
    end
    return var_cap(raw, 0, 100)
end

-- Smooth ramp to 54% when in hot start (bleed heat + temp full)
local ng_hot_start_smooth = nil

-- Function to update gauge display (with current value, animated or not)
local function update_ng_display(display_value)
    -- Bleed heat ON + temp control full on: hot start – NG shows 54%
    if bleed_heat_on and temp_ctrl_percent >= 75 then
        if ng_hot_start_smooth == nil then
            ng_hot_start_smooth = current_displayed_value
        end
        local alpha = 0.08  -- smooth ramp to 54%
        ng_hot_start_smooth = ng_hot_start_smooth + (54 - ng_hot_start_smooth) * alpha
        display_value = ng_hot_start_smooth
    elseif starter_switch_on and display_value < 12 then
        ng_hot_start_smooth = nil
        display_value = 12
    else
        ng_hot_start_smooth = nil  -- reset when leaving hot start
        local cond_low_idle = is_condition_lever_low_idle and is_condition_lever_low_idle()
        if cond_low_idle and display_value < 55 then
            display_value = 55
        end
    end
    -- Clamp value between 0 and 100
    display_value = var_cap(display_value, 0, 100)
    
    -- Store current displayed value for animation
    current_displayed_value = display_value
    
    -- Write to L-variable (for other instruments, NOT back to sim)
    if fsx_variable_write then
        pcall(fsx_variable_write, "L:NG_PERCENT", "Percent", display_value or 0)
        pcall(fsx_variable_write, "L:NG_OFFSET", "Percent", ng_offset or 0)
        pcall(fsx_variable_write, "L:NG_LIVE", "Percent", live_ng_value or 0)
        -- Also write to a direct L:NG variable as requested
        pcall(fsx_variable_write, "L:NG", "Percent", display_value or 0)
    end
    
    -- Update gauge with display value (uses custom nonlinear scale)
    new_ng_value(display_value)
end

-- Animation function: smoothly transitions from start to target over 3 seconds
local animation_frame = 0
local animation_total_frames = 60  -- 60 frames for 3 seconds at 50ms per frame

local function animate_ng_value()
    if not animation_active then 
        if animation_timer then
            timer_stop(animation_timer)
            animation_timer = nil
        end
        return 
    end
    
    animation_frame = animation_frame + 1
    
    if animation_frame >= animation_total_frames then
        -- Animation complete
        animation_active = false
        animation_frame = 0
        update_ng_display(animation_target_value)
        if animation_timer then
            timer_stop(animation_timer)
            animation_timer = nil
        end
        print("NG OFFSET: Animation complete")
    else
        -- Interpolate between start and target
        local progress = animation_frame / animation_total_frames
        -- Use ease-in-out for smooth animation
        local eased_progress
        if progress < 0.5 then
            eased_progress = 2 * progress * progress
        else
            eased_progress = 1 - ((-2 * progress + 2) ^ 2) / 2
        end
        
        local current_value = animation_start_value + 
            (animation_target_value - animation_start_value) * eased_progress
        
        update_ng_display(current_value)
    end
end

-- Key/Button press handler: adds +30 to offset with smooth animation
local function ng_offset_key_handler()
    -- Set persistent offset to 30
    ng_offset = 30
    
    -- Calculate target value
    local target = calculate_target_display()
    
    -- Get current display value (use the actual displayed value, not target)
    local current_display = current_displayed_value
    
    -- Stop any existing animation
    if animation_timer then
        timer_stop(animation_timer)
        animation_timer = nil
    end
    animation_active = false
    animation_frame = 0
    
    -- Start new animation
    animation_active = true
    animation_start_value = current_display
    animation_target_value = target
    animation_frame = 0
    
    -- Start animation timer (update every 50ms for smooth 3-second animation)
    -- 3000ms / 50ms = 60 frames total
    -- timer_start(delay_ms, interval_ms, callback)
    animation_timer = timer_start(0, 50, function()
        animate_ng_value()
        -- Stop timer if animation is complete
        if not animation_active and animation_timer then
            timer_stop(animation_timer)
            animation_timer = nil
        end
    end)
    
    print(string.format("NG OFFSET: Animation started from %.1f to %.1f (60 frames over 3 seconds)", 
        animation_start_value, animation_target_value))
    
    print(string.format("NG OFFSET: Set to 30, New offset = %.1f, Animating to %.1f over 3 seconds", 
        ng_offset, target))
end

--=============================================================================
-- NG OFFSET BUTTON (Click to add +30)
--=============================================================================
-- Clickable button over the Ng digital readout
-- Just click the Ng value number to add +30 offset
--=============================================================================

--=============================================================================
-- BUTTON + SPACEBAR INPUT
--=============================================================================
-- 1. BUTTON: Click the Ng digital readout to add +30
-- 2. SPACEBAR: Via key_add() (Air Manager 4.0+, panel must have focus)
--=============================================================================

-- Add clickable button over Ng readout (always works - click to add +30)
button_add(nil, nil, 86, 246, 55, 24,
    function() 
        -- Button pressed: add +30 to offset
        ng_offset_key_handler()
    end,
    function() 
        -- Button released: do nothing (trigger on press only)
    end
)
print("NG OFFSET: Button ready - Click the Ng number to add +30")

print("NG OFFSET: Click the Ng number to add +30")

-- Variable subscription: read live NG from sim
fsx_variable_subscribe(
    "TURB ENG N1:1", "Percent",
    function(ng)

        -- Guard against nil / NaN when using sim value
        if ng == nil or ng ~= ng then return end

        local was_below_46 = (live_ng_value < 46)
        live_ng_value = ng
        local is_below_46 = (live_ng_value < 46)

        -- When Ng crosses 46% (and battery is on), turn generator on or off automatically
        -- It also respects the physical hardware switch (`generator_switch_on`)
        local should_gen_be_on = (not is_below_46) and (generator_switch_on == true)
        
        -- If power state changes OR Ng crosses threshold (which affects the "GENERATOR OFF" warning and "FUEL BOOST" logic), update CAS/Fuel
        if (gen_switch_on ~= should_gen_be_on) or (was_below_46 ~= is_below_46) then
            gen_switch_on = should_gen_be_on
            if txt_cas_gen then
                txt_set(txt_cas_gen, gen_switch_on and "ON" or "OFF")
                txt_style(txt_cas_gen, gen_switch_on and "size:12; color:rgb(180,255,180); halign:center; valign:center;" or "size:12; color:rgb(255,180,180); halign:center; valign:center;")
            end
            if apply_light_load_to_electrical then apply_light_load_to_electrical() end
            write_cas_lvars()
            
            -- Re-evaluate fuel boost logic dynamically when crossing 46% threshold
            if fuel_logic then fuel_logic() end
        end

        -- If animation is active, update target; otherwise update display immediately
        if not animation_active then
            local target = calculate_target_display()
            update_ng_display(target)
        else
            animation_target_value = calculate_target_display()
        end
    end
)

-- When starter is turned ON: drive Ng from panel state only (12%), don't read aircraft
function apply_starter_ng_min_if_needed()
    if not starter_switch_on then return end
    -- Force Ng to 12% when starter is ON (panel-driven, not sim)
    live_ng_value = 12
    local target = calculate_target_display()
    local current_display = current_displayed_value

    if animation_timer then
        timer_stop(animation_timer)
        animation_timer = nil
    end
    animation_active = true
    animation_start_value = current_display
    animation_target_value = target
    animation_frame = 0
    animation_timer = timer_start(0, 50, function()
        animate_ng_value()
        if not animation_active and animation_timer then
            timer_stop(animation_timer)
            animation_timer = nil
        end
    end)
end

-- OIL PRESSURE BRIDGE
fsx_variable_subscribe("GENERAL ENG OIL PRESSURE:1", "Psf", function(psf)
    if psf == nil or psf ~= psf then return end
    local psi = psf / 144
    if starter_switch_on and (psi < 20 or psi == 0) then
        psi = OIL_PRESS_STARTER_ON_PSI
        psf = psi * 144
    end
    live_oil_pressure_psi = psi
    write_cas_lvars()
    fsx_variable_write("L:OIL_PRESS_PSI", "PSI", psi)
    new_oil_pressure_value(psf)
end)

-- OIL TEMPERATURE BRIDGE
fsx_variable_subscribe("GENERAL ENG OIL TEMPERATURE:1", "Rankine", function(ittR)
    if ittR == nil or ittR ~= ittR then return end
    -- Bleed heat ON + temp control full: hot start – oil temp high (104°C)
    if bleed_heat_on and temp_ctrl_percent >= 75 then
        local hot_oil_c = 104
        local hot_oil_r = (hot_oil_c * 9/5) + 491.67
        fsx_variable_write("L:OIL_TEMP_CELSIUS", "Celsius", hot_oil_c)
        new_oil_temperature_value(hot_oil_r)
        return
    end
    local celsius = (ittR - 491.67) * 0.5555555556
    fsx_variable_write("L:OIL_TEMP_CELSIUS", "Celsius", celsius)
    new_oil_temperature_value(ittR)
end)

-- FUEL FLOW BRIDGE
-- Reads directly from the A-parameter as requested by user.
fsx_variable_subscribe("TURB ENG FUEL FLOW PPH:1", "Pounds per hour", function(pph)
    if pph == nil or pph ~= pph then return end
    fsx_variable_write("L:FUEL_FLOW_PPH", "Pounds per hour", pph)
    new_fuel_flow_value(pph)
    -- Update overlay
    if overlay_visible and txt_overlay_fflow_val then
        txt_set(txt_overlay_fflow_val, string.format("%d", math.floor(pph + 0.5)))
    end
end)

-- Forward declaration for update_fuel_cas so subscriptions can use it
local update_fuel_cas

-- FUEL PRESSURE BRIDGE (Sim and L-Var Override)
-- (Legacy fuel pressure block removed to prevent conflict with new hysteresis logic)

-- ELECTRICAL BRIDGE (Amps & Volts)
fsx_variable_subscribe("ELECTRICAL MAIN BUS VOLTAGE", "Volts", 
    function(volts)
        if volts ~= nil and volts == volts then 
            last_sim_bus_voltage = volts  -- kept for optional logic only; display uses panel values only
        end
    end
)

-- PROP RPM BRIDGE
fsx_variable_subscribe("PROP RPM:1", "Rpm", function(rpm)
    if rpm == nil or rpm ~= rpm then return end
    fsx_variable_write("L:PROP_RPM", "Rpm", rpm)
    new_prop_rpm_value(rpm)
end)

-- FUEL QUANTITY BRIDGE — read only from Cessna 208 aircraft
fsx_variable_subscribe("FUEL LEFT QUANTITY", "Gallons", "FUEL RIGHT QUANTITY", "Gallons", "FUEL WEIGHT PER GALLON", "Pounds",
    function(l_gal, r_gal, wt)
        -- Use Cessna 208 display weight so panel total matches aircraft
        local w = (wt ~= nil and wt == wt and wt > 0) and wt or 6.7
        local l_gal_val = (l_gal ~= nil and l_gal == l_gal) and l_gal or 0
        local r_gal_val = (r_gal ~= nil and r_gal == r_gal) and r_gal or 0
        local l_lbs = l_gal_val * w
        local r_lbs = r_gal_val * w
        fuel_qty_left_lbs = l_lbs
        fuel_qty_left_gal = l_gal_val   -- store gallons for RSVR FUEL LOW threshold
        fuel_qty_right_lbs = r_lbs
        fuel_qty_right_gal = r_gal_val  -- store gallons for RSVR FUEL LOW threshold
        fsx_variable_write("L:FUEL_QTY_LEFT_LBS", "Pounds", l_lbs)
        new_fuel_qty_left_value(l_lbs)
        if overlay_visible and txt_overlay_qty_l_val then
            txt_set(txt_overlay_qty_l_val, string.format("%d", math.floor(l_lbs + 0.5)))
        end
        fsx_variable_write("L:FUEL_QTY_RIGHT_LBS", "Pounds", r_lbs)
        new_fuel_qty_right_value(r_lbs)
        if overlay_visible and txt_overlay_qty_r_val then
            txt_set(txt_overlay_qty_r_val, string.format("%d", math.floor(r_lbs + 0.5)))
        end
        write_cas_lvars()
    end
)


-- FUEL TOTALIZER (LB REM and LB USED)
local initial_fuel_lbs = nil
fsx_variable_subscribe("FUEL TOTAL QUANTITY", "Gallons", "FUEL WEIGHT PER GALLON", "Pounds",
    function(total_gal, wt)
        if total_gal == nil or total_gal ~= total_gal then return end
        local w = (wt ~= nil and wt == wt and wt > 0) and wt or 6.7
        local total_lbs = total_gal * w
        
        -- LB REM
        if fsx_variable_write then fsx_variable_write("L:FUEL_TOTAL_LBS", "Pounds", total_lbs) end
        if overlay_visible and txt_overlay_lb_rem_val then
            txt_set(txt_overlay_lb_rem_val, string.format("%.1f", total_lbs))
        end
        
        -- LB USED (requires tracking initial fuel)
        if initial_fuel_lbs == nil then
            initial_fuel_lbs = total_lbs
        end
        local fuel_used = math.max(0, initial_fuel_lbs - total_lbs)
        if fsx_variable_write then fsx_variable_write("L:FUEL_USED_LBS", "Pounds", fuel_used) end
        if overlay_visible and txt_overlay_lb_used_val then
            txt_set(txt_overlay_lb_used_val, string.format("%.1f", fuel_used))
        end
    end
)

-- FUEL CONDITION LEVER BRIDGE (Mixture maps to Condition Lever in PT6)
fsx_variable_subscribe("GENERAL ENG MIXTURE LEVER POSITION:1", "Percent", function(pos)
    if pos == nil or pos ~= pos then return end
    -- The condition lever position is broadly tracked 0-100%
    -- Cutoff = 0%, Low Idle ~= 10-30%, High Idle ~= 100% depending on mapping
    fuel_condition_lever_pos = pos
end)

--=============================================================================
-- REALISTIC AIRCRAFT ELECTRICAL SYSTEM (Cessna 208-style)
--=============================================================================
-- Priority-based power source selection:
--   1) Generator (highest priority)
--   2) Alternator (backup if generator fails)
--   3) Battery (only when both GEN and ALT are unavailable)
--=============================================================================

-- Electrical system state
-- NOTE: We drive GEN/ALT/BAT amps primarily from:
--   - Generator/alternator switches
--   - Main bus amps (total load)
-- This avoids relying on ambiguous per-source load simvars.
-- When 1, treat alternator as "off" for priority (no ALT switch in aircraft) – test battery-only
local alt_force_off = false

-- Removed custom electrical limits table

-- Custom logic removed per user request

local function update_light_labels()
    if txt_light_1 then txt_set(txt_light_1, light_on[1] and "BEACON ON" or "BEACON OFF") end
    if txt_light_2 then txt_set(txt_light_2, (light_on[2] or light_on[3]) and "LANDING ON" or "LANDING OFF") end
    if txt_light_3 then txt_set(txt_light_3, light_on[5] and "STROBE ON" or "STROBE OFF") end
end

-- Toggle light: L only — update local state and write L (no A/sim). No effect when Battery OFF.
local function toggle_light(i)
    if i < 1 or i > 3 then return end
    if not battery_switch_on then return end
    light_on[i] = not light_on[i]
    local new_val = light_on[i] and 1 or 0
    if fsx_variable_write then
        pcall(fsx_variable_write, LIGHTS[i].lvar, "Number", new_val)
    end
    update_light_labels()
end

local function apply_bleed_heat_visual()
    if not txt_bleed_heat then return end
    if bleed_heat_on then
        txt_set(txt_bleed_heat, "ON")
        txt_style(txt_bleed_heat, "size:12; color:rgb(180,255,180); halign:center; valign:center;")
    else
        txt_set(txt_bleed_heat, "OFF")
        txt_style(txt_bleed_heat, "size:12; color:rgb(255,180,180); halign:center; valign:center;")
    end
    if fsx_variable_write then
        pcall(fsx_variable_write, "L:BLEED_AIR_HEAT", "Number", bleed_heat_on and 1 or 0)
    end
end

-- Cabin heat mix: FLT (push) / GND (pull); update label and L-var
local function apply_cabin_heat_mix_visual()
    if not txt_cabin_heat_mix then return end
    if cabin_heat_mix_gnd then
        txt_set(txt_cabin_heat_mix, "GND")
        txt_style(txt_cabin_heat_mix, "size:12; color:rgb(255,220,180); halign:center; valign:center;")
    else
        txt_set(txt_cabin_heat_mix, "FLT")
        txt_style(txt_cabin_heat_mix, "size:12; color:rgb(180,255,180); halign:center; valign:center;")
    end
    if fsx_variable_write then
        pcall(fsx_variable_write, "L:CABIN_HEAT_MIX", "Number", cabin_heat_mix_gnd and 1 or 0)
    end
end

-- Fuel/oil shutoff: update label and L-var (ON/OFF)
local function apply_fuel_oil_shutoff_visual()
    if not txt_fuel_oil_shutoff then return end
    if fuel_oil_shutoff_on then
        txt_set(txt_fuel_oil_shutoff, "ON")
        txt_style(txt_fuel_oil_shutoff, "size:12; color:rgb(180,255,180); halign:center; valign:center;")
    else
        txt_set(txt_fuel_oil_shutoff, "OFF")
        txt_style(txt_fuel_oil_shutoff, "size:12; color:rgb(255,180,180); halign:center; valign:center;")
    end
    if fsx_variable_write then
        pcall(fsx_variable_write, "L:FUEL_OIL_SHUTOFF", "Number", fuel_oil_shutoff_on and 1 or 0)
    end
end

if fsx_variable_write then
    pcall(fsx_variable_write, "L:COND_LEVER_POS", "Number", condition_lever_pos)
end

local function push_cas_gen_alt()
end

local function push_cas_fuel_boost()
end

-- Helper to sync ignition UI and CAS whenever the switch state changes
function apply_ignition_ui_and_cas()
    local is_on = ignition_switch_on or starter_switch_on
    if txt_ignition then
        txt_set(txt_ignition, is_on and "ON" or "NORM")
        txt_style(
            txt_ignition,
            is_on
                and "size:12; color:rgb(180,255,180); halign:center; valign:center;"
                or  "size:12; color:rgb(255,180,180); halign:center; valign:center;"
        )
    end

    cas_fictitious[7] = is_on and 1 or 0
    if write_cas_lvars then write_cas_lvars() end
end

--=============================================================================
-- CAS: one-shot and recurring logic
--=============================================================================
local function push_cas_starter()
end

-- One-shot CAS update when battery turns ON (avoids 13× write_cas_lvars = flicker)
local function push_cas_battery_on_once()
    if not battery_switch_on then return end
    
    -- Ensure fuel logic has run once to establish correct pressure/state
    if fuel_logic then fuel_logic() end
    
    cas_fictitious[1] = 1   -- VOLTAGE LOW (show at power-up)
    cas_fictitious[2] = 1   -- OIL PRESS LOW (show at power-up)
    cas_fictitious[3] = (fuel_press < 4.75) and 1 or 0  -- FUEL PRESS LOW (Critical Red)
    cas_fictitious[4] = test_fire_detect_on and 1 or 0 -- ENGINE FIRE
    cas_fictitious[5] = test_fuel_select_off_on and 1 or 0 -- FUEL SELECT OFF
    cas_fictitious[6] = fuel_boost_on and 1 or 0  -- FUEL BOOST ON (Advisory White)
    cas_fictitious[7] = (ignition_switch_on or starter_switch_on) and 1 or 0 -- IGNITION ON
    cas_fictitious[8] = starter_switch_on and 1 or 0 -- STARTER ON
    -- GENERATOR OFF (warning shows when physical switch tripped OR gen_switch_on is false due to low Ng)
    cas_fictitious[9] = (not generator_switch_on or not gen_switch_on) and 1 or 0 
    cas_fictitious[10] = standby_power_switch_on and 1 or 0 -- STBY PWR ON
    -- GENERATOR OVERHEAT (> 200A)
    cas_fictitious[11] = (electrical_state.gen_amps > 200) and 1 or 0
    -- ALTERNATOR OVERHEAT (> 75A)
    cas_fictitious[12] = (electrical_state.alt_amps > 75) and 1 or 0
    -- STBY PWR INOP (warning shows when switch is off)
    cas_fictitious[13] = not standby_power_switch_on and 1 or 0
    -- FUEL LEVEL LOW L (< 170 lbs)
    cas_fictitious[14] = (fuel_qty_left_lbs < 170) and 1 or 0
    -- FUEL LEVEL LOW R (< 170 lbs)
    cas_fictitious[15] = (fuel_qty_right_lbs < 170) and 1 or 0
    -- FUEL LEVEL LOW L-R (< 170 lbs for either)
    cas_fictitious[16] = (fuel_qty_left_lbs < 170 or fuel_qty_right_lbs < 170) and 1 or 0
    -- EMER PWR LVR
    cas_fictitious[17] = 0 -- driven by L-Var or axis
    -- Clear all lights in fictitious CAS (if needed, though CAS usually handles by index)
    write_cas_lvars()
end

local push_cas_all_off

-- Force all panel buttons to OFF (state + UI + L:). Used when battery turns ON so no button is on automatically.
local function set_all_buttons_off()
    gen_switch_on = false
    alt_switch_on = false
    ng_35_auto_done = false
    fuel_boost_on = false
    starter_switch_on = false
    for i = 1, 3 do light_on[i] = false end
    txt_set(txt_cas_gen, "OFF")
    txt_style(txt_cas_gen, "size:12; color:rgb(255,180,180); halign:center; valign:center;")
    txt_set(txt_cas_alt, "OFF")
    txt_style(txt_cas_alt, "size:12; color:rgb(255,180,180); halign:center; valign:center;")
    txt_set(txt_cas_fuel, "OFF")
    txt_style(txt_cas_fuel, "size:12; color:rgb(255,180,180); halign:center; valign:center;")
    txt_set(txt_cas_starter, "OFF")
    txt_style(txt_cas_starter, "size:12; color:rgb(255,180,180); halign:center; valign:center;")
    ignition_switch_norm = true
    if txt_ignition then txt_set(txt_ignition, "NORM") txt_style(txt_ignition, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    -- emergency_power_lever_front = false
    -- if txt_emerge_pwr_lever then txt_set(txt_emerge_pwr_lever, "IDLE") txt_style(txt_emerge_pwr_lever, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    test_fire_detect_on = false
    test_fuel_select_off_on = false
    if txt_cas_test_fire then txt_set(txt_cas_test_fire, "OFF") txt_style(txt_cas_test_fire, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    if txt_cas_test_fuel_sel then txt_set(txt_cas_test_fuel_sel, "OFF") txt_style(txt_cas_test_fuel_sel, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    fuel_tank_left_on = false
    fuel_tank_right_on = false
    bleed_heat_on = false
    if txt_fuel_tank_left then txt_set(txt_fuel_tank_left, "OFF") txt_style(txt_fuel_tank_left, "size:11; color:rgb(255,180,180); halign:center; valign:center;") end
    if txt_fuel_tank_right then txt_set(txt_fuel_tank_right, "OFF") txt_style(txt_fuel_tank_right, "size:11; color:rgb(255,180,180); halign:center; valign:center;") end
    if txt_bleed_heat then txt_set(txt_bleed_heat, "OFF") txt_style(txt_bleed_heat, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    update_light_labels()
    if fsx_variable_write then
        for i = 1, #LIGHTS do pcall(fsx_variable_write, LIGHTS[i].lvar, "Number", 0) end
        pcall(fsx_variable_write, "L:C208_GEN_SWITCH", "Number", 0)
        pcall(fsx_variable_write, "L:C208_ALT_SWITCH", "Number", 0)
        pcall(fsx_variable_write, "L:ASD_SWITCH_FUEL_AUXBP", "Number", 0)
        pcall(fsx_variable_write, "L:C208_STARTER_ON", "Number", 0)
        pcall(fsx_variable_write, "TURBINE_IGNITION_SWITCH_TOGGLE", "Number", 0)
        pcall(fsx_variable_write, "L:LeftTank1", "Number", 0)
        pcall(fsx_variable_write, "L:RightTank1", "Number", 0)
        -- pcall(fsx_variable_write, "L:C208_EMERGENCY_PWR_LEVER", "Number", 0)
        pcall(fsx_variable_write, "L:C208_TEST_FIRE", "Number", 0)
        pcall(fsx_variable_write, "L:C208_TEST_FUEL_SEL", "Number", 0)
    end
end

-- Subscribe to L:C208_* so both instances stay in sync
local function apply_battery_off_state()
    gen_switch_on = false
    alt_switch_on = false
    ng_35_auto_done = false
    fuel_boost_on = false
    starter_switch_on = false
    for i = 1, 3 do light_on[i] = false end
    if txt_cas_gen then txt_set(txt_cas_gen, "OFF") txt_style(txt_cas_gen, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    if txt_cas_alt then txt_set(txt_cas_alt, "OFF") txt_style(txt_cas_alt, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    if txt_cas_fuel then txt_set(txt_cas_fuel, "OFF") txt_style(txt_cas_fuel, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    if txt_cas_starter then txt_set(txt_cas_starter, "OFF") txt_style(txt_cas_starter, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    ignition_switch_norm = true
    if txt_ignition then txt_set(txt_ignition, "NORM") txt_style(txt_ignition, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    emergency_power_lever_front = false
    if txt_emerge_pwr_lever then txt_set(txt_emerge_pwr_lever, "IDLE") txt_style(txt_emerge_pwr_lever, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    test_fire_detect_on = false
    test_fuel_select_off_on = false
    if txt_cas_test_fire then txt_set(txt_cas_test_fire, "OFF") txt_style(txt_cas_test_fire, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    if txt_cas_test_fuel_sel then txt_set(txt_cas_test_fuel_sel, "OFF") txt_style(txt_cas_test_fuel_sel, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    fuel_tank_left_on = false
    fuel_tank_right_on = false
    bleed_heat_on = false
    if txt_fuel_tank_left then txt_set(txt_fuel_tank_left, "OFF") txt_style(txt_fuel_tank_left, "size:11; color:rgb(255,180,180); halign:center; valign:center;") end
    if txt_fuel_tank_right then txt_set(txt_fuel_tank_right, "OFF") txt_style(txt_fuel_tank_right, "size:11; color:rgb(255,180,180); halign:center; valign:center;") end
    if txt_bleed_heat then txt_set(txt_bleed_heat, "OFF") txt_style(txt_bleed_heat, "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    update_light_labels()
    if fsx_variable_write and LIGHTS then
        for i = 1, 3 do
            if LIGHTS[i] then pcall(fsx_variable_write, LIGHTS[i].lvar, "Number", 0) end
        end
        pcall(fsx_variable_write, "L:C208_GEN_SWITCH", "Number", 0)
        pcall(fsx_variable_write, "L:C208_ALT_SWITCH", "Number", 0)
        pcall(fsx_variable_write, "L:ASD_SWITCH_FUEL_AUXBP", "Number", 0)
        pcall(fsx_variable_write, "L:C208_STARTER_ON", "Number", 0)
        pcall(fsx_variable_write, "TURBINE_IGNITION_SWITCH_TOGGLE", "Number", 0)
        pcall(fsx_variable_write, "L:LeftTank1", "Number", 0)
        pcall(fsx_variable_write, "L:RightTank1", "Number", 0)
        pcall(fsx_variable_write, "L:C208_EMERGENCY_PWR_LEVER", "Number", 0)
        pcall(fsx_variable_write, "L:C208_TEST_FIRE", "Number", 0)
        pcall(fsx_variable_write, "L:C208_TEST_FUEL_SEL", "Number", 0)
    end
    if push_cas_all_off then push_cas_all_off() end
end
local function apply_battery_logic(v)
    if v == nil then return end
    battery_switch_on = (v == 1)
    
    -- UI Update
    if txt_cas_battery then txt_set(txt_cas_battery, battery_switch_on and "ON" or "OFF") end
    if txt_cas_battery then txt_style(txt_cas_battery, battery_switch_on and "size:13; color:rgb(180,255,180); halign:center; valign:center; weight:bold;" or "size:13; color:rgb(255,180,180); halign:center; valign:center; weight:bold;") end
    
    -- Tell CAS panel about battery state via SI variable
    if si_variable_write and cas_battery_si_id then
        pcall(si_variable_write, cas_battery_si_id, battery_switch_on and 1 or 0)
    end
    
    -- State and CAS Updates
    if not battery_switch_on then 
        apply_battery_off_state() 
    else 
        -- One-shot CAS push to minimize flicker when powering up
        push_cas_battery_on_once()
    end
    
    apply_light_load_to_electrical()
end

-- Subscribe to standard side panel L-variable
fsx_variable_subscribe("L:C208_BATTERY_SWITCH", "Number", apply_battery_logic)

-- Also subscribe to the hardware battery switch variable
fsx_variable_subscribe("L:ASD_SWITCH_MASTER_BAT_C182T", "Number", function(v)
    if v == nil then return end
    -- Write to the side panel's primary internal L-variable to keep everything in sync
    fsx_variable_write("L:C208_BATTERY_SWITCH", "Number", v)
    -- Also apply the logic directly for immediate response
    apply_battery_logic(v)
end)
fsx_variable_subscribe("L:C208_GEN_SWITCH", "Number", function(v) 
    if v == nil then return end 
    gen_switch_on = (v == 1) 
    if txt_cas_gen then txt_set(txt_cas_gen, gen_switch_on and "ON" or "OFF") end
    if txt_cas_gen then txt_style(txt_cas_gen, gen_switch_on and "size:12; color:rgb(180,255,180); halign:center; valign:center;" or "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    apply_light_load_to_electrical() 
end)
fsx_variable_subscribe("L:C208_ALT_SWITCH", "Number", function(v) 
    if v == nil then return end 
    alt_switch_on = (v == 1) 
    if txt_cas_alt then txt_set(txt_cas_alt, alt_switch_on and "ON" or "OFF") end
    if txt_cas_alt then txt_style(txt_cas_alt, alt_switch_on and "size:12; color:rgb(180,255,180); halign:center; valign:center;" or "size:12; color:rgb(255,180,180); halign:center; valign:center;") end
    apply_light_load_to_electrical() 
end)
-- =========================
-- FUEL SYSTEM VARIABLES & STATE
-- =========================
-- (Fuel variable declarations moved to top)

-- =========================
-- MAIN FUEL LOGIC
-- =========================
local function fuel_logic()
    -- Isolated Check: ONLY rely on the hardware switch position. 
    if boost_switch == nil then return end

    local is_engine_running = (live_ng_value ~= nil and live_ng_value >= 46.0)
    local pump_active = false
    local calculated_psi = 0.0

    -- =========================
    -- 1. DETERMINE PUMP STATE & PRESSURE
    -- =========================
    if boost_switch == 2 then
        -- Position 2: Manual ON
        pump_active = true
        if is_engine_running then
            calculated_psi = 10.0
        else
            calculated_psi = 4.75 -- Per your rules, manual ON with engine off gives 4.75 PSI
        end

    elseif boost_switch == 1 then
        -- Position 1: NORM (Auto Mode)
        if is_engine_running then
            -- Engine pump provides 10 PSI, boost pump stays OFF
            pump_active = false
            calculated_psi = 10.0
        else
            -- Engine below 46%, auto-boost kicks in at 4.75 PSI
            pump_active = true
            calculated_psi = 4.75 
        end

    else
        -- Position 0: OFF
        pump_active = false
        if is_engine_running then
            -- Engine pump provides 10 PSI even if boost is OFF
            calculated_psi = 10.0
        else
            -- Nothing is pumping, pressure is dead
            calculated_psi = 0.0
        end
    end

    -- =========================
    -- 2. APPLY PRESSURE TO SIM & LOCAL STATE
    -- =========================
    if fsx_variable_write and calculated_psi ~= fuel_press then
        pcall(fsx_variable_write, "L:C208_CUSTOM_FUEL_PRESS", "Number", calculated_psi)
    end
    fuel_press = calculated_psi

    -- =========================
    -- 3. UI TEXT & COLORS
    -- =========================
    local txt_boost = ""
    local boost_color = "size:12; color:rgb(255,180,180); halign:center; valign:center;" -- NORM default
    
    if boost_switch == 1 and pump_active then
        txt_boost = "AUTO ON"
        boost_color = "size:12; color:rgb(255,255,180); halign:center; valign:center;"
    elseif pump_active then
        txt_boost = "ON"
        boost_color = "size:12; color:rgb(180,255,180); halign:center; valign:center;"
    else
        if boost_switch == 0 then
            txt_boost = "OFF"
        else
            txt_boost = "NORM"
        end
    end

    if txt_cas_fuel then 
        txt_set(txt_cas_fuel, txt_boost) 
        txt_style(txt_cas_fuel, boost_color) 
    end

    -- =========================
    -- 4. CAS WARNINGS
    -- =========================
    fuel_boost_on = pump_active
    light_on[13] = fuel_boost_on

    if battery_switch_on then
        -- FUEL PRESS LOW: Only show if strictly less than 4.75 (so 4.75 will NOT trigger it)
        cas_fictitious[3] = (fuel_press < 4.75) and 1 or 0  
        
        -- FUEL BOOST ON: Show whenever the pump is actively running
        cas_fictitious[6] = pump_active and 1 or 0        
    else
        cas_fictitious[3] = 0
        cas_fictitious[6] = 0
    end

    if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    if write_cas_lvars then write_cas_lvars() end

    print(string.format("CUSTOM FUEL LOGIC -> PRESS: %.2f PSI | BOOST: %s | SWITCH: %d | NG: %.1f", 
        fuel_press or 0, pump_active and "ON" or "OFF", boost_switch or 0, live_ng_value or 0))
    
    -- Sync simulator event (optional fallback)
    if pump_active then
        pcall(fsx_event, "FUEL_PUMP1_ON")
    else
        pcall(fsx_event, "FUEL_PUMP1_OFF")
    end
end

-- =========================
-- SUBSCRIPTIONS
-- =========================
fsx_variable_subscribe(
    "L:ASD_SWITCH_FUEL_AUXBP", "Number",
    "L:C208_CUSTOM_FUEL_PRESS", "Number",  -- Custom L-Var for Fuel Pressure
    function(sw, press)
        boost_switch = sw
        fuel_press   = press
        fuel_logic()
    end
)
-- Track whether ignition was auto-enabled by the starter (so we don't disable a manually-set ignition)
local ignition_auto_enabled_by_starter = false

-- User's Hardware Starter Switch (Triggers Starter Warning Only)
fsx_variable_subscribe("L:ASD_SWITCH_STARTER_CE208EX", "Number", function(v) 
    if v == nil then return end 
    starter_switch_on = (v == 2)    -- ON only in START
    
    -- Auto-enable physical aircraft ignition when starter turns ON
    if starter_switch_on then
        -- The user confirmed TURBINE_IGNITION_SWITCH_TOGGLE previously worked perfectly.
        -- We removed the `if not ignition_switch_on` safeguard because the joystick 
        -- switch is no longer wired to the sim, meaning the sim's ignition is always OFF.
        pcall(fsx_event, "TURBINE_IGNITION_SWITCH_TOGGLE")
        ignition_auto_enabled_by_starter = true
    else
        -- Starter released — restore the sim's ignition by toggling it back OFF
        if ignition_auto_enabled_by_starter then
            pcall(fsx_event, "TURBINE_IGNITION_SWITCH_TOGGLE")
            ignition_auto_enabled_by_starter = false
        end
    end

    -- Update unified ignition UI and CAS warning
    apply_ignition_ui_and_cas()

    -- Sync CAS starter label
    if txt_cas_starter then 
        txt_set(txt_cas_starter, starter_switch_on and "ON" or "OFF") 
        txt_style(txt_cas_starter, starter_switch_on and "size:12; color:rgb(180,255,180); halign:center; valign:center;" or "size:12; color:rgb(255,180,180); halign:center; valign:center;") 
    end 
    
    -- Simulator spikes and start conditions
    if starter_switch_on and apply_starter_ng_min_if_needed then apply_starter_ng_min_if_needed() end 
    if starter_switch_on and start_low_idle_itt_spike then start_low_idle_itt_spike() end 
    
    -- Push CAS state
    write_cas_lvars()
end)

-- Ignition Switch: Purely L-Var driven for CAS warning and panel logic
-- The user will toggle L:ASD_SWITCH_IGNITION_CE208 via FSUIPC/Hardware
fsx_variable_subscribe("L:ASD_SWITCH_IGNITION_CE208", "Number", function(v) 
    if v == nil or v ~= v then return end 
    print("IGNITION L-VAR INPUT: " .. tostring(v))
    ignition_switch_on = (v >= 1) -- 0=NORM, 1=ON (Corrected from >=0)
    
    -- Update panel label and CAS
    apply_ignition_ui_and_cas()
end)


-- Emergency Power Lever: read from FSUIPC L-Var
-- Show EMER PWR LVR warning when lever >= 0 AND fuel condition is between cutoff and low idle (< 40%)
fsx_variable_subscribe("L:C208_EMERGENCY_PWR_LEVER", "Number", function(v)
    if v == nil then return end
    local epl_engaged = (v >= 0)
    local condition_in_start_range = (fuel_condition_lever_pos < 40)
    local epl_warning = epl_engaged and condition_in_start_range
    cas_fictitious[17] = epl_warning and 1 or 0
    write_cas_lvars()
end)

-- User's Hardware Generator Switch (0=Trip, 1=On, 2=Reset)
fsx_variable_subscribe("L:ASD_SWITCH_GENERATOR_POWER", "Number", function(v) 
    if v == nil then return end 
    -- The generator is considered "ON" for CAS warning purposes 
    -- in both the 1 (ON) and 2 (RESET) positions. Warning shows only at 0 (TRIP).
    generator_switch_on = (v > 0) 
    
    -- Recalculate generator power state based on new switch position and current Ng
    local is_below_46 = (live_ng_value < 46)
    gen_switch_on = (not is_below_46) and (generator_switch_on == true)
    
    if txt_cas_gen then 
        txt_set(txt_cas_gen, gen_switch_on and "ON" or "OFF") 
        txt_style(txt_cas_gen, gen_switch_on and "size:12; color:rgb(180,255,180); halign:center; valign:center;" or "size:12; color:rgb(255,180,180); halign:center; valign:center;") 
    end 
    
    if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    write_cas_lvars()
end)

-- User's Hardware Standby Power Switch
fsx_variable_subscribe("L:ASD_SWITCH_STBY_POWER_CE208EX", "Number", function(v) 
    if v == nil then return end 
    standby_power_switch_on = (v == 1) 
    
    write_cas_lvars()
end)

fsx_variable_subscribe("L:LeftTank1", "Number", function(v) if v == nil then return end fuel_tank_left_on = (v == 1) if txt_fuel_tank_left then txt_set(txt_fuel_tank_left, fuel_tank_left_on and "ON" or "OFF") end if txt_fuel_tank_left then txt_style(txt_fuel_tank_left, fuel_tank_left_on and "size:11; color:rgb(180,255,180); halign:center; valign:center;" or "size:11; color:rgb(255,180,180); halign:center; valign:center;") end write_cas_lvars() end)
fsx_variable_subscribe("L:RightTank1", "Number", function(v) if v == nil then return end fuel_tank_right_on = (v == 1) if txt_fuel_tank_right then txt_set(txt_fuel_tank_right, fuel_tank_right_on and "ON" or "OFF") end if txt_fuel_tank_right then txt_style(txt_fuel_tank_right, fuel_tank_right_on and "size:11; color:rgb(180,255,180); halign:center; valign:center;" or "size:11; color:rgb(255,180,180); halign:center; valign:center;") end write_cas_lvars() end)
fsx_variable_subscribe("L:C208_EMERGENCY_PWR_LEVER", "Number", function(v) if v == nil then return end emergency_power_lever_front = (v == 1) if txt_emerge_pwr_lever then txt_set(txt_emerge_pwr_lever, emergency_power_lever_front and "FRONT" or "IDLE") end if txt_emerge_pwr_lever then txt_style(txt_emerge_pwr_lever, emergency_power_lever_front and "size:12; color:rgb(180,255,180); halign:center; valign:center;" or "size:12; color:rgb(255,180,180); halign:center; valign:center;") end end)
-- Subscribe to User's Hardware Fire Detect Switch
fsx_variable_subscribe("L:ASD_SWITCH_FIRE_DETECT_CE208EX", "Number", function(v)
    if v == nil then return end
    fsx_variable_write("L:C208_TEST_FIRE", "Number", v)
    
    -- Drive the CAS Warning internally
    test_fire_detect_on = (v == 1)
    if txt_cas_test_fire then 
        txt_set(txt_cas_test_fire, test_fire_detect_on and "ON" or "OFF") 
        txt_style(txt_cas_test_fire, test_fire_detect_on and "size:12; color:rgb(180,255,180); halign:center; valign:center;" or "size:12; color:rgb(255,180,180); halign:center; valign:center;") 
    end
    -- Push the new CAS warnings out to the display logic
    write_cas_lvars()
end)
fsx_variable_subscribe("L:C208_TEST_FUEL_SEL", "Number", function(v) 
    if v == nil then return end 
    test_fuel_select_off_on = (v == 1) 
    if txt_cas_test_fuel_sel then 
        txt_set(txt_cas_test_fuel_sel, test_fuel_select_off_on and "ON" or "OFF") 
        txt_style(txt_cas_test_fuel_sel, test_fuel_select_off_on and "size:12; color:rgb(180,255,180); halign:center; valign:center;" or "size:12; color:rgb(255,180,180); halign:center; valign:center;") 
    end
    write_cas_lvars()
end)

-- LIGHTS & SYSTEM STATE SUBSCRIPTIONS
-- Mapped to specific "Complete String Names" from provided reference
fsx_variable_subscribe("TOGGLE_BEACON_LIGHTS", "Bool", function(v)
    if v ~= nil and battery_switch_on then
        light_on[1] = (v == true or v == 1)
        update_light_labels()
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)

fsx_variable_subscribe("LANDING_LIGHTS_TOGGLE", "Bool", function(v)
    if v ~= nil and battery_switch_on then
        light_on[2] = (v == true or v == 1)
        light_on[3] = (v == true or v == 1)
        update_light_labels()
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)

fsx_variable_subscribe("TOGGLE_TAXI_LIGHTS", "Bool", function(v)
    if v ~= nil and battery_switch_on then
        light_on[4] = (v == true or v == 1)
        update_light_labels()
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)

fsx_variable_subscribe("STROBES_TOGGLE", "Bool", function(v)
    if v ~= nil and battery_switch_on then
        light_on[5] = (v == true or v == 1)
        update_light_labels()
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)

fsx_variable_subscribe("TOGGLE_NAV_LIGHTS", "Bool", function(v)
    if v ~= nil and battery_switch_on then
        light_on[6] = (v == true or v == 1)
        update_light_labels()
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)

fsx_variable_subscribe("TOGGLE_CABIN_LIGHTS", "Bool", function(v)
    if v ~= nil and battery_switch_on then
        light_on[7] = (v == true or v == 1)
        update_light_labels()
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)

fsx_variable_subscribe("L:ASD_SWITCH_AVIONICS_N01", "Number", function(v)
    if v ~= nil and battery_switch_on then
        light_on[8] = (v == 1)
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)

fsx_variable_subscribe("L:ASD_SWITCH_AVIONICS_N02", "Number", function(v)
    if v ~= nil and battery_switch_on then
        light_on[9] = (v == 1)
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)

fsx_variable_subscribe("TOGGLE_WING_LIGHTS", "Bool", function(v)
    if v ~= nil and battery_switch_on then
        light_on[10] = (v == true or v == 1)
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)

fsx_variable_subscribe("PITOT HEAT:1", "Bool", function(v)
    if v ~= nil and battery_switch_on then
        light_on[11] = (v == true or v == 1)
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)

fsx_variable_subscribe("L:WINDSHIELD_HEAT", "Number", function(v)
    if v ~= nil and battery_switch_on then
        light_on[12] = (v == 1)
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
    end
end)


-- Amperage Subscriptions
for i=1, #LIGHTS do
    fsx_variable_subscribe(LIGHTS[i].amp_lvar, "Amperes", function(v)
        if v ~= nil then 
            LIGHTS[i].amps = v 
            if apply_light_load_to_electrical then apply_light_load_to_electrical() end
        end
    end)
end

-- Fuel condition lever: allow external L:COND_LEVER_POS writes (0–100)
fsx_variable_subscribe("L:COND_LEVER_POS", "Number", function(v)
    if v == nil or v ~= v then return end
    local was_low_idle = is_condition_lever_low_idle and is_condition_lever_low_idle()
    condition_lever_pos = math.max(0, math.min(100, v))
    local now_low_idle = is_condition_lever_low_idle and is_condition_lever_low_idle()
    if now_low_idle and not was_low_idle then
        if start_low_idle_itt_spike then start_low_idle_itt_spike() end
    end
    if apply_condition_lever_visual then apply_condition_lever_visual() end
end)

-- Ng Offset: allow external L:NG_OFFSET writes (-20 to 20 approx)
fsx_variable_subscribe("L:NG_OFFSET", "Number", function(v)
    if v == nil or v ~= v then return end
    ng_offset = v
end)

-- Temp control: allow external L:TEMP_CTRL_PERCENT writes (0–100); 0=closed, 50=mid, 100=open
fsx_variable_subscribe("L:TEMP_CTRL_PERCENT", "Number", function(v)
    if v == nil or v ~= v then return end
    temp_ctrl_percent = math.max(0, math.min(100, math.floor(v + 0.5)))
    if apply_temp_ctrl_visual then apply_temp_ctrl_visual() end
    if set_cas_caution then
        set_cas_caution(14, bleed_heat_on and temp_ctrl_percent >= 75)
    end
end)
if fsx_variable_write then
    pcall(fsx_variable_write, "L:TEMP_CTRL_PERCENT", "Number", 0)
end

-- Bleed air heat: allow external L:BLEED_AIR_HEAT writes (0=OFF, 1=ON)
fsx_variable_subscribe("L:BLEED_AIR_HEAT", "Number", function(v)
    if v == nil or v ~= v then return end
    bleed_heat_on = (v == 1)
    if apply_bleed_heat_visual then apply_bleed_heat_visual() end
end)

-- Cabin heat mix: allow external L:CABIN_HEAT_MIX writes (0=FLT push, 1=GND pull)
fsx_variable_subscribe("L:CABIN_HEAT_MIX", "Number", function(v)
    if v == nil or v ~= v then return end
    cabin_heat_mix_gnd = (v == 1)
    if apply_cabin_heat_mix_visual then apply_cabin_heat_mix_visual() end
end)

-- Fuel/oil shutoff: allow external L:FUEL_OIL_SHUTOFF writes (0=OFF, 1=ON)
fsx_variable_subscribe("L:FUEL_OIL_SHUTOFF", "Number", function(v)
    if v == nil or v ~= v then return end
    fuel_oil_shutoff_on = (v == 1)
    apply_fuel_oil_shutoff_visual()
end)
if fsx_variable_write then
    pcall(fsx_variable_write, "L:FUEL_OIL_SHUTOFF", "Number", fuel_oil_shutoff_on and 1 or 0)
end

-- Generator subscription (switch)
fsx_variable_subscribe(
    "GENERAL ENG GENERATOR SWITCH:1", "Bool",
    function(gen_switch)
        -- No custom logic to run here; simply stored for the switch position warning (not the output)
    end
)

-- Alternator subscription (switch only)
fsx_variable_subscribe(
    "GENERAL ENG MASTER ALTERNATOR:1", "Bool",
    function(alt_switch)
        -- Kept for future expandability or logic if needed
    end
)

-- Battery subscription (Trigger recalculation only)
fsx_variable_subscribe(
    "ELECTRICAL BATTERY LOAD", "Amperes",
    function(bat_load)
        if bat_load ~= nil then
            -- Fictitious mode: triggered only, not assigned
            if apply_light_load_to_electrical then apply_light_load_to_electrical() end
        end
    end
)

-- Main bus subscription (Trigger recalculation only)
fsx_variable_subscribe(
    "ELECTRICAL MAIN BUS VOLTAGE", "Volts",
    function(bus_voltage)
        if bus_voltage ~= nil then
            -- Fictitious mode: triggered only, not assigned
            if apply_light_load_to_electrical then apply_light_load_to_electrical() end
        end
    end
)

-- Generator and Alternator subscriptions (Trigger recalculation only)
fsx_variable_subscribe(
    "ELECTRICAL GENALT BUS AMPS:1", "Amperes",
    "ELECTRICAL GENALT BUS AMPS:2", "Amperes",
    function(gen_amps, alt_amps)
        if gen_amps ~= nil or alt_amps ~= nil then
            -- Fictitious mode: triggered only, not assigned
            if apply_light_load_to_electrical then apply_light_load_to_electrical() end
        end
    end
)

-- Priority logic: Generator > Alternator > Battery
-- Limits - BAT < 45A, ALT < 75A, BUS 24-28V (trip at 32.5V)

-- BU0836X button state trackers
local last_overlay_button_state = nil
local last_panel_button_state   = nil

-- BU0836X Interface 4 button mappings
local BU0836X_INTERFACE_NAME     = "BU0836X Interface 4"

local IGNITION_ON_BUTTON_INDEX   = 13  -- physical button 14
local IGNITION_OFF_BUTTON_INDEX  = 19  -- physical button 20

local FUEL_BOOST_ON_INDEX        = 6   -- physical button 7
local FUEL_BOOST_NORM_INDEX      = 5   -- physical button 6
local FUEL_BOOST_OFF_INDEX       = 4   -- physical button 5

local last_ignition_on_button_state   = nil
local last_ignition_off_button_state  = nil
local last_fuel_boost_on_state        = nil
local last_fuel_boost_norm_state      = nil
local last_fuel_boost_off_state       = nil

local function set_ignition_from_joystick(on_state)
    ignition_switch_on = on_state and true or false

    if fsx_variable_write then
        pcall(fsx_variable_write, "L:ASD_SWITCH_IGNITION_CE208", "Number", ignition_switch_on and 1 or 0)
    end

    apply_ignition_ui_and_cas()
    print("JOYSTICK IGNITION => " .. (ignition_switch_on and "ON" or "NORM"))
end

local function set_fuel_boost_from_joystick(mode)
    -- mode:
    --   2 = ON
    --   1 = NORM
    --   0 = OFF
    if fsx_variable_write then
        pcall(fsx_variable_write, "L:ASD_SWITCH_FUEL_AUXBP", "Number", mode)
    end

    if mode == 2 then
        print("FUEL BOOST PRESSED: ON")
    elseif mode == 1 then
        print("FUEL BOOST PRESSED: NORM")
    else
        print("FUEL BOOST PRESSED: OFF")
    end
end

-- BU0836X Master Handler Factory (Creates a unique handler with the controller name)
local function create_bu0836x_master_handler(controller_name)
    return function(type, index, value)
        if type ~= 1 then return end -- button events only

        -- General Diagnostic: Print ANY button press
        if value == 1 or value == true then
            print("BU0836X [" .. controller_name .. "] BUTTON PRESSED: " .. tostring(index))
        end

        -- Overlay Toggle (Button 0)
        if index == 0 then
            if last_overlay_button_state ~= value then
                last_overlay_button_state = value
                toggle_overlay()
            end
            return
        end

        -- Panel Visibility Toggle (Button 1)
        if index == 1 then
            if last_panel_button_state ~= value then
                last_panel_button_state = value
                toggle_panel_visible()
            end
            return
        end

        -- Restrict switch handling to Interface 4 only
        if controller_name ~= BU0836X_INTERFACE_NAME then return end

        -- Ignition ON
        if index == IGNITION_ON_BUTTON_INDEX then
            if last_ignition_on_button_state ~= value then
                last_ignition_on_button_state = value
                if value == true then
                    print("IGNITION PRESSED: 1")
                    set_ignition_from_joystick(true)
                end
            end
            return
        end

        -- Ignition NORM/OFF
        if index == IGNITION_OFF_BUTTON_INDEX then
            if last_ignition_off_button_state ~= value then
                last_ignition_off_button_state = value
                if value == true then
                    print("IGNITION PRESSED: 2")
                    set_ignition_from_joystick(false)
                end
            end
            return
        end

        -- Fuel Boost ON
        if index == FUEL_BOOST_ON_INDEX then
            if last_fuel_boost_on_state ~= value then
                last_fuel_boost_on_state = value
                if value == true then
                    set_fuel_boost_from_joystick(2)
                end
            end
            return
        end

        -- Fuel Boost NORM
        if index == FUEL_BOOST_NORM_INDEX then
            if last_fuel_boost_norm_state ~= value then
                last_fuel_boost_norm_state = value
                if value == true then
                    set_fuel_boost_from_joystick(1)
                end
            end
            return
        end

        -- Fuel Boost OFF
        if index == FUEL_BOOST_OFF_INDEX then
            if last_fuel_boost_off_state ~= value then
                last_fuel_boost_off_state = value
                if value == true then
                    set_fuel_boost_from_joystick(0)
                end
            end
            return
        end
    end
end

-- Visibility driven only by L:PANEL_VISIBLE (0 = hidden, 1 = visible).
fsx_variable_subscribe("L:PANEL_VISIBLE", "Number", function(val)
    if val == nil then return end
    current_lpanel_visible = (val == 1) and 1 or 0
    panel_visible = am_i_visible(current_lpanel_visible)
    apply_panel_visibility()
end)

-- Initial state & sync: only Instance A (main) drives L: vars and shows on load.
if my_instance == "A" then
    fsx_variable_write("L:PANEL_VISIBLE", "Number", 1)
    apply_panel_visibility()
    if timer_start and fsx_variable_write then
        timer_start(300, function()
            pcall(fsx_variable_write, "L:C208_BATTERY_SWITCH", "Number", battery_switch_on and 1 or 0)
            pcall(fsx_variable_write, "L:C208_GEN_SWITCH", "Number", gen_switch_on and 1 or 0)
            pcall(fsx_variable_write, "L:C208_ALT_SWITCH", "Number", alt_switch_on and 1 or 0)
            pcall(fsx_variable_write, "L:ASD_SWITCH_FUEL_AUXBP", "Number", boost_switch or 0)
            pcall(fsx_variable_write, "L:C208_STARTER_ON", "Number", starter_switch_on and 1 or 0)
            -- (Removed invalid ignition event-write)
            pcall(fsx_variable_write, "L:LeftTank1", "Number", fuel_tank_left_on and 1 or 0)
            pcall(fsx_variable_write, "L:RightTank1", "Number", fuel_tank_right_on and 1 or 0)
            pcall(fsx_variable_write, "L:C208_EMERGENCY_PWR_LEVER", "Number", emergency_power_lever_front and 1 or 0)
            pcall(fsx_variable_write, "L:C208_TEST_FIRE", "Number", test_fire_detect_on and 1 or 0)
            pcall(fsx_variable_write, "L:C208_TEST_FUEL_SEL", "Number", test_fuel_select_off_on and 1 or 0)
            -- Initialize custom amperage L-variables
            for i=1, #LIGHTS do
                if LIGHTS[i].amp_lvar then
                    pcall(fsx_variable_write, LIGHTS[i].amp_lvar, "Amperes", LIGHTS[i].amps)
                end
            end
        end)
    end
    timer_start(1500, 1500, function()
        fsx_variable_write("L:PANEL_VISIBLE", "Number", current_lpanel_visible or 1)
        if fsx_variable_write then
            pcall(fsx_variable_write, "L:C208_BATTERY_SWITCH", "Number", battery_switch_on and 1 or 0)
            pcall(fsx_variable_write, "L:C208_GEN_SWITCH", "Number", gen_switch_on and 1 or 0)
            pcall(fsx_variable_write, "L:C208_ALT_SWITCH", "Number", alt_switch_on and 1 or 0)
        end
    end)
else
    panel_visible = am_i_visible(current_lpanel_visible)
    apply_panel_visibility()
end

-- BU0836X joystick switch logic is defined above in the master handler block.

-- SI variables for overlay only (optional; L:Var used for panel)
local si_overlay_visible
if si_variable_create then
    local ok2, id2 = pcall(si_variable_create, "C208_OVERLAY_VISIBLE", "BOOL", overlay_visible)
    si_overlay_visible = (ok2 and id2) or nil
end

local controllers = game_controller_list()
for _, name in pairs(controllers) do
    if name == BU0836X_INTERFACE_NAME then
        print("Registering BU0836X master handler on: " .. name)
        game_controller_add(name, create_bu0836x_master_handler(name))
    end
end

-- Click top-left corner (40x40) to toggle panel visibility (L:PANEL_VISIBLE)
button_add(nil, nil, 0, 0, 40, 40, function() toggle_panel_visible() end, nil)

--=============================================================================
-- CAS CONNECTION (side panel → CAS: SI variables created at top of script)
--=============================================================================
-- SI variables already created at top so they exist before CAS subscribes.
-- 1=show caution, 0=hide.
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
    "L:CAS_RSVR_FUEL_LOW",   -- index 18
    "L:CAS_VOLTAGE_HIGH",    -- index 19
}

-- cas_fictitious and sim_cas already created at top of script for button callback scope

-- CAS is driven only by panel buttons (battery, gen, alt, etc.), not by aircraft/sim.
-- sim_cas is no longer merged so the CAS does not flicker when sim vars change at power-up.
local function effective_cas(i)
    if not battery_switch_on then return 0 end
    return (cas_fictitious[i] == 1) and 1 or 0
end

-- Sync GEN/ALT/fuel/starter into CAS only when battery is ON; when battery OFF all stay 0
local function update_cas_fictitious_states()
    if battery_switch_on then
        -- 1: VOLTAGE LOW (shows when generator and alternator are both off AND bus voltage < 24.5)
        local is_battery_source = (not gen_switch_on and not alt_switch_on)
        cas_fictitious[1] = (is_battery_source and current_bus_volts < 24.5) and 1 or 0
        -- 2: OIL PRESS LOW (strictly pressure based, cleared > 40 PSI)
        cas_fictitious[2] = (live_oil_pressure_psi < OIL_PRESS_LOW_PSI) and 1 or 0
        -- 3: FUEL PRESS LOW (Controlled by update_fuel_cas)
        -- 4: ENGINE FIRE (show when fire detect test switch is ON)
        if test_fire_detect_on ~= nil then
            cas_fictitious[4] = test_fire_detect_on and 1 or 0
        end
        -- 5: FUEL SELECT OFF (triggers when test switch ON, both tanks are OFF, or fuel < 25 gal in a tank)
        local both_tanks_off = (not fuel_tank_left_on and not fuel_tank_right_on)
        local fuel_under_25 = (fuel_qty_left_gal < 25 or fuel_qty_right_gal < 25)
        cas_fictitious[5] = (test_fuel_select_off_on or both_tanks_off or fuel_under_25) and 1 or 0
        -- 6: FUEL BOOST ON (Controlled by update_fuel_cas)
        -- 7: IGNITION ON (shows when ignition switch is ON, or starter is ON)
        cas_fictitious[7] = (ignition_switch_on or starter_switch_on) and 1 or 0
        -- 8: STARTER ON
        if starter_switch_on ~= nil then
            cas_fictitious[8] = starter_switch_on and 1 or 0
        end
        -- 9: GENERATOR OFF (warning shows when switch is TRIPPED (position 0) OR Ng < 46%)
        -- Tripped = always show, regardless of Ng. Ng < 46% = always show, regardless of switch.
        cas_fictitious[9] = (not generator_switch_on or live_ng_value < 46) and 1 or 0
        -- 10: STBY PWR ON (warning shows when switch is on)
        if standby_power_switch_on ~= nil then
            cas_fictitious[10] = standby_power_switch_on and 1 or 0
        end
        -- 11: GENERATOR OVERHEAT (> 200A)
        cas_fictitious[11] = (current_gen_amps > 200) and 1 or 0
        -- 12: ALTERNATOR OVERHEAT (> 75A)
        cas_fictitious[12] = (current_alt_amps > 75) and 1 or 0
        -- STBY PWR INOP (warning shows when switch is off)
        cas_fictitious[13] = not standby_power_switch_on and 1 or 0
        -- FUEL LEVEL CASCADING LOGIC (Indices 14, 15, 16)
        -- Priority: L-R (both) > individual L or R
        local l_low = (fuel_qty_left_lbs < 170)
        local r_low = (fuel_qty_right_lbs < 170)
        
        if l_low and r_low then
            cas_fictitious[14] = 0
            cas_fictitious[15] = 0
            cas_fictitious[16] = 1
        elseif l_low then
            cas_fictitious[14] = 1
            cas_fictitious[15] = 0
            cas_fictitious[16] = 0
        elseif r_low then
            cas_fictitious[14] = 0
            cas_fictitious[15] = 1
            cas_fictitious[16] = 0
        else
            cas_fictitious[14] = 0
            cas_fictitious[15] = 0
            cas_fictitious[16] = 0
        end
        -- Index 17 is EPL, driven by FSUIPC or axis handler
        -- 18: RSVR FUEL LOW (trigger when EITHER tank is below 82.5 gallons)
        cas_fictitious[18] = (fuel_qty_left_gal < 82.5 or fuel_qty_right_gal < 82.5) and 1 or 0
        -- 19: VOLTAGE HIGH (trigger when bus > 32V)
        cas_fictitious[19] = (current_bus_volts > 32.0) and 1 or 0
    end
end

-- Cache of last-written CAS values so we only write when changed (reduces flicker on pause/unpause)
local last_cas_written = {}

function write_cas_lvars()
    update_cas_fictitious_states()
    -- Effective = panel OR sim (when battery on); 0 when battery off
    local function eff(i) return effective_cas(i) end
    for i = 1, 47 do
        local v = eff(i)
        if last_cas_written[i] ~= v then
            last_cas_written[i] = v
            if si_variable_write and cas_si_ids[i] then
                pcall(si_variable_write, cas_si_ids[i], v)
            end
            if fsx_variable_write and CAS_LVARS[i] then
                if i == 7 then print("DEBUG: Pushing IGNITION ON to G1000: " .. tostring(v)) end
                pcall(fsx_variable_write, CAS_LVARS[i], "Number", v)
            end
        end
    end
end

-- Throttle CAS writes from sim subscriptions to reduce lag (94 writes per call was firing too often)
local cas_write_scheduled = false
local CAS_WRITE_THROTTLE_MS = 120
function schedule_cas_write()
    if cas_write_scheduled then return end
    cas_write_scheduled = true
    if timer_start then
        timer_start(CAS_WRITE_THROTTLE_MS, function()
            cas_write_scheduled = false
            write_cas_lvars()
        end)
    end
end

-- Clear all CAS warnings when battery is OFF (defined here so cas_fictitious and write_cas_lvars are in scope)
push_cas_all_off = function()
    for i = 1, 47 do
        cas_fictitious[i] = 0
    end
    last_cas_written = {}  -- force full write so CAS panel clears immediately
    write_cas_lvars()
end

-- Call from soft keys: set_cas_caution(index, true/false) then write_cas_lvars()
function set_cas_caution(index, show)
    if index >= 1 and index <= 47 then
        cas_fictitious[index] = show and 1 or 0
        write_cas_lvars()
    end
end

-- Toggle a caution (for soft keys): set_cas_caution_toggle(index)
function set_cas_caution_toggle(index)
    if index >= 1 and index <= 47 then
        cas_fictitious[index] = (cas_fictitious[index] == 1) and 0 or 1
        write_cas_lvars()
    end
end

-- ==========================================================
-- EMERGENCY POWER LEVER VALUE TEST ONLY
-- Interface 2 axis slider
-- Confirmed axis index = 4
-- ==========================================================

local EPL_INTERFACE_NAME = "BU0836X Interface 2"
local EMERGENCY_PWR_AXIS_INDEX = 4

local last_printed_value = nil

game_controller_add(EPL_INTERFACE_NAME, function(input_type, input_index, value)
    if input_type ~= 0 then return end       -- axis only
    if input_index ~= EMERGENCY_PWR_AXIS_INDEX then return end
    if value == nil then return end

    local v = tonumber(value)
    if v == nil then return end

    -- round to 3 decimals so log does not spam too much
    local rounded = math.floor(v * 1000 + 0.5) / 1000

    -- print only if value actually changed
    if last_printed_value ~= rounded then
        last_printed_value = rounded
        print("EMERGENCY POWER LEVER VALUE => " .. tostring(rounded))
        
        -- Trigger CAS Warning (Index 17) if value is 0 or above
        local epl_on = (rounded >= 0)
        cas_fictitious[17] = epl_on and 1 or 0
        write_cas_lvars()
    end
end)

print("Registered EMERGENCY POWER LEVER value test on: " .. EPL_INTERFACE_NAME)

-- BU0836X ignition handling is consolidated into the master handler above.
--=============================================================================
-- CAS: no aircraft/sim read. Warnings are driven only by panel (cas_fictitious).
--=============================================================================

write_cas_lvars()  -- Initial push so CAS gets 0 for all
-- Re-push after CAS may have loaded (SI vars must exist before CAS subscribes)
if timer_start then
    timer_start(300, function() write_cas_lvars() end)
    timer_start(800, function() write_cas_lvars() end)
    timer_start(100, function() apply_light_load_to_electrical() end)  -- Fictitious electrical push on load

    -- Recurring battery charge/drain simulation timer (500ms tick)
    local function battery_simulation_tick()
        if battery_charge == nil then battery_charge = 1.0 end
        
        -- Recharge when Gen/Alt are active
        if gen_switch_on or alt_switch_on then
            battery_charge = math.min(1.0, battery_charge + BATTERY_CHARGE_RATE)
        else
            -- Drain battery when main sources are OFF and battery/starter is ON
            if battery_switch_on then
                local drain = BATTERY_DRAIN_RATE
                if starter_switch_on then drain = drain * 50 end -- High drain during start
                battery_charge = math.max(0, battery_charge - drain)
            end
        end
        
        -- Recalculate electrical values with updated charge state
        if apply_light_load_to_electrical then apply_light_load_to_electrical() end
        
        timer_start(500, battery_simulation_tick)
    end
    timer_start(2000, battery_simulation_tick) -- Start after delay
end

-- PROP DE-ICE AMPS (removed - overlay image handles this display)

--=============================================================================
-- ALTERNATIVE: Prepar3D-specific subscriptions (if needed)
--=============================================================================
-- Use these when running in Prepar3D if fsx_variable_subscribe doesn't work
-- or if the sim uses different variable names (e.g. TURB ENG TORQUE vs ENG TORQUE).
if p3d_variable_subscribe then
    p3d_variable_subscribe("TURB ENG TORQUE:1", "Foot pounds", function(trq)
        if trq ~= nil and trq == trq then new_trq_value(trq) end
    end)
    p3d_variable_subscribe("TURB ENG ITT:1", "Rankine", function(ittR)
        if ittR ~= nil and ittR == ittR then new_itt_value(ittR) end
    end)
    p3d_variable_subscribe("TURB ENG N1:1", "Percent", function(ng)
        if ng ~= nil and ng == ng then 
            live_ng_value = ng
            new_ng_value(ng) 
        end
    end)
    print("Prepar3D: Registered TURB ENG TORQUE, ITT, N1 subscriptions")
end
--=============================================================================
-- G1000 SOFTKEY INTEGRATION
--=============================================================================
-- MFD Softkey 1 (Overlay Toggle)
fsx_variable_subscribe("L:EFIS_Fly.MFD_SOFTKEY_1", "Number", function(v)
    if v == 1 then
        if toggle_overlay then toggle_overlay() end
        fsx_variable_write("L:EFIS_Fly.MFD_SOFTKEY_1", "Number", 0)
    end
end)

-- MFD Softkey 12 (Panel Visibility Swap)
fsx_variable_subscribe("L:EFIS_Fly.MFD_SOFTKEY_12", "Number", function(v)
    if v == 1 then
        if toggle_panel_visible then toggle_panel_visible() end
        fsx_variable_write("L:EFIS_Fly.MFD_SOFTKEY_12", "Number", 0)
    end
end)

-- Reversionary Mode (DISPLAY BACKUP)
-- Sync the panel visibility back to Main when active
fsx_variable_subscribe("L:EFIS_Fly.AUDIO_ACTIVATE_REVERSIONARY", "Number", function(v)
    if v == 1 then
        fsx_variable_write("L:PANEL_VISIBLE", "Number", 1)
        if apply_panel_visibility then apply_panel_visibility() end
    end
end)

-- Support for hardware button callbacks (if defined in Air Manager)
function press_mfd_softkey_1() fsx_variable_write("L:EFIS_Fly.MFD_SOFTKEY_1", "Number", 1) end
function press_mfd_softkey_12() fsx_variable_write("L:EFIS_Fly.MFD_SOFTKEY_12", "Number", 1) end
function activate_reversionary_mode() fsx_variable_write("L:EFIS_Fly.AUDIO_ACTIVATE_REVERSIONARY", "Number", 1) end

if hw_button_add then
    hw_button_add("Softkey 1", press_mfd_softkey_1)
    hw_button_add("Softkey 12", press_mfd_softkey_12)
    hw_button_add("Reversionary Mode", activate_reversionary_mode)
end

--=============================================================================
-- HARDWARE SWITCH SUBSCRIPTIONS (Manual overrides for physical panels)
--=============================================================================
-- Hardware Master Battery Switch
fsx_variable_subscribe("L:ASD_SWITCH_MASTER_BAT_C182T", "Number", function(v)
    if v == nil then return end
    if fsx_variable_write then
        -- Forward to internal battery handler which manages CAS and electrical system
        pcall(fsx_variable_write, "L:C208_BATTERY_SWITCH", "Number", v == 1 and 1 or 0)
    end
end)

-- Hardware Fire Detect Switch
fsx_variable_subscribe("L:ASD_SWITCH_FIRE_DETECT_CE208EX", "Number", function(v)
    if v == nil then return end
    if fsx_variable_write then
        pcall(fsx_variable_write, "L:C208_TEST_FIRE", "Number", v == 1 and 1 or 0)
    end
end)    
