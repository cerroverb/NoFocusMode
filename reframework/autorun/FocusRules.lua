-- Focus Rules: Manual Aim / Focus Aim Restricted (MA) for Monster Hunter Wilds.
-- With a melee weapon drawn, the focus button on its own no longer enters Focus Mode, and the focus
-- reticle stays hidden. Focus button + R1 still performs a Focus Strike, turned only the way a normal
-- attack turns, never towards the camera. R1 on its own keeps its normal use, unless "R1 alone does
-- the Focus Strike" is on, in which case R1 alone strikes and no longer sheathes.
-- Monster wounds are highlighted while the focus button is held.
-- With an Insect Glaive, focus button + B during the charged attack with all three extracts still
-- does the Rising Spiral Slash.
-- Ranged weapons and a sheathed weapon keep the game's behavior.
-- Switches are in the REFramework menu under "Focus Rules" and are saved to reframework/data/FocusRules.json.
-- With "Log focus state" on, focus state, the focus button and actions are written to re2_framework_log.txt.
-- Logging is off by default. Its per-character hook is only installed when it
-- is on at script load.
--
-- Method names come from the game's il2cpp_dump.json (REFramework SDK dump).
-- Hook patterns follow Bimmr's MHWS-Weapon-Swapper (HunterCharacter.update, get_IsMaster,
-- BaseActionController:get_CurrentAction, json config) and MHWS-Buffer (getMasterPlayerInfo,
-- SKIP_ORIGINAL, replacing a return value with sdk.to_ptr): https://github.com/Bimmr
-- Reading keys follows getKey() on the command controller's merged input in DerKleineLi's MHWs-MIGGA
-- (Kinsect_dont_come_back.lua): https://github.com/DerKleineLi/MHWs-MIGGA
-- The wound highlight follows kmy0's HudController (hud/hook/options/scar.lua), which sets
-- app.cEnemyLoopEffectHighlight._IsAim from a hook on isActivate(), and hiding the reticle follows its
-- slinger_reticle element (findDisplayControl, _TargetControl, set_ForceInvisible):
-- https://github.com/kmy0/HudController

local CONFIG_PATH = "FocusRules.json"

local settings = {
    log_state = false,
    focus_strike_only = true,
    no_aim_turning = true,
    wounds_only_while_focus_held = true,
    hide_focus_reticle = true,
    no_target_pull = true,
    rising_spiral_slash = true,
    strike_on_r1_alone = false,
}

-- app.WeaponDef.TYPE: LONG_SWORD = 0 through ROD = 10 are melee. BOW, HEAVY_BOWGUN and LIGHT_BOWGUN follow.
local LAST_MELEE_WEAPON_TYPE = 10
-- app.PlayerKey.PAD
local PAD_KEY_FOCUS_STRIKE = 3 -- ATTACK_SP_B, R1 on a pad
local PAD_KEY_FOCUS = 18 -- AIM
local PAD_KEY_ATTACK_01 = 1 -- B on a pad
-- Insect Glaive (app.WeaponDef.TYPE ROD). Its Rising Spiral Slash is the focus button + B during the
-- charged attack with all three extracts (Wp10Action.cHoldAttackSuper).
local INSECT_GLAIVE = 10
local RISING_SPIRAL_SLASH_FROM = "cHoldAttackSuper"
-- app.HunterDef.ACTION_START_TURN_TYPE: the _AIM variants turn towards the camera.
local START_TURN_FOR_AIM = { [3] = 1, [4] = 2 } -- LV1_AIM -> LV1, LV2_AIM -> LV2

-- Frames the focus button is held on for the game after a Focus Strike press, so Focus Mode can
-- start, and frames it stays on after the strike press is passed to the game.
local STRIKE_WINDOW_FRAMES = 30
local FRAMES_AFTER_STRIKE = 10

local function load_settings()
    local saved = json.load_file(CONFIG_PATH)
    if not saved then return end
    for key in pairs(settings) do
        if saved[key] ~= nil then
            settings[key] = saved[key]
        end
    end
end

load_settings()

local function log_line(text)
    if settings.log_state then
        log.info("[FocusRules] " .. string.format("%.3f ", os.clock()) .. text)
    end
end

local function get_master_hunter()
    local player_manager = sdk.get_managed_singleton("app.PlayerManager")
    if not player_manager then return nil end
    local player_info = player_manager:getMasterPlayerInfo()
    if not player_info then return nil end
    return player_info:get_Character()
end

local function is_melee(hunter)
    local weapon_type = hunter:get_WeaponType()
    return weapon_type >= 0 and weapon_type <= LAST_MELEE_WEAPON_TYPE
end

-- More than one hunter object can report get_IsMaster, so the master is matched
-- against the character from PlayerManager instead. Its address is looked up once per frame,
-- and only the address is kept, so no hook calls into an object from an earlier frame.
local master_hunter_address = nil
local hide_focus_reticle_now = false

re.on_frame(function()
    local master = get_master_hunter()
    local address = master and master:get_address() or nil
    if address ~= master_hunter_address then
        log_line("master hunter " .. (address and string.format("%x", address) or "none"))
    end
    master_hunter_address = address
    local melee_drawn = master ~= nil and is_melee(master) and master:get_IsWeaponOn()
    hide_focus_reticle_now = settings.hide_focus_reticle and settings.focus_strike_only and melee_drawn
end)

local function is_master_hunter(hunter)
    return hunter ~= nil and master_hunter_address ~= nil and hunter:get_address() == master_hunter_address
end

local function is_master_melee(hunter)
    return is_master_hunter(hunter) and is_melee(hunter)
end

local function is_master_melee_drawn(hunter)
    return is_master_melee(hunter) and hunter:get_IsWeaponOn()
end

local function hunter_from_args(args)
    return sdk.to_managed_object(args[2])
end

-- Focus button state as the player pressed it, read before this script changes it.
local focus_button_held = false

-- Focus Mode stance actions every weapon has. While the hunter is still in one
-- of these after the strike press was sent, the game has not started the strike yet.
local FOCUS_STANCE_ACTIONS = { cAimIdle = true, cAimIdleHigh = true, cAimWalk = true, cAimWalkStop = true }

local strike = { frames_left = 0, pending = false, sent = false, start_action = nil, key_index = PAD_KEY_FOCUS_STRIKE }

local function current_action_name(hunter)
    local action = hunter:get_BaseActionController():get_CurrentAction()
    return action and action:get_type_definition():get_name() or "none"
end

local function reset_strike()
    strike.frames_left = 0
    strike.pending = false
    strike.sent = false
end

-- Calls blocked by "No pull towards the target" during the current strike, logged when it ends.
local target_pull_blocks = {}

local function start_strike_window(hunter, input, key_index)
    strike.frames_left = STRIKE_WINDOW_FRAMES
    strike.pending = true
    strike.sent = false
    strike.start_action = current_action_name(hunter)
    strike.key_index = key_index
    input:getKey(key_index):clear()
    target_pull_blocks = {}
    log_line(string.format("strike armed during %s key %d", strike.start_action, key_index))
end

local function send_strike_press(strike_key)
    strike_key:set_On(true)
    strike_key:set_OnTrigger(true)
    if not strike.sent then
        log_line("strike passed to game")
    end
    strike.sent = true
end

-- Keeps Focus Mode on for the game and sends the press once Focus Mode is active. The press is sent
-- again each frame until the hunter leaves the action it was in and the Focus Mode stance actions.
local function hold_focus_for_strike(hunter, focus_key, strike_key)
    strike.frames_left = strike.frames_left - 1
    focus_key:set_On(true)
    if not strike.pending then return end

    local action = current_action_name(hunter)
    if strike.sent and action ~= strike.start_action and not FOCUS_STANCE_ACTIONS[action] then
        strike.pending = false
        strike.frames_left = math.min(strike.frames_left, FRAMES_AFTER_STRIKE)
        local blocked = {}
        for name, count in pairs(target_pull_blocks) do
            table.insert(blocked, name .. "=" .. count)
        end
        log_line("strike ended in " .. action .. " target pull blocked " .. table.concat(blocked, " "))
    elseif hunter:get_HunterContext():get_IsAim() then
        send_strike_press(strike_key)
    end
    if strike.frames_left == 0 and strike.pending then
        log_line("strike window ended in " .. action)
    end
end

-- app.PlayerKey.PAD ATTACK_00 to ATTACK_SP_B, logged while the focus button is held to confirm
-- which one the game uses for Focus Strikes.
local ATTACK_KEYS = { 0, 1, 2, 3 }

local function log_attack_presses(input)
    for _, key_index in ipairs(ATTACK_KEYS) do
        if input:getKey(key_index):get_OnTrigger() then
            log_line("attack key " .. key_index .. " pressed with focus button held")
        end
    end
end

local function is_rising_spiral_slash_press(hunter, input)
    return settings.rising_spiral_slash and focus_button_held and hunter:get_WeaponType() == INSECT_GLAIVE
        and input:getKey(PAD_KEY_ATTACK_01):get_OnTrigger()
        and current_action_name(hunter) == RISING_SPIRAL_SLASH_FROM
end

-- The key of a Focus Mode move pressed this frame: a Focus Strike, or the Insect Glaive's Rising
-- Spiral Slash. Both are passed to the game through the same window that holds Focus Mode on.
local function focus_move_pressed(hunter, input)
    local strike_key = input:getKey(PAD_KEY_FOCUS_STRIKE)
    if strike_key:get_OnTrigger() and (focus_button_held or settings.strike_on_r1_alone) then
        return PAD_KEY_FOCUS_STRIKE
    end
    if is_rising_spiral_slash_press(hunter, input) then
        return PAD_KEY_ATTACK_01
    end
    return nil
end

-- The command controller merges pad and keyboard input here, before the game reads its commands.
local merging_controller = nil

sdk.hook(sdk.find_type_definition("app.cPlayerCommandController"):get_method("mergeAndUpdateInput"), function(args)
    merging_controller = sdk.to_managed_object(args[2])
end, function(retval)
    local controller = merging_controller
    merging_controller = nil
    local hunter = controller and controller:get_Character()
    if not is_master_hunter(hunter) then return retval end

    local input = controller:get_MergedVirtualInput()
    local focus_key = input:getKey(PAD_KEY_FOCUS)
    focus_button_held = focus_key:get_On()
    if focus_button_held then
        log_attack_presses(input)
    end

    if not settings.focus_strike_only or not is_master_melee_drawn(hunter) then
        reset_strike()
        return retval
    end
    if strike.frames_left == 0 then
        local key_index = focus_move_pressed(hunter, input)
        if key_index then
            start_strike_window(hunter, input, key_index)
        end
    end
    if strike.frames_left > 0 then
        hold_focus_for_strike(hunter, focus_key, input:getKey(strike.key_index))
    else
        focus_key:clear()
    end
    return retval
end)

-- Focus Strikes and other Focus Mode actions start with an _AIM turn towards the camera.
-- Using the plain turn makes them turn like a normal attack.
sdk.hook(sdk.find_type_definition("app.HunterCharacter"):get_method("beginActionStartTurn"), function(args)
    if not settings.no_aim_turning or not is_master_melee(hunter_from_args(args)) then return end
    local turn_type = sdk.to_int64(args[4]) & 0xFFFFFFFF
    local plain_turn = START_TURN_FOR_AIM[turn_type]
    if plain_turn then
        args[4] = sdk.to_ptr(plain_turn)
        log_line(string.format("start turn %d -> %d", turn_type, plain_turn))
    end
end)

-- In Focus Mode the hunter turns to the camera through rotateAimTurnLook,
-- gated by isEnableAimTurn.
local hunter_type = sdk.find_type_definition("app.HunterCharacter")
local aim_turn_check_hunter = nil

sdk.hook(hunter_type:get_method("isEnableAimTurn"), function(args)
    aim_turn_check_hunter = hunter_from_args(args)
end, function(retval)
    local hunter = aim_turn_check_hunter
    aim_turn_check_hunter = nil
    if settings.no_aim_turning and is_master_melee(hunter) then
        return sdk.to_ptr(0)
    end
    return retval
end)

local function skip_aim_turn_rotation(args)
    if settings.no_aim_turning and is_master_melee(hunter_from_args(args)) then
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end

sdk.hook(hunter_type:get_method("rotateAimTurnLook"), skip_aim_turn_rotation)
sdk.hook(hunter_type:get_method("rotateAimTurnLook_WpOffset"), skip_aim_turn_rotation)

-- A Focus Strike picks a target on the monster (decideAimAttackSightPos, onAimAttackTargetDecided on
-- the weapon handling) and keeps tracking it during the attack (acAimTargetHold.updateTargetPos).
-- Analysis of the SDK dump points to that target as the source of the pull towards the wound, so
-- with this switch on no target is set and the strike moves the way its animation does.
local function block_target_pull(hunter, name)
    if not settings.no_target_pull or not is_master_melee(hunter) then return end
    target_pull_blocks[name] = (target_pull_blocks[name] or 0) + 1
    return sdk.PreHookResult.SKIP_ORIGINAL
end

local weapon_handling_type = sdk.find_type_definition("app.cHunterWeaponHandlingBase")
for _, method_name in ipairs({ "decideAimAttackSightPos", "onAimAttackTargetDecided" }) do
    sdk.hook(weapon_handling_type:get_method(method_name), function(args)
        return block_target_pull(sdk.to_managed_object(args[2]):get_Hunter(), method_name)
    end)
end

sdk.hook(sdk.find_type_definition("app.PlayerCommonActionComponent.acAimTargetHold"):get_method("updateTargetPos"),
    function(args)
        return block_target_pull(sdk.to_managed_object(args[2]):get_Chara(), "updateTargetPos")
    end)

-- Reticle panels shown while the script holds Focus Mode on for a strike. kmy0's HudController maps
-- the focus reticle (UI020002) onto the general reticle HUD (UI020000) in data/ace.lua
-- (hudless_to_hud), so both are hidden.
-- GUIID values are from app.GUIID.ID in the SDK dump.
local FOCUS_RETICLE_GUI_IDS = { 46, 50 } -- UI020000, UI020002
-- GUI020016 turns visible at every strike and invisible after it. It is hidden only while the
-- strike window is open, since it also shows outside Focus Mode.
local STRIKE_ONLY_GUI_ID = 61 -- UI020016
local strike_panel_hidden = false
local focus_reticle_hidden = false

local function get_hud_display_manager()
    local gui_manager = sdk.get_managed_singleton("app.GUIManager")
    return gui_manager and gui_manager:get_HudDisplayManager()
end

-- Like kmy0's HudController, the change is written after app.GUIManager.lateUpdateApp(), once the
-- game has finished its own HUD updates for the frame. Panels are shown again only once, so the
-- game's own visibility is left alone.
local function apply_focus_reticle_visibility(display_manager)
    if not hide_focus_reticle_now and not focus_reticle_hidden then return end
    for _, gui_id in ipairs(FOCUS_RETICLE_GUI_IDS) do
        -- No display control exists until the HUD is loaded (title screen, loading).
        local display_control = display_manager:findDisplayControl(gui_id)
        if display_control and display_control._TargetControl then
            display_control._TargetControl:set_ForceInvisible(hide_focus_reticle_now)
        end
    end
    if focus_reticle_hidden ~= hide_focus_reticle_now then
        log_line("focus reticle hidden=" .. tostring(hide_focus_reticle_now))
    end
    focus_reticle_hidden = hide_focus_reticle_now
end

local function apply_strike_panel_visibility(display_manager)
    local hide = settings.hide_focus_reticle and strike.frames_left > 0
    if not hide and not strike_panel_hidden then return end
    local display_control = display_manager:findDisplayControl(STRIKE_ONLY_GUI_ID)
    if display_control and display_control._TargetControl then
        display_control._TargetControl:set_ForceInvisible(hide)
    end
    strike_panel_hidden = hide
end

-- With logging on: logs every HUD panel that turns visible or invisible while a melee weapon is
-- drawn.
local hud_panel_visible = {}

local function log_hud_panel_changes(display_manager)
    local display_controls = display_manager._DisplayControls
    for i = 0, display_controls:get_Count() - 1 do
        local display_control = display_controls:get_Item(i)
        local control = display_control._TargetControl
        if control then
            local name = display_control._Owner:get_type_definition():get_name()
            local visible = display_control:isHudVisible() and control:get_ActualVisible()
            if hud_panel_visible[name] ~= nil and hud_panel_visible[name] ~= visible then
                log_line(string.format("hud %s visible=%s", name, tostring(visible)))
            end
            hud_panel_visible[name] = visible
        end
    end
end

sdk.hook(sdk.find_type_definition("app.GUIManager"):get_method("lateUpdateApp"), nil, function(retval)
    local display_manager = get_hud_display_manager()
    if not display_manager then return retval end
    apply_focus_reticle_visibility(display_manager)
    apply_strike_panel_visibility(display_manager)
    if settings.log_state and hide_focus_reticle_now then
        log_hud_panel_changes(display_manager)
    end
    return retval
end)

local highlight_effect = nil
-- With logging on: once per second, how often the game asked for the wound highlight, how often its
-- own answer was "on", and what this script answered.
local highlight_counts = { calls = 0, game_on = 0, script_on = 0, since = 0 }

local function log_highlight_counts()
    local now = os.clock()
    if now - highlight_counts.since < 1 then return end
    if highlight_counts.calls > 0 then
        log_line(string.format("wound highlight calls=%d game_on=%d script_on=%d focus_button=%s",
            highlight_counts.calls, highlight_counts.game_on, highlight_counts.script_on,
            tostring(focus_button_held)))
    end
    highlight_counts.calls, highlight_counts.game_on, highlight_counts.script_on = 0, 0, 0
    highlight_counts.since = now
end

sdk.hook(sdk.find_type_definition("app.cEnemyLoopEffectHighlight"):get_method("isActivate"), function(args)
    highlight_effect = sdk.to_managed_object(args[2])
end, function(retval)
    local effect = highlight_effect
    highlight_effect = nil
    if settings.log_state then
        highlight_counts.calls = highlight_counts.calls + 1
        if (sdk.to_int64(retval) & 1) == 1 then
            highlight_counts.game_on = highlight_counts.game_on + 1
        end
        if settings.wounds_only_while_focus_held and focus_button_held then
            highlight_counts.script_on = highlight_counts.script_on + 1
        end
        log_highlight_counts()
    end
    if not settings.wounds_only_while_focus_held or not effect then return retval end
    effect._IsAim = focus_button_held
    return sdk.to_ptr(focus_button_held and 1 or 0)
end)

local last_state = {}

local function read_focus_state(hunter)
    local context = hunter:get_HunterContext()
    local action = hunter:get_BaseActionController():get_CurrentAction()
    return {
        is_aim = context:get_IsAim(),
        aim_type = context:get_AimType(),
        action = action and action:get_type_definition():get_full_name() or "none",
        focus_button = focus_button_held,
    }
end

local function log_state_changes(hunter)
    local state = read_focus_state(hunter)
    if state.action ~= last_state.action then
        log_line("action " .. state.action)
    end
    if state.is_aim ~= last_state.is_aim or state.aim_type ~= last_state.aim_type then
        log_line(string.format("focus is_aim=%s aim_type=%d", tostring(state.is_aim), state.aim_type))
    end
    if state.focus_button ~= last_state.focus_button then
        log_line("focus_button=" .. tostring(state.focus_button))
    end
    last_state = state
end

-- update is inherited from app.CharacterBase, so this hook runs for every monster and NPC each frame.
-- It is installed only when logging is on at script load.
if settings.log_state then
    sdk.hook(hunter_type:get_method("update"), function(args)
        if not settings.log_state then return end
        local hunter = hunter_from_args(args)
        if not hunter or not hunter:get_type_definition():is_a("app.HunterCharacter") then return end
        if not is_master_hunter(hunter) then return end
        log_state_changes(hunter)
    end)
end

local function setting_checkbox(label, key)
    local changed, value = imgui.checkbox(label, settings[key])
    if changed then
        settings[key] = value
        json.dump_file(CONFIG_PATH, settings)
        log_line(string.format("setting %s=%s", key, tostring(value)))
    end
end

re.on_draw_ui(function()
    if not imgui.tree_node("Focus Rules") then return end
    setting_checkbox("L2 alone does nothing, L2 + R1 does a Focus Strike (melee, weapon drawn)", "focus_strike_only")
    setting_checkbox("No turning towards the camera (melee)", "no_aim_turning")
    setting_checkbox("Show wounds only while L2 is held", "wounds_only_while_focus_held")
    setting_checkbox("Hide the focus reticle (melee, weapon drawn)", "hide_focus_reticle")
    setting_checkbox("No pull towards the target on Focus Strikes (melee)", "no_target_pull")
    setting_checkbox("L2 + B does the Rising Spiral Slash (Insect Glaive charged attack, three extracts)", "rising_spiral_slash")
    setting_checkbox("R1 alone does the Focus Strike, R1 no longer sheathes (melee, weapon drawn)", "strike_on_r1_alone")
    setting_checkbox("Log focus state (applies after Reset scripts)", "log_state")
    imgui.tree_pop()
end)
