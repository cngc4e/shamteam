@include libs/db2.lua
@include libs/PairTable.lua

-- Module variables
local translations = {}
local players = {}  -- module room player data
local playerData = {}  -- module persistent player data
local pd_loaded = {}  -- table of bool flags denoting players in which have successfully loadaed data
local roundv = {}  -- data spanning the lifetime of the round
local new_game_vars = {}  -- data spanning the lifetime till the next eventNewGame
local mapcodes = {}
local module_started = false

@include translations-gen/*.lua

-- Cached variable lookups (or rather in the fancy name of "spare my brains & hands lol")
local room = tfm.get.room
local band = bit32.band     -- x & Y
local bor = bit32.bor       -- x | y
local bnot = bit32.bnot     -- ~x
local bxor = bit32.bxor     -- x ^ y
local lshift = bit32.lshift -- x << y
local rshift = bit32.rshift -- x >> y

-- Keeps an accurate list of players and their states by rely on asynchronous events to update
-- This works around playerList issues which are caused by it relying on sync and can be slow to update
local pL = {}
do
    local states = {
        "room",
        "alive",
        "dead",
        "shaman",
        "non_shaman",
        "spectator"
    }
    for i = 1, #states do
        pL[states[i]] = PairTable:new()
    end
end

----- ENUMS / CONST DEFINES
-- Permission levels
local GROUP_GUEST = 1
local GROUP_PLAYER = 2
local GROUP_ADMIN = 3
local GROUP_STAFF = 4
local GROUP_DEV = 5

-- Key trigger types
local DOWN_ONLY = 1
local UP_ONLY = 2
local DOWN_ONLY = 3

-- Windows
local WINDOW_GUI = lshift(0, 7)
local WINDOW_HELP = lshift(1, 7)
local WINDOW_LOBBY = lshift(2, 7)
local WINDOW_OPTIONS = lshift(3, 7)
local WINDOW_DB_MAP = lshift(4, 7)
local WINDOW_DB_HISTORY = lshift(5, 7)

-- TextAreas
local TA_SPECTATING = 9000

-- MOD FLAGS
local MOD_TELEPATHY = lshift(1, 0)
local MOD_WORK_FAST = lshift(1, 1)
local MOD_BUTTER_FINGERS = lshift(1, 2)
local MOD_SNAIL_NAIL = lshift(1, 3)

-- OPTIONS FLAGS
local OPT_ANTILAG = lshift(1, 0)
local OPT_GUI = lshift(1, 1)
local OPT_CIRCLE = lshift(1, 2)
local OPT_LANGUAGE = lshift(1, 3)

-- Map properties flags
local MP_PORTALS = lshift(1, 0)
local MP_OPPORTUNIST = lshift(1, 1)
local MP_NOBALLOON = lshift(1, 2)
local MP_SEPARATESHAM = lshift(1, 3)

-- Link IDs
local LINK_DISCORD = 1

-- AntiLag ping (ms) thresholds
local ANTILAG_WARN_THRESHOLD = 690
local ANTILAG_FORCE_THRESHOLD = 1100

-- GUI color defs
local GUI_BTN = "<font color='#EDCC8D'>"

-- Images
local IMG_FEATHER_HARD = "172e1332b11.png" -- hard feather 30px width
local IMG_FEATHER_DIVINE = "172e14b438a.png" -- divine feather 30px width
local IMG_FEATHER_HARD_DISABLED = "172ed052b25.png"
local IMG_FEATHER_DIVINE_DISABLED = "172ed050e45.png"
local IMG_TOGGLE_ON = "172e5c315f1.png" -- 30px width
local IMG_TOGGLE_OFF = "172e5c335e7.png" -- 30px width
local IMG_LOBBY_BG = "172e68f8d24.png"
local IMG_HELP = "172e72750d9.png" -- 18px width
local IMG_OPTIONS_BG = "172eb766bdd.png" -- 240 x 325
local IMG_RANGE_CIRCLE = "172ef5c1de4.png" -- 240 x 240

-- Modes
local TSM_HARD = 1
local TSM_DIV = 2

-- Room
local DEFAULT_MAX_PLAYERS = 50

-- Module ID (this is per-Lua dev, change it accordingly and careful not to let your data get overridden!)
local MODULE_ID = 2

-- Default player data
local DEFAULT_PD = {
    exp = 0,
    toggles = 0,
}
-- Toggles enabled by default
DEFAULT_PD.toggles = bor(DEFAULT_PD.toggles, OPT_GUI)
DEFAULT_PD.toggles = bor(DEFAULT_PD.toggles, OPT_CIRCLE)

-- Others
local staff = {["Cass11337#8417"]=true, ["Emeryaurora#0000"]=true, ["Pegasusflyer#0000"]=true, ["Tactcat#0000"]=true, ["Leafileaf#0000"]=true, ["Rini#5475"]=true, ["Rayallan#0000"]=true, ["Shibbbbbyy#1143"]=true}
local dev = {["Cass11337#8417"]=true, ["Casserole#1798"]=true}

local mods = {
    [MOD_TELEPATHY] = {"Telepathic Communication", 0.5, "Disables prespawn preview. You won't be able to see what and where your partner is trying to spawn."},
    [MOD_WORK_FAST] = {"We Work Fast!", 0.3, "Reduces building time limit by 60 seconds. For the quick hands."},
    [MOD_BUTTER_FINGERS] = {"Butter Fingers", -0.5, "Allows you and your partner to undo your last spawned object by pressing U up to two times."},
    [MOD_SNAIL_NAIL] = {"Snail Nail", -0.5, "Increases building time limit by 30 seconds. More time for our nails to arrive."},
}

local options = {
    [OPT_ANTILAG] = {"AntiLag", "Attempt to minimise impacts on buildings caused by delayed anchor spawning during high latency."},
    [OPT_GUI] = {"Show GUI", "Whether to show or hide the help menu, player settings and profile buttons on-screen."},
    [OPT_CIRCLE] = {"Show partner's range", "Toggles an orange circle that shows the spawning range of your partner in Team Hard Mode."},
}

----- Forward declarations (local)
local keys, cmds, cmds_alias, callbacks, sWindow, GetExpMult, SetSpectate, UpdateCircle

----- GENERAL UTILS
local function math_round(num, dp)
    local mult = 10 ^ (dp or 0)
    return math.floor(num * mult + 0.5) / mult
end

local function string_split(str, delimiter)
    local delimiter,a = delimiter or ',', {}
    for part in str:gmatch('[^'..delimiter..']+') do
        a[#a+1] = part
    end
    return a
end

local function table_copy(tbl)
    local out = {}
    for k, v in next, tbl do
        out[k] = v
    end
    return out
end

local function dumptbl (tbl, indent)
    if not indent then indent = 0 end
    for k, v in pairs(tbl) do
        formatting = string.rep("  ", indent) .. k .. ": "
        if type(v) == "table" then
            print(formatting)
            dumptbl(v, indent+1)
        elseif type(v) == 'boolean' then
            print(formatting .. tostring(v))
        else
            print(formatting .. v)
        end
    end
end

local function tl(name, lang)
    local lang = translations[lang] and lang or "en"
    if translations[lang][name] then
        return translations[lang][name]
    else
        return name
    end
end

local function ZeroTag(pn, add) --#0000 removed for tag matches
    if add then
        if not pn:find('#') then
            return pn.."#0000"
        else return pn
        end
    else
        return pn:find('#0000') and pn:sub(1,-6) or pn
    end
end

local function pFind(target, pn)
    local ign = string.lower(target or ' ')
    for name in pairs(room.playerList) do
        if string.lower(name):find(ign) then return name end
    end
    if pn then tfm.exec.chatMessage("<R>error: no such target", pn) end
end

local function pDisp(pn)
    -- TODO: check if the player has the same name as another existing player in the room.
    return pn and (pn:find('#') and pn:sub(1,-6)) or "N/A"
end

local function pythag(x1, y1, x2, y2, r)
	local x,y,r = x2-x1, y2-y1, r+r
	return x*x+y*y<r*r
end

local function expDisp(n, addColor)
    if addColor == nil then addColor = true end
    local sign, color = "", "<J>"
    if n > 0 then
        sign = "+"
        color = "<VP>"
    elseif n < 0 then
        sign = "-"
        color = "<R>"
    end
    if not addColor then color = "" end
    return color..sign..math.abs(n*100).."%"
end

----- HELPERS
@include helpers/map_sched.lua
@include helpers/MDHelper.lua
@include helpers/PDHelper.lua

-- Handles map rotation and scoring
local rotate_evt
do
    local function rotate()
        if not MDHelper.getMdLoaded() then
            print("module data hasn't been loaded, retrying...")
            system.newTimer(rotate, 1000)  -- ewww
            return
        end
        local diff,map
        local mode = roundv.mode
        if roundv.custommap then
            diff = 0
            map = roundv.custommap[1]
            mode = roundv.custommap[2] or mode
        else
            repeat
                diff = math.random(roundv.diff1, roundv.diff2)
                map = mapcodes[roundv.mode][diff][ math.random(1,#mapcodes[roundv.mode][diff])]
            until not roundv.previousmap or tonumber(map) ~= roundv.previousmap
        end
        new_game_vars.mode = mode
        new_game_vars.difficulty = diff
        new_game_vars.mods = roundv.mods

        map_sched.load(map)
    end

    local function lobby()
        if roundv.lobby then  -- reloading lobby
            sWindow.close(WINDOW_LOBBY, nil)
        else
            for name in pL.shaman:pairs() do
                players[name].internal_score = 0
                tfm.exec.setPlayerScore(name, 0)
            end
        end

        local highest = {-1}
        local second_highest = nil
        for name in pL.room:pairs() do
            if not pL.spectator[name] then
                players[name].internal_score = players[name].internal_score + 1
                if players[name].internal_score >= highest[1] then
                    second_highest = highest[2]
                    highest[1] = players[name].internal_score
                    highest[2] = name
                end
            end
            print("[dbg] int score "..name..": "..players[name].internal_score)
        end

        if roundv.customshams then
            tfm.exec.setPlayerScore(roundv.customshams[1], 100)
            tfm.exec.setPlayerScore(roundv.customshams[2], 100)
        else
            tfm.exec.setPlayerScore(highest[2], 100)
            if players[highest[2]] and players[highest[2]].pair then
                tfm.exec.setPlayerScore(players[highest[2]].pair, 100)
            elseif second_highest then
                tfm.exec.setPlayerScore(second_highest, 100) -- TODO: prioritise the pre-defined pair or soulmate
            end
        end

        -- pass statistics and info on the previous round
        if roundv.running then
            new_game_vars.previous_round = {
                mapcode = roundv.mapinfo and roundv.mapinfo.code or nil,
                shamans = table_copy(roundv.shamans),
            }
        end
        new_game_vars.lobby = true
        new_game_vars.custommap = roundv.custommap
        map_sched.load(7740307)
    end
    
    local function diedwon(type, pn)
        local allplayerdead = true
        local allnonshamdead = true
        for name in pL.room:pairs() do
            if not pL.dead[name] then allplayerdead = false end
            if not pL.dead[name] and pL.non_shaman[name] then allnonshamdead = false end
        end
        if allplayerdead then
            lobby()
        elseif allnonshamdead then
            if type=='won' then tfm.exec.setGameTime(20) end
            if band(roundv.mapinfo.flags, MP_OPPORTUNIST) ~= 0 then
                for name in pL.shaman:pairs() do
                    tfm.exec.giveCheese(name)
                    tfm.exec.playerVictory(name)
                end
            end
        end
    end

    local function died(pn)
        if not roundv.running or pL.spectator[pn] then
            return
        elseif roundv.lobby then
            tfm.exec.respawnPlayer(pn)
            return
        end
        if pL.shaman[pn] then
            tfm.exec.setGameTime(20)
        end
        diedwon('died', pn)
    end

    local function won(pn)
        if not roundv.running or pL.spectator[pn] then
            return
        elseif roundv.lobby then
            tfm.exec.respawnPlayer(pn)
            return
        end
        diedwon('won', pn)
    end

    local function timesup()
        if not roundv.running then return end
        if roundv.lobby then
            sWindow.close(WINDOW_LOBBY, nil)
            rotate()
        else
            lobby()
        end
    end

    rotate_evt = {
        lobby = lobby,
        rotate = rotate,
        died = died,
        won = won,
        timesup = timesup
    }
end

do
    sWindow = {}
    local INDEPENDENT = 1  -- window is able to stay open regardless of other open windows
    local MUTUALLY_EXCLUSIVE = 2  -- window will close other mutually exclusive windows that are open

    local help_ta_range = {
        ['Welcome'] = {WINDOW_HELP+21, WINDOW_HELP+22},
        ['Rules'] = {WINDOW_HELP+31, WINDOW_HELP+32},
        ['Commands'] = {WINDOW_HELP+41, WINDOW_HELP+42},
        ['Contributors'] = {WINDOW_HELP+51, WINDOW_HELP+52},
    }
    -- WARNING: No error checking, ensure that all your windows have all the required attributes (open, close, type, players)
    local windows = {
        [WINDOW_GUI] = {
            open = function(pn, p_data, tab)
                local T = {{"event:help!Welcome","?"},{"event:options","O"},{"event:profile","P"}}
                local x, y = 800-(30*(#T+1)), 25
                for i,m in ipairs(T) do
                    ui.addTextArea(WINDOW_GUI+i,"<p align='center'><a href='"..m[1].."'>"..m[2], pn, x+(i*30), y, 20, 0, 1, 0, .7, true)
                end
            end,
            close = function(pn, p_data)
                for i = 1, 3 do
                    ui.removeTextArea(WINDOW_GUI+i, pn)
                end
            end,
            type = INDEPENDENT,
            players = {}
        },
        [WINDOW_HELP] = {
            open = function(pn, p_data, tab)
                local tabs = {
                    {'Welcome', 'help_tab_welcome'},
                    {'Rules', 'help_tab_rules'},
                    {'Commands', 'help_tab_commands'},
                    {'Contributors', 'help_tab_contributors'},
                    {'Close', 'close'}
                }
                local tabs_k = {['Welcome']=true,['Rules']=true,['Commands']=true,['Contributors']=true}
                tab = tab or 'Welcome'

                if not tabs_k[tab] then return end
                if not p_data.tab then
                    ui.addTextArea(WINDOW_HELP+1,"",pn,75,40,650,340,0x133337,0x133337,1,true)  -- the background
                else  -- already opened before
                    if help_ta_range[p_data.tab] then
                        for i = help_ta_range[p_data.tab][1], help_ta_range[p_data.tab][2] do
                            ui.removeTextArea(i, pn)
                        end
                    end
                    if p_data.images[p_data.tab] then
                        for i = 1, #p_data.images[p_data.tab] do
                            tfm.exec.removeImage(p_data.images[p_data.tab][i])
                        end
                        p_data.images[p_data.tab] = nil
                    end
                end
                for i, v in pairs(tabs) do
                    local iden, tl_key = v[1], v[2]
                    local translated = tl(tl_key, players[pn].lang)
                    local opacity = (iden == tab) and 0 or 1 
                    ui.addTextArea(WINDOW_HELP+1+i, GUI_BTN.."<font size='2'><br><font size='12'><p align='center'><a href='event:help!"..iden.."'>"..translated.."\n</a>",pn,92+((i-1)*130),50,100,24,0x666666,0x676767,opacity,true)
                end
                p_data.tab = tab

                if tab == "Welcome" then
                    local text = string.format(tl("help_content_welcome", players[pn].lang), GUI_BTN, LINK_DISCORD)
                    ui.addTextArea(WINDOW_HELP+21,text,pn,88,95,625,nil,0,0,0,true)
                elseif tab == "Rules" then
                    local text = tl("help_content_rules", players[pn].lang)
                    ui.addTextArea(WINDOW_HELP+31,text,pn,88,95,625,nil,0,0,0,true)
                elseif tab == "Commands" then
                    local text = tl("help_content_commands", players[pn].lang)
                    ui.addTextArea(WINDOW_HELP+41,text,pn,88,95,625,nil,0,0,0,true)
                elseif tab == "Contributors" then
                    local text = tl("help_content_contributors", players[pn].lang)
                    ui.addTextArea(WINDOW_HELP+51,text,pn,88,95,625,nil,0,0,0,true)
                    --local img_id = tfm.exec.addImage("172cde7e326.png", "&1", 571, 180, pn)
                    --p_data.images[tab] = {img_id}
                end
            end,
            close = function(pn, p_data)
                for i = 1, 10 do
                    ui.removeTextArea(WINDOW_HELP+i, pn)
                end
                if help_ta_range[p_data.tab] then
                    for i = help_ta_range[p_data.tab][1], help_ta_range[p_data.tab][2] do
                        ui.removeTextArea(i, pn)
                    end
                end
                if p_data.images[p_data.tab] then
                    for i = 1, #p_data.images[p_data.tab] do
                        tfm.exec.removeImage(p_data.images[p_data.tab][i])
                    end
                    p_data.images[p_data.tab] = nil
                end
                p_data.tab = nil
            end,
            type = MUTUALLY_EXCLUSIVE,
            players = {}
        },
        [WINDOW_LOBBY] = {
            open = function(pn, p_data)
                p_data.images = { main={}, mode={}, help={}, toggle={} }

                --ui.addTextArea(WINDOW_LOBBY+1,"",pn,75,40,650,340,1,0,.8,true)  -- the background
                local header = pL.shaman[pn] and "You’ve been chosen to pair up for the next round!" or "Every second, 320 baguettes are eaten in France!"
                ui.addTextArea(WINDOW_LOBBY+2,"<p align='center'><font size='13'>"..header,pn,75,50,650,nil,1,0,1,true)
                p_data.images.main[1] = {tfm.exec.addImage(IMG_LOBBY_BG, ":"..WINDOW_LOBBY, 70, 40, pn)}

                -- shaman cards
                --ui.addTextArea(WINDOW_LOBBY+3,"",pn,120,85,265,200,0xcdcdcd,0xbababa,.1,true)
                --ui.addTextArea(WINDOW_LOBBY+4,"",pn,415,85,265,200,0xcdcdcd,0xbababa,.1,true)
                ui.addTextArea(WINDOW_LOBBY+5,"<p align='center'><font size='13'><b>"..pDisp(roundv.shamans[1]),pn,118,90,269,nil,1,0,1,true)
                ui.addTextArea(WINDOW_LOBBY+6,"<p align='center'><font size='13'><b>"..pDisp(roundv.shamans[2]),pn,413,90,269,nil,1,0,1,true)

                -- mode
                p_data.images.mode[TSM_HARD] = {tfm.exec.addImage(roundv.mode == TSM_HARD and IMG_FEATHER_HARD or IMG_FEATHER_HARD_DISABLED, ":"..WINDOW_LOBBY, 202, 125, pn), 202, 125}
                p_data.images.mode[TSM_DIV] = {tfm.exec.addImage(roundv.mode == TSM_DIV and IMG_FEATHER_DIVINE or IMG_FEATHER_DIVINE_DISABLED, ":"..WINDOW_LOBBY, 272, 125, pn), 272, 125}

                ui.addTextArea(WINDOW_LOBBY+20, string.format("<a href='event:setmode!%s'><font size='35'>\n", TSM_HARD), pn, 202, 125, 35, 40, 1, 0, 0, true)
                ui.addTextArea(WINDOW_LOBBY+21, string.format("<a href='event:setmode!%s'><font size='35'>\n", TSM_DIV), pn, 272, 125, 35, 40, 1, 0, 0, true)

                -- difficulty
                ui.addTextArea(WINDOW_LOBBY+7,"<p align='center'><font size='13'><b>Difficulty",pn,120,184,265,nil,1,0,.2,true)
                ui.addTextArea(WINDOW_LOBBY+8,"<p align='center'><font size='13'>to",pn,240,240,30,nil,1,0,0,true)
                ui.addTextArea(WINDOW_LOBBY+9,"<p align='center'><font size='13'><b>"..roundv.diff1,pn,190,240,20,nil,1,0,.2,true)
                ui.addTextArea(WINDOW_LOBBY+10,"<p align='center'><font size='13'><b>"..roundv.diff2,pn,299,240,20,nil,1,0,.2,true)
                ui.addTextArea(WINDOW_LOBBY+11,GUI_BTN.."<p align='center'><font size='17'><b><a href='event:setdiff!1&1'>&#x25B2;</a><br><a href='event:setdiff!1&-1'>&#x25BC;",pn,132,224,20,nil,1,0,0,true)
                ui.addTextArea(WINDOW_LOBBY+12,GUI_BTN.."<p align='center'><font size='17'><b><a href='event:setdiff!2&1'>&#x25B2;</a><br><a href='event:setdiff!2&-1'>&#x25BC;",pn,350,224,20,nil,1,0,0,true)

                -- mods
                local mods_str = {}
                local mods_helplink_str = {}
                local i = 1
                for k, mod in pairs(mods) do
                    mods_str[#mods_str+1] = string.format("<a href='event:modtoggle!%s'>%s", k, mod[1])
                    local is_set = band(roundv.mods, k) ~= 0
                    local x, y = 640, 120+((i-1)*25)
                    p_data.images.toggle[k] = {tfm.exec.addImage(is_set and IMG_TOGGLE_ON or IMG_TOGGLE_OFF, ":"..WINDOW_LOBBY, x, y, pn), x, y}
                    --ui.addTextArea(WINDOW_LOBBY+80+i,string.format("<a href='event:modtoggle!%s'><font size='15'> <br>", k),pn,x-2,y+3,35,18,1,0xfffff,0,true)
                    
                    x = 425
                    y = 125+((i-1)*25)
                    p_data.images.help[k] = {tfm.exec.addImage(IMG_HELP, ":"..WINDOW_LOBBY, x, y, pn), x, y}
                    mods_helplink_str[#mods_helplink_str+1] = string.format("<a href='event:modhelp!%s'>", k)

                    i = i+1
                end
                ui.addTextArea(WINDOW_LOBBY+14, table.concat(mods_str, "\n\n").."\n", pn,450,125,223,nil,1,0,0,true)
                ui.addTextArea(WINDOW_LOBBY+15, "<font size='11'>"..table.concat(mods_helplink_str, "\n\n").."\n", pn,422,123,23,nil,1,0,0,true)

                -- help and xp multiplier text
                ui.addTextArea(WINDOW_LOBBY+16,"<p align='center'><i><J>",pn,120,300,560,nil,1,0,0,true)
                ui.addTextArea(WINDOW_LOBBY+17,"<p align='center'><font size='13'><N>Exp multiplier:<br><font size='15'>"..expDisp(GetExpMult()),pn,330,333,140,nil,1,0,0,true)

                -- ready
                ui.addTextArea(WINDOW_LOBBY+18, GUI_BTN.."<font size='2'><br><font size='12'><p align='center'><a href='event:setready'>".."&#9744; Ready".."</a>",pn,200,340,100,24,0x666666,0x676767,1,true)
                ui.addTextArea(WINDOW_LOBBY+19, GUI_BTN.."<font size='2'><br><font size='12'><p align='center'><a href='event:setready'>".."&#9744; Ready".."</a>",pn,500,340,100,24,0x666666,0x676767,1,true)
            end,
            close = function(pn, p_data)
                for i = 1, 21 do
                    ui.removeTextArea(WINDOW_LOBBY+i, pn)
                end
                for _, imgs in pairs(p_data.images) do
                    for k, img_dat in pairs(imgs) do
                        tfm.exec.removeImage(img_dat[1])
                    end
                end
                p_data.images = {}
            end,
            type = INDEPENDENT,
            players = {}
        },
        [WINDOW_OPTIONS] = {
            open = function(pn, p_data)
                p_data.images = { main={}, toggle={}, help={} }

                p_data.images.main[1] = {tfm.exec.addImage(IMG_OPTIONS_BG, ":"..WINDOW_OPTIONS, 520, 47, pn)}
                ui.addTextArea(WINDOW_OPTIONS+1, "<font size='3'><br><p align='center'><font size='13'><J><b>Settings", pn, 588,52, 102,30, 1, 0, 0, true)
                ui.addTextArea(WINDOW_OPTIONS+2, "<a href='event:options!close'><font size='30'>\n", pn, 716,48, 31,31, 1, 0, 0, true)

                local opts_str = {}
                local opts_helplink_str = {}
                local i = 1
                for k, opt in pairs(options) do
                    opts_str[#opts_str+1] = string.format("<a href='event:opttoggle!%s'>%s", k, opt[1])
                    local is_set = playerData[pn]:getToggle(k)
                    local x, y = 716, 100+((i-1)*25)
                    p_data.images.toggle[k] = {tfm.exec.addImage(is_set and IMG_TOGGLE_ON or IMG_TOGGLE_OFF, ":"..WINDOW_OPTIONS, x, y, pn), x, y}
                    
                    x = 540
                    y = 105+((i-1)*25)
                    p_data.images.help[k] = {tfm.exec.addImage(IMG_HELP, ":"..WINDOW_OPTIONS, x, y, pn), x, y}
                    opts_helplink_str[#opts_helplink_str+1] = string.format("<a href='event:opthelp!%s'>", k)

                    i = i+1
                end
                ui.addTextArea(WINDOW_OPTIONS+3, table.concat(opts_str, "\n\n").."\n", pn,560,105,223,nil,1,0,0,true)
                ui.addTextArea(WINDOW_OPTIONS+4, "<font size='11'>"..table.concat(opts_helplink_str, "\n\n").."\n", pn,540,103,23,nil,1,0,0,true)
            end,
            close = function(pn, p_data)
                for i = 1, 5 do
                    ui.removeTextArea(WINDOW_OPTIONS+i, pn)
                end
                for _, imgs in pairs(p_data.images) do
                    for k, img_dat in pairs(imgs) do
                        tfm.exec.removeImage(img_dat[1])
                    end
                end
                p_data.images = {}
            end,
            type = MUTUALLY_EXCLUSIVE,
            players = {}
        },
        [WINDOW_DB_MAP] = {
            open = function(pn, p_data)
                local tabs = {"Add", "Remove", "&#9587; Close"}
                local tabstr = "<p align='center'><V>"..string.rep("&#x2500;", 6).."<br>"
                local t_str = {"<p align='center'><font size='15'>Modify map</font><br>"}

                for i = 1, #tabs do
                    local t = tabs[i]
                    local col = GUI_BTN
                    tabstr = tabstr..string.format("%s<a href='event:dbmap!%s'>%s</a><br><V>%s<br>", col, t, t, string.rep("&#x2500;", 6))
                end

                t_str[#t_str+1] = "<ROSE>@"..roundv.mapinfo.code.."<br><V>"..string.rep("&#x2500;", 15).."</p><p align='left'><br>"
                

                ui.addTextArea(WINDOW_DB_MAP+1, tabstr, pn, 170, 60, 70, nil, 1, 0, .8, true)
	            ui.addTextArea(WINDOW_DB_MAP+2, table.concat(t_str), pn, 250, 50, 300, 300, 1, 0, .8, true)
            end,
            close = function(pn, p_data)
                for i = 1, 2 do
                    ui.removeTextArea(WINDOW_DB_MAP+i, pn)
                end
            end,
            type = INDEPENDENT,
            players = {}
        },
        [WINDOW_DB_HISTORY] = {
            open = function(pn, p_data)
                ui.addTextArea(WINDOW_DB_HISTORY+1,"",pn,75,40,650,340,0x133337,0x133337,1,true)  -- the background
            end,
            close = function(pn, p_data)
                for i = 1, 5 do
                    ui.removeTextArea(WINDOW_DB_HISTORY+i, pn)
                end
            end,
            type = INDEPENDENT,
            players = {}
        },
    }

    sWindow.open = function(window_id, pn, ...)
        if not windows[window_id] then
            return
        elseif not pn then
            for name in pairs(room.playerList) do
                sWindow.open(window_id, name, table.unpack(arg))
            end
            return
        elseif not windows[window_id].players[pn] then
            windows[window_id].players[pn] = {images={}}
        end
        if windows[window_id].type == MUTUALLY_EXCLUSIVE then
            for w_id, w in pairs(windows) do
                if w_id ~= window_id and w.type == MUTUALLY_EXCLUSIVE then
                    sWindow.close(w_id, pn)
                end
            end
        end
        windows[window_id].players[pn].is_open = true
        windows[window_id].open(pn, windows[window_id].players[pn], table.unpack(arg))
    end

    sWindow.close = function(window_id, pn)
        if not pn then
            for name in pairs(room.playerList) do
                sWindow.close(window_id, name)
            end
        elseif sWindow.isOpened(window_id, pn) then
            windows[window_id].close(pn, windows[window_id].players[pn])
            windows[window_id].players[pn].is_open = false
        end
    end

    -- Hook this on to eventPlayerLeft, where all of the player's windows would be closed
    sWindow.clearPlayer = function(pn)
        for w_id in pairs(windows) do
            windows[w_id].players[pn] = nil
        end
    end

    sWindow.isOpened = function(window_id, pn)
        return windows[window_id]
            and windows[window_id].players[pn]
            and windows[window_id].players[pn].is_open
    end

    sWindow.getImages = function(window_id, pn)
        if sWindow.isOpened(window_id, pn) then
            return windows[window_id].players[pn].images
        end
        return {}
    end 
end

keys = {
    [71] = {
        func = function(pn, enable) -- g (display GUI for shamans)
            if not roundv.lobby and pL.shaman[pn] then
                if enable then
                    sWindow.open(WINDOW_GUI, pn)
                else
                    sWindow.close(WINDOW_GUI, pn)
                end
            end
        end,
        trigger = DOWN_UP
    },
    [72] = {
        func = function(pn) -- h (display help)
            if sWindow.isOpened(WINDOW_HELP, pn) then
                sWindow.close(WINDOW_HELP, pn)
            else
                sWindow.open(WINDOW_HELP, pn)
            end
        end,
        trigger = DOWN_ONLY
    },
    [79] = {
        func = function(pn) -- o (display player options)
            if sWindow.isOpened(WINDOW_OPTIONS, pn) then
                sWindow.close(WINDOW_OPTIONS, pn)
            else
                sWindow.open(WINDOW_OPTIONS, pn)
            end
        end,
        trigger = DOWN_ONLY
    },
    [85] = {
        func = function(pn) -- u (undo spawn)
            if not pL.shaman[pn] or band(roundv.mods, MOD_BUTTER_FINGERS) == 0 then return end
            local sl = roundv.spawnlist[pn]
            if sl._len > 0 and roundv.undo_count < 2 then
                tfm.exec.removeObject(sl[sl._len])
                sl[sl._len] = nil
                sl._len = sl._len - 1
                roundv.undo_count = roundv.undo_count + 1
                tfm.exec.chatMessage(string.format("<ROSE>%s used an undo! (%s left)", pDisp(pn), 2 - roundv.undo_count))
            end
        end,
        trigger = DOWN_ONLY
    },
}

cmds = {
    a = {
        func = function(pn, m)
            local msg = m:match("^%a+%s+(.*)")
            if msg then
                tfm.exec.chatMessage(string.format("<ROSE><b>[#ShamTeam Mod]</b> %s", msg))
            else MSG('empty message', pn, 'R')
            end
        end,
        perms = GROUP_STAFF
    },
    exec = {
        func = function(pn, m, w1)
            local argv = string_split(m, '%s')
            local stem = tfm.exec
            if w1 == "ui" then
                stem = ui
            elseif w1 == "system" then
                stem = system
            end
            if argv[2] and stem[argv[2]]~=nil then
                local args = {_len=0}
                local buildstring = {false}
                for i = 3, #argv do
                    arg = argv[i]
                    if arg=='true' then
                        args[args._len+1]=true
                        args._len = args._len+1
                    elseif arg=='false' then
                        args[args._len+1]=false
                        args._len = args._len+1
                    elseif arg=='nil' then
                        args[args._len+1]=nil
                        args._len = args._len+1
                    elseif tonumber(arg) ~= nil then
                        args[args._len+1]=tonumber(arg)
                        args._len = args._len+1
                    elseif arg:find('{(.-)}') then
                        local params = {}
                        for _,p in pairs(string_split(arg:match('{(.-)}'), ',')) do
                            local prop = string_split(p, '=')
                            local attr,val=prop[1],prop[2]
                            if val=='true' then val=true
                            elseif val=='false' then val=false
                            elseif val=='nil' then val=nil
                            elseif tonumber(val) ~= nil then val=tonumber(val)
                            end
                            params[attr] = val
                        end
                        args[args._len+1] = params
                        args._len = args._len+1
                    elseif arg:find('^"(.*)"$') then
                        args[args._len+1] = arg:match('^"(.*)"$'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                        args._len = args._len+1
                    elseif arg:find('^"(.*)') then
                        buildstring[1] = true
                        buildstring[2] = arg:match('^"(.*)'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    elseif arg:find('(.*)"$') then
                        buildstring[1] = false
                        args[args._len+1] = buildstring[2] .. " " .. arg:match('(.*)"$'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                        args._len = args._len+1
                    elseif buildstring[1] then
                        buildstring[2] = buildstring[2] .. " " .. arg:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    else
                        args[args._len+1] = arg
                        args._len = args._len+1
                    end
                end
                stem[argv[2]](table.unpack(args, 1, args._len))
            else
                tfm.exec.chatMessage('<R>no such exec '..(argv[2] and argv[2] or 'nil'), pn)
            end
        end,
        perms = GROUP_DEV
    },
    skip = {
        func = function(pn)
            if pL.shaman[pn] or players[pn].group >= GROUP_STAFF then  -- TODO: both shams must vote!
                rotate_evt.timesup()
            end
        end,
        perms = GROUP_PLAYER
    },
    npp = {
        func = function(pn, m, w1, w2, w3)
            local modes = {['thm']=TSM_HARD, ['tdm']=TSM_DIV}
            if w3 and not modes[w3] then
                tfm.exec.chatMessage("<R>error: invalid mode (thm,tdm)", pn)
                return
            end
            roundv.custommap = {w2, modes[w3]}
            tfm.exec.chatMessage("Map "..w2.." will be loaded the next round.", pn)
        end,
        perms = GROUP_STAFF
    },
    ch = {
        func = function(pn, m, w1, w2, w3)
            local s1, s2 = pFind(w2, pn), pFind(w3, pn)
            if not s1 or not s2 then return end
            roundv.customshams = {s1, s2}
            tfm.exec.chatMessage(s1.." & "..s2.." will be the shamans the next round.", pn)
            if roundv.lobby then
                rotate_evt.lobby()  -- reload the lobby
            end
        end,
        perms = GROUP_STAFF
    },
    score = {
        func = function(pn, m, w1, w2, w3)
            local num = tonumber(w2) or tonumber(w3) or 0
            local target = pFind(w1) or pFind(w2) or pn
            if num<0 or num>999 then tfm.exex.chatMessage("<R>error: score (0-999)",pn)
            elseif w2=='all' or w3=='all' then
                for name in pairs(room.playerList) do tfm.exec.setPlayerScore(name, num) end
            elseif w2 =='me' or w3=='me' then
                tfm.exec.setPlayerScore(pn, num) 
            else
                tfm.exec.setPlayerScore(pFind(target), num) 
            end
        end,
        perms = GROUP_STAFF
    },
    pos = {
        func = function(pn)
            players[pn].pos = not players[pn].pos
        end,
        perms = GROUP_STAFF
    },
    pair = {
        func = function(pn, m, w1, w2, w3)
            if players[pn].request_to then
                tfm.exec.chatMessage("<R>You may not have more than one pending request!", pn)
                return
            end
            if w2 then
                local target = pFind(w2)
                if not target then return end
                if players[pn].pair then
                    tfm.exec.chatMessage("<R>You may not request to pair until you have unpaired your current partner by typing !cancel", pn)
                    return
                end
                if not players[target].request_from and not players[target].pair then  -- TODO: and player is not already paired up
                    tfm.exec.chatMessage("Your request to pair up has been sent to "..target, pn)
                    tfm.exec.chatMessage(pn.." is requesting to pair up with you. Type !accept or !reject to respond.", target)
                    players[pn].request_to = target
                    players[target].request_from = pn
                else
                    tfm.exec.chatMessage("<R>You may not request to pair with this player at the moment.", pn)
                end
            end
        end,
        perms = GROUP_PLAYER
    },
    accept = {
        func = function(pn, m, w1, w2)
            if players[pn].request_from then
                local target = players[pn].request_from
                if players[target].pair then
                    players[target].request_to = nil
                    tfm.exec.chatMessage("<R>You may not pair with this player at the moment.", pn)
                    return
                end
                tfm.exec.chatMessage("You are now paired with "..target, pn)
                tfm.exec.chatMessage("You are now paired with "..pn, target)
                players[pn].request_from = nil
                players[target].request_to = nil
                players[pn].pair = target
                players[target].pair = pn
            end
        end,
        perms = GROUP_PLAYER
    },
    reject = {
        func = function(pn, m, w1, w2)
            local target = players[pn].request_from
            if target then
                players[target].request_to = nil
                players[pn].request_from = nil
                tfm.exec.chatMessage("Rejected "..target.."'s request.", pn)
                tfm.exec.chatMessage(pn.." rejected your request.", target)
            end
        end,
        perms = GROUP_PLAYER
    },
    cancel = {
        func = function(pn, m, w1, w2)
            if players[pn].pair then
                local target = players[pn].pair
                tfm.exec.chatMessage("You are no longer paired.", pn)
                tfm.exec.chatMessage(pn.." no longer wants to pair with you.", target)
                players[target].pair = nil
                players[pn].pair = nil
            else
                local target = players[pn].request_to
                if target then
                    players[target].request_from = nil
                    players[pn].request_to = nil
                    tfm.exec.chatMessage("Cancelled request.", pn)
                    tfm.exec.chatMessage(pn.." has cancelled the request.", target)
                end
            end
        end,
        perms = GROUP_PLAYER
    },
    mort = {
        func = function(pn)
            if not roundv.lobby then
                tfm.exec.killPlayer(pn)
            end
        end,
        perms = GROUP_PLAYER
    },
    staff = {
        func = function(pn)
            tfm.exec.chatMessage(
[[<J>List of mapcrew staff:<N>
- Casserole#1798
- Emeryaurora#0000
- Pegasusflyer#0000
- Rini#5475
- Rayallan#0000
- Shibbbbbyy#1143

<J>Module developers:<N>
- Casserole#1798
- Emeryaurora#0000]], pn)
        end
    },
    help = {
        func = function(pn)
            sWindow.open(WINDOW_HELP, pn)
        end
    },
    spectate = {
        func = function(pn, m, w1, w2)
            local target, other = pn
            if w2 and players[pn].group >= GROUP_STAFF then  -- target others
                target = pFind(w2, pn)
                other = true
            end
            if target then
                if w1 == "unafk" then
                    if other and pL.spectator[target] then
                        SetSpectate(target, false)
                    end
                elseif not pL.spectator[target] and not pL.shaman[target] then
                    SetSpectate(target, true)
                    if other then
                        tfm.exec.chatMessage(string.format("<J>Ξ %s has been marked afk!", target))
                    end
                end
            end
        end,
        perms = GROUP_PLAYER
    },
    window = {
        func = function(pn, m, w1, w2)
            local w_id = tonumber(w2)
            if sWindow.isOpened(w_id, pn) then
                sWindow.close(w_id, pn)
            else
                sWindow.open(w_id, pn)
            end
        end,
        perms = GROUP_DEV
    },
    roomlimit = {
        func = function(pn, m, w1, w2)
            local limit = tonumber(w2)
            if not w2 then
                tfm.exec.setRoomMaxPlayers(DEFAULT_MAX_PLAYERS)
                tfm.exec.chatMessage("Room limit reset.", pn)
            elseif limit then
                tfm.exec.setRoomMaxPlayers(limit)
                tfm.exec.chatMessage("Room limit set to "..limit..".", pn)
            else
                tfm.exec.chatMessage("<R>error: number", pn)
            end
        end,
        perms = GROUP_STAFF
    },
    time = {
        func = function(pn, m, w1, w2)
            local limit = tonumber(w2)
            tfm.exec.setGameTime(limit)
        end,
        perms = GROUP_STAFF
    },
    db = {
        func = function(pn, m, w1, w2, w3, w4)
            if not MDHelper.getMdLoaded() then
                tfm.exec.chatMessage("Module data not loaded yet, please try again.", pn)
                return
            end
            local subcommands = {
                map = function(action, p1)
                    local actions = {
                        info = function()
                            local map = MDHelper.getMapInfo(roundv.mapinfo.code)
                            if not map then
                                tfm.exec.chatMessage("<R>This map is not in rotation.", pn)
                                return
                            end
                            local info = string.format("Mapcode: @%s\nHard Difficulty: %s\nDivine Difficulty: %s\nCompletion: %s / %s",
                                    map.code, map.hard_diff, map.div_diff, map.completed, map.rounds)
                            tfm.exec.chatMessage(info, pn)
                        end,
                        hard = function()
                            local map = MDHelper.getMapInfo(roundv.mapinfo.code)
                            if not map then
                                tfm.exec.chatMessage("<R>This map is not in rotation.", pn)
                                return
                            end
                            local diff = tonumber(p1)
                            if not diff then
                                tfm.exec.chatMessage("<R>Specify a valid difficulty number.", pn)
                                return
                            end
                            MDHelper.commit(pn, MDHelper.OP_UPDATE_MAP_HARD, map.code, diff)
                            tfm.exec.chatMessage("Changing Hard difficulty of @"..map.code.." to "..p1, pn)
                        end,
                        div = function()
                            local map = MDHelper.getMapInfo(roundv.mapinfo.code)
                            if not map then
                                tfm.exec.chatMessage("<R>This map is not in rotation.", pn)
                                return
                            end
                            local diff = tonumber(p1)
                            if not diff then
                                tfm.exec.chatMessage("<R>Specify a valid difficulty number.", pn)
                                return
                            end
                            MDHelper.commit(pn, MDHelper.OP_UPDATE_MAP_DIV, map.code, diff)
                            tfm.exec.chatMessage("Changing Divine difficulty of @"..map.code.." to "..p1, pn)
                        end,
                        add = function()
                            local map = MDHelper.getMapInfo(roundv.mapinfo.code)
                            if map then
                                tfm.exec.chatMessage("<R>This map is already in rotation.", pn)
                                return
                            end
                            MDHelper.commit(pn, MDHelper.OP_ADD_MAP, map.code)
                            tfm.exec.chatMessage("Adding @"..map.code, pn)
                        end,
                        remove = function()
                            local map = MDHelper.getMapInfo(roundv.mapinfo.code)
                            if not map then
                                tfm.exec.chatMessage("<R>This map is not in rotation.", pn)
                                return
                            end
                            MDHelper.commit(pn, MDHelper.OP_REMOVE_MAP, map.code)
                            tfm.exec.chatMessage("Removing @"..map.code, pn)
                        end,
                    }
                    if actions[action] then
                        actions[action]()
                    else
                        local a = {}
                        for sb in pairs(actions) do
                            a[#a+1] = sb
                        end
                        tfm.exec.chatMessage("Usage: !db map [ "..table.concat(a, " | ").." ]", pn)
                    end
                    -- TODO: Map settings UI?
                    --[[if not roundv.lobby then
                        sWindow.open(WINDOW_DB_MAP, pn)
                    else
                        tfm.exec.chatMessage("<R>Unable to open map settings for the lobby.", pn)
                    end]]
                end,
                history = function()
                    local logs = MDHelper.getTable("module_log")
                    tfm.exec.chatMessage("Change logs:", pn)
                    for i = 1, #logs do
                        local log = logs[i]
                        local log_str = MDHelper.getChangelog(log.op) or ""
                        tfm.exec.chatMessage(string.format("<ROSE>\t- %s\t%s\t%s", log.committer, os.date("%d/%m/%y %X", log.time*1000), log_str), pn)
                    end
                    --sWindow.open(WINDOW_DB_HISTORY, pn)
                end,
            }
            if subcommands[w2] then
                subcommands[w2](w3, w4)
            else
                local s = {}
                for sb in pairs(subcommands) do
                    s[#s+1] = sb
                end
                tfm.exec.chatMessage("Usage: !db [ "..table.concat(s, " | ").." ]", pn)
            end
        end,
        perms = GROUP_STAFF
    },
}

cmds_alias = {
    m = "mort",
    afk = "spectate",
    unafk = "spectate",
    ui = "exec",
    system = "exec",
    lock = "roomlimit",
}

-- WARNING: It is possible for players to alter callback strings, ensure
-- that callbacks are designed to protect against bad inputs!
callbacks = {
    help = function(pn, tab)
        if tab == 'Close' then
            sWindow.close(WINDOW_HELP, pn)
        else
            sWindow.open(WINDOW_HELP, pn, tab)
        end
    end,
    options = function(pn, action)
        if action == 'close' then
            sWindow.close(WINDOW_OPTIONS, pn)
        elseif not sWindow.isOpened(WINDOW_OPTIONS, pn) then
            sWindow.open(WINDOW_OPTIONS, pn)
        end
    end,
    unafk = function(pn)
        SetSpectate(pn, false)
        tfm.exec.chatMessage(tl("unafk_message", players[pn].lang), pn)
    end,
    link = function(pn, link_id)
        -- Do not print out raw text from players! Use predefined IDs instead.
        link_id = tonumber(link_id)
        local links = {
            [LINK_DISCORD] = "https://discord.gg/YkzM4rh",
        }
        if links[link_id] then
            tfm.exec.chatMessage(links[link_id], pn)
        end
    end,
    setmode = function(pn, mode_id)
        mode_id = tonumber(mode_id) or -1
        if not roundv.running or not roundv.lobby or (mode_id ~= TSM_HARD and mode_id ~= TSM_DIV)
                or pn ~= roundv.shamans[1] then -- only shaman #1 gets to set mode
            return
        end
        roundv.mode = mode_id

        for name in pL.room:pairs() do
            local imgs = sWindow.getImages(WINDOW_LOBBY, name)
            local img_dats = imgs.mode
            if img_dats and img_dats[mode_id] then
                tfm.exec.removeImage(img_dats[TSM_HARD][1])
                tfm.exec.removeImage(img_dats[TSM_DIV][1])
                if mode_id == TSM_HARD then
                    img_dats[TSM_HARD][1] = tfm.exec.addImage(IMG_FEATHER_HARD, ":"..WINDOW_LOBBY, img_dats[TSM_HARD][2], img_dats[TSM_HARD][3], name)
                    img_dats[TSM_DIV][1] = tfm.exec.addImage(IMG_FEATHER_DIVINE_DISABLED, ":"..WINDOW_LOBBY, img_dats[TSM_DIV][2], img_dats[TSM_DIV][3], name)
                else
                    img_dats[TSM_HARD][1] = tfm.exec.addImage(IMG_FEATHER_HARD_DISABLED, ":"..WINDOW_LOBBY, img_dats[TSM_HARD][2], img_dats[TSM_HARD][3], name)
                    img_dats[TSM_DIV][1] = tfm.exec.addImage(IMG_FEATHER_DIVINE, ":"..WINDOW_LOBBY, img_dats[TSM_DIV][2], img_dats[TSM_DIV][3], name)
                end
            end
        end
    end,
    setdiff = function(pn, id, add)
        id = tonumber(id) or 0
        add = tonumber(add) or 0
        if not roundv.running or not roundv.lobby 
                or pn ~= roundv.shamans[1] -- only shaman #1 gets to choose difficulty
                or (id ~= 1 and id ~= 2)
                or (add ~= -1 and add ~= 1) then
            return
        end
        local diff_id = "diff"..id
        local new_diff = roundv[diff_id] + add

        if new_diff < 1 or new_diff > #mapcodes[roundv.mode]
                or (id == 1 and roundv.diff2 - new_diff < 1)
                or (id == 2 and new_diff - roundv.diff1 < 1) then  -- range error
            tfm.exec.chatMessage(string.format("<R>error: range must have a value of 1-%s and have a difference of at least 1", #mapcodes[roundv.mode]), pn)
            return
        end

        roundv[diff_id] = new_diff
        ui.updateTextArea(WINDOW_LOBBY+9,"<p align='center'><font size='13'><b>"..roundv.diff1)
        ui.updateTextArea(WINDOW_LOBBY+10,"<p align='center'><font size='13'><b>"..roundv.diff2)
    end,
    setready = function(pn)
        if not roundv.running or not roundv.lobby then return end
        if roundv.shamans[1] == pn then
            local is_ready = not roundv.shaman_ready[1]
            roundv.shaman_ready[1] = is_ready

            local blt = is_ready and "&#9745;" or "&#9744;";
            ui.updateTextArea(WINDOW_LOBBY+18, GUI_BTN.."<font size='2'><br><font size='12'><p align='center'><a href='event:setready'>"..blt.." Ready".."</a>")
        elseif roundv.shamans[2] == pn then
            local is_ready = not roundv.shaman_ready[2]
            roundv.shaman_ready[2] = is_ready

            local blt = is_ready and "&#9745;" or "&#9744;";
            ui.updateTextArea(WINDOW_LOBBY+19, GUI_BTN.."<font size='2'><br><font size='12'><p align='center'><a href='event:setready'>"..blt.." Ready".."</a>")
        end
        if roundv.shaman_ready[1] and roundv.shaman_ready[2] then
            rotate_evt.timesup()
        end
    end,
    modtoggle = function(pn, mod_id)
        mod_id = tonumber(mod_id)
        if not roundv.running or not roundv.lobby or not mod_id or not mods[mod_id]
                or pn ~= roundv.shamans[2] then -- only shaman #2 gets to choose mods
            return
        end
        roundv.mods = bxor(roundv.mods, mod_id)  -- flip and toggle the flag
        local is_set = band(roundv.mods, mod_id) ~= 0
        for name in pL.room:pairs() do
            local imgs = sWindow.getImages(WINDOW_LOBBY, name)
            local img_dats = imgs.toggle
            if img_dats and img_dats[mod_id] then
                tfm.exec.removeImage(img_dats[mod_id][1])
                img_dats[mod_id][1] = tfm.exec.addImage(is_set and IMG_TOGGLE_ON or IMG_TOGGLE_OFF, ":"..WINDOW_LOBBY, img_dats[mod_id][2], img_dats[mod_id][3], name)
            end
        end
        ui.updateTextArea(WINDOW_LOBBY+17,"<p align='center'><font size='13'><N>Exp multiplier:<br><font size='15'>"..expDisp(GetExpMult()))
    end,
    modhelp = function(pn, mod_id)
        mod_id = tonumber(mod_id) or -1
        local mod = mods[mod_id]
        if mod then
            ui.updateTextArea(WINDOW_LOBBY+16, string.format("<p align='center'><i><J>%s: %s %s of original exp.", mod[1], mod[3], expDisp(mod[2], false)),pn)
        end
    end,
    opttoggle = function(pn, opt_id)
        opt_id = tonumber(opt_id)
        if not opt_id or not options[opt_id] or not roundv.running then
            return
        end
        playerData[pn]:flipToggle(opt_id)  -- flip and toggle the flag
        
        local is_set = playerData[pn]:getToggle(opt_id)

        local imgs = sWindow.getImages(WINDOW_OPTIONS, pn)
        local img_dats = imgs.toggle
        if img_dats and img_dats[opt_id] then
            tfm.exec.removeImage(img_dats[opt_id][1])
            img_dats[opt_id][1] = tfm.exec.addImage(is_set and IMG_TOGGLE_ON or IMG_TOGGLE_OFF, ":"..WINDOW_OPTIONS, img_dats[opt_id][2], img_dats[opt_id][3], pn)
        end

        -- hide/show GUI on toggle
        if opt_id == OPT_GUI then
            if not pL.shaman[pn] or roundv.lobby then
                if is_set then
                    sWindow.open(WINDOW_GUI, pn)
                else
                    sWindow.close(WINDOW_GUI, pn)
                end
            end
        end

        if opt_id == OPT_CIRCLE then
            if pn == roundv.shamans[roundv.shaman_turn==1 and 2 or 1] then
                UpdateCircle()
            end
        end

        -- Schedule saving
        playerData[pn]:scheduleSave()
    end,
    opthelp = function(pn, opt_id)
        opt_id = tonumber(opt_id) or -1
        local opt = options[opt_id]
        if opt then
            tfm.exec.chatMessage("<J>"..opt[1]..": "..opt[2], pn)
        end
    end,
    dbmap = function(pn, action)
        if players[pn].group < GROUP_STAFF then return end
        if action == "Close" then
            sWindow.close(WINDOW_DB_MAP, pn)
        end
    end,
    dbhist = function(pn, action)
        if players[pn].group < GROUP_STAFF then return end
        if action == "close" then
            sWindow.close(WINDOW_DB_HISTORY, pn)
        end
    end,
}

GetExpMult = function()
    local ret = 0
    for k, mod in pairs(mods) do
        if band(roundv.mods, k) ~= 0 then
            ret = ret + mod[2]
        end
    end
    if ret > 0.7 then
        ret = 0.7
    elseif ret < -0.7 then
        ret = -0.7
    end
    return ret
end

SetSpectate = function(pn, b)
    if b and not pL.spectator[pn] then
        pL.spectator:add(pn)
        players[pn].internal_score = -1
        tfm.exec.killPlayer(pn)
        tfm.exec.setPlayerScore(pn, -5)
        ui.addTextArea(TA_SPECTATING, GUI_BTN.."<font size='14'><p align='center'><a href='event:unafk'>You have entered spectator mode.\nClick here to exit spectator mode.", pn, 190, 355, 420, nil, 1, 0, .7, true)
    elseif pL.spectator[pn] then
        pL.spectator[pn]:remove(pn)
        players[pn].internal_score = 0
        tfm.exec.setPlayerScore(pn, 0)
        ui.removeTextArea(TA_SPECTATING, pn)
    end
end

local ShowMapInfo = function(pn)
    local mp = roundv.mapinfo
    local has_portals = band(mp.flags, MP_PORTALS) ~= 0
    local strT = {
        string.format("<ROSE>[Map Info]<J> @%s <N>by <VP>%s%s", mp.code, mp.original_author or mp.author, mp.mirrored and ' (mirrored)' or ''),
        string.format("<VP>Wind: <J>%s <VP>| Gravity: <J>%s <VP>| MGOC: <J>%s",mp.Wind or '0',mp.Gravity or '10', mp.MGOC or '100', has_portals and '<VP>' or '<R>')
    }

    local tags_tbl = {
        {MP_PORTALS, "Portals"},
        {MP_NOBALLOON, "No Balloon"},
        {MP_OPPORTUNIST, "Opportunist"}
    }
    local tags = { _len = 0 }
    for i = 1, #tags_tbl do
        local t = tags_tbl[i]
        if band(mp.flags, t[1]) ~= 0 then
            tags[tags._len+1] = t[2]
            tags._len = tags._len+1
        end
    end
    if tags._len > 0 then
        strT[#strT+1] = "<ROSE>Tags: <N>"..table.concat(tags, ", ")
    end
    
    local m = { _len = 0 }
    for k, mod in pairs(mods) do
        if band(roundv.mods, k) ~= 0 then
            m[m._len+1] = mod[1]
            m._len = m._len+1
        end
    end
    if m._len > 0 then
        strT[#strT+1] = "<ROSE>Mods: <N>"..table.concat(m, ", ")
    end

    tfm.exec.chatMessage("<N>"..table.concat(strT, "\n"), pn)
end

local ReadXML = function()
    local xml = room.xmlMapInfo.xml
    if not xml then
        return
    end
    local mp = roundv.mapinfo
    mp.flags = 0
    for attr, val in xml:match('<P .->'):gmatch('([^%s]-)="(.-)"') do
        local a = string.upper(attr)
        if a == 'P' then
            mp.flags = bor(mp.flags, MP_PORTALS)
        elseif a == 'G' then
            local wg = string_split(val or "")
            mp.Wind, mp.Gravity = tonumber(wg[1]), tonumber(wg[2])
        elseif a == 'MGOC' then
            mp.MGOC = tonumber(val)
        elseif a == 'NOBALLOON' then
            mp.flags = bor(mp.flags, MP_NOBALLOON)
        elseif a == 'OPPORTUNIST' then
            mp.flags = bor(mp.flags, MP_OPPORTUNIST)
        elseif a == 'SEPARATESHAM' then
            mp.flags = bor(mp.flags, MP_SEPARATESHAM)
        elseif a == 'ORIGINALAUTHOR' then
            mp.original_author = val
        end
    end
    local dc = xml:match('<DC (.-)>')
    if dc then
        mp.DC = {}
        mp.DC[1] = { tonumber(dc:match('X="(%d-)"')) or 0, tonumber(dc:match('Y="(%d-)"')) or 0 }
        local dc2 = xml:match('<DC2 (.-)>')
        if dc2 then
            mp.DC[2] = { tonumber(dc2:match('X="(%d-)"')) or 0, tonumber(dc2:match('Y="(%d-)"')) or 0 }
        end
    end
end

local UpdateTurnUI = function()
    local color = "CH"
    local shaman = roundv.shamans[roundv.shaman_turn]
    ui.setShamanName(string.format("<%s>%s's <J>Turn", color, pDisp(shaman)))
end

UpdateCircle = function()
    if roundv.mode == TSM_HARD then
        local display_to = roundv.shamans[roundv.shaman_turn == 1 and 2 or 1]
        local display_for = roundv.shamans[roundv.shaman_turn]
        if not display_to then return end
        
        if roundv.circle then
            tfm.exec.removeImage(roundv.circle)
        end
        if playerData[display_to]:getToggle(OPT_CIRCLE) then
            roundv.circle = tfm.exec.addImage(IMG_RANGE_CIRCLE, "$"..display_for, -120, -120, display_to)
        else
            tfm.exec.removeImage(roundv.circle)
            roundv.circle = nil
        end
    end
end

local UpdateMapCodes = function()
    local maps = MDHelper.getTable("maps")
    mapcodes = {[TSM_HARD]={}, [TSM_DIV]={}}
    local hardcodes, divcodes = mapcodes[TSM_HARD], mapcodes[TSM_DIV]
    for i = 1, #maps do
        local map = maps[i]
        if map.hard_diff > 0 then
            if not hardcodes[map.hard_diff] then hardcodes[map.hard_diff] = {} end
            local cat = hardcodes[map.hard_diff]
            cat[#cat+1] = map.code
        end
        if map.div_diff > 0 then
            if not divcodes[map.div_diff] then divcodes[map.div_diff] = {} end
            local cat = divcodes[map.div_diff]
            cat[#cat+1] = map.code
        end
    end
end

----- EVENTS
function eventChatCommand(pn, msg)
    local words = string_split(string.lower(msg), "%s")
    local cmd = cmds_alias[words[1]] or words[1]
    if cmds[cmd] then
        if not cmds[cmd].perms or players[pn].group >= cmds[cmd].perms then
            cmds[cmd].func(pn, msg, table.unpack(words))
        else
            tfm.exec.chatMessage('<R>error: no authority', pn)
        end
    else
       tfm.exec.chatMessage('<R>error: invalid command', pn)
    end
    
end

function eventFileLoaded(file, data)
    local success, result = pcall(MDHelper.parse, file, data)
    if not success then
        print(string.format("Exception encountered in eventFileLoaded: %s", result))
    end
end

-- Called from MDHelper when parsing is done
function eventFileParsed()
    UpdateMapCodes()
end

function eventFileSaved(file)
    MDHelper.onSaved(file)
end

function eventPlayerDataLoaded(pn, data)
    local pd = playerData[pn]
    if #data > 0 then
        local success, result = pcall(pd.load, pd, data)
        if not success then
            print(string.format("Exception encountered in eventPlayerDataLoaded: %s", result))
        else
            pd_loaded[pn] = true
        end
    end
    local success, result = pcall(pd.save, pd, pn)  -- TODO: to remove, for testing only
    if not success then
        print(string.format("Exception encountered in eventPlayerDataLoaded: %s", result))
    end
end

function eventKeyboard(pn, k, d, x, y)
    if keys[k] then
        keys[k].func(pn, d, x, y)
    end
end

function eventLoop(elapsed, remaining)
    map_sched.run()
    PDHelper.checkSaves()
    MDHelper.trySync()
    if not roundv.running then return end
    if roundv.phase < 3 and remaining <= 0 then
        rotate_evt.timesup()
        roundv.phase = 3
    elseif roundv.lobby then
        ui.setMapName(string.format("<N>Next Shamans: <CH>%s <N>- <CH2>%s  <G>|  <N>Game starts in: <V>%s  <G>|  <N>Mice: <V>%s<", pDisp(roundv.shamans[1]), pDisp(roundv.shamans[2]) or '', math_round(remaining/1000), pL.room:len()))
    end
end

function eventMouse(pn, x, y)
    if not players[pn] then
        return
    end
    if players[pn].pos then  -- Debugging function
        tfm.exec.chatMessage("<J>X: "..x.."  Y: "..y, pn)
    end
end

function eventNewGame()
    print('ev newGame '..(new_game_vars.lobby and "is lobby" or "not lobby"))  -- temporary for debug b/4: init race condition
    local mapcode = tonumber(room.currentMap:match('%d+'))
    local diff = new_game_vars.difficulty or 0
    if (not module_started and mapcode ~= 7740307) then  -- workaround for b/4: init race condition
        roundv = { running = false }
        return
    end
    -- Bail out if the map is vanilla or a map in rotation that is NOT dual shaman
    if mapcode < 1000 or (diff ~= 0 and not roundv.lobby and (room.xmlMapInfo.mapCode ~= 8 and room.xmlMapInfo.mapCode ~= 32)) then
        roundv = { running = false }
        tfm.exec.chatMessage("<R>Ξ Faulty map! Please help report this map: @"..mapcode)
        tfm.exec.setGameTime(3)
        rotate_evt.lobby()
        return
    end
    if not module_started then module_started = true end
    roundv = {
        mapinfo = {
            Wind = 0,
            Gravity = 10,
            MGOC = 100,
            mirrored = room.mirroredMap,
            author = room.xmlMapInfo.author,
            code = mapcode
        },
        shamans = {},
        shaman_turn = 1,
        undo_count = 0,
        sballoon_count = 0,
        spawnlist = {},
        difficulty = diff,
        phase = 0,
        lobby = new_game_vars.lobby,
        start_epoch = os.time(),
        mode = new_game_vars.mode or TSM_DIV,
        mods = new_game_vars.mods or 0,
    }

    pL.dead = PairTable:new()
    pL.alive = PairTable:new(room)
    pL.shaman = PairTable:new()
    pL.non_shaman = PairTable:new()

    for name, p in pairs(room.playerList) do
        if p.isShaman then
            roundv.shamans[#roundv.shamans+1] = name
            pL.shaman:add(name)
        else
            pL.non_shaman:add(name)
        end
    end
    assert(#roundv.shamans <= 2, "Shaman count is greater than 2: "..#roundv.shamans)

    for name in pL.spectator:pairs() do
        tfm.exec.killPlayer(name)
        tfm.exec.setPlayerScore(name, -5)
    end

    if roundv.lobby then
        roundv.diff1 = 1
        roundv.diff2 = 5
        roundv.shaman_ready = {}
        if new_game_vars.previous_round then
            -- show back the GUI for the previous round of shamans
            for i = 1, #new_game_vars.previous_round.shamans do
                local name = new_game_vars.previous_round.shamans[i]
                if playerData[name]:getToggle(OPT_GUI) then
                    sWindow.open(WINDOW_GUI, name)
                end
            end
            roundv.custommap = new_game_vars.custommap
            roundv.previousmap = new_game_vars.previous_round.mapcode
        end
        sWindow.open(WINDOW_LOBBY, nil)
        tfm.exec.setGameTime(30)
        if #roundv.shamans == 2 then
            tfm.exec.chatMessage(string.format("<ROSE>Ξ <CH>%s <ROSE>& <CH2>%s <ROSE>are the next shaman pair!", pDisp(roundv.shamans[1]), pDisp(roundv.shamans[2])))
        else
            tfm.exec.chatMessage("<R>Ξ No shaman pair!")
        end
        tfm.exec.disableAfkDeath(true)
        tfm.exec.disableMortCommand(true)
        tfm.exec.disablePrespawnPreview(false)
    else
        ReadXML()

        for i = 1, #roundv.shamans do
            local name = roundv.shamans[i]

            roundv.spawnlist[name] = { _len = 0 }

            -- hide the GUI for shamans
            sWindow.close(WINDOW_GUI, name)
            
            -- Force the mode; this also teleports both shamans to the blue's spawnpoint
            tfm.exec.setShamanMode(name, roundv.mode == TSM_HARD and 1 or 2)

            if band(roundv.mapinfo.flags, MP_SEPARATESHAM) ~= 0 then
                local dc = roundv.mapinfo.DC[i]
                if dc then
                    tfm.exec.movePlayer(name, dc[1], dc[2])
                end
            end
        end

        ShowMapInfo()
        if #roundv.shamans == 2 then
            tfm.exec.chatMessage(string.format("<ROSE>Ξ <CH>%s <ROSE>& <CH2>%s <ROSE>are now the shaman pair!", pDisp(roundv.shamans[1]), pDisp(roundv.shamans[2])))
        else
            tfm.exec.chatMessage("<R>Ξ No shaman pair!")
        end
        UpdateTurnUI()
        UpdateCircle()

        local t_mode = {
            [TSM_HARD]={"J", "THM"},
            [TSM_DIV]={"VI", "TDM"}
        }
        local mode_disp = t_mode[roundv.mode]
        assert(mode_disp ~= nil, "Invalid TSM mode!!")
        ui.setMapName(string.format("<%s>[%s] <ROSE>Difficulty %s - <VP>@%s", mode_disp[1], mode_disp[2], roundv.difficulty, roundv.mapinfo.code))
        
        tfm.exec.disableAfkDeath(false)
        tfm.exec.disableMortCommand(false)
        tfm.exec.disablePrespawnPreview(band(roundv.mods, MOD_TELEPATHY) ~= 0)

        local time_limit = roundv.mode == TSM_HARD and 200 or 180
        if band(roundv.mods, MOD_WORK_FAST) ~= 0 then
            time_limit = time_limit - 60
        end
        if band(roundv.mods, MOD_SNAIL_NAIL) ~= 0 then
            time_limit = time_limit + 30
        end
        tfm.exec.setGameTime(time_limit)
    end
    new_game_vars = {}
    roundv.running = true
end

function eventNewPlayer(pn)
    local p = room.playerList[pn]
    players[pn] = {
        windows = {
            help = false,
        },
        keys = {},
        sets = {},
        lang = "en",
        group = GROUP_PLAYER,
        internal_score = 0,
    }

    if translations[p.community] then
        players[pn].lang = p.community
    end

    if dev[pn] then
        players[pn].group = GROUP_DEV
    elseif staff[pn] then
        players[pn].group = GROUP_STAFF
    elseif room.name:find(ZeroTag(pn)) or (p.tribeName and room.name:find(p.tribeName)) then
        players[pn].group = GROUP_ADMIN
    end

    playerData[pn] = PDHelper.new(pn, table_copy(DEFAULT_PD))
    system.loadPlayerData(pn)

    system.bindMouse(pn, true)
    for key, a in pairs(keys) do
        if a.trigger == DOWN_ONLY then
            system.bindKeyboard(pn, key, true)
        elseif a.trigger == UP_ONLY then
            system.bindKeyboard(pn, key, false)
        elseif a.trigger == DOWN_UP then
            system.bindKeyboard(pn, key, true)
            system.bindKeyboard(pn, key, false)
        end
    end

    local load_lobby = false
    if pL.room:len() == 1 and roundv.lobby and module_started then
        load_lobby = true
    end
    pL.room:add(pn)
    pL.dead:add(pn)

    tfm.exec.chatMessage("\t<VP>Ξ Welcome to <b>Team Shaman (TSM)</b> v0.7 Alpha! Ξ\n<J>TSM is a building module where dual shamans take turns to spawn objects.\nPress H for more information.\n<R>NOTE: <VP>Module is in early stages of development and may see incomplete or broken features.", pn)

    tfm.exec.setPlayerScore(pn, 0)

    if playerData[pn]:getToggle(OPT_GUI) then
        sWindow.open(WINDOW_GUI, pn)
    end
    if roundv.lobby then
        sWindow.open(WINDOW_LOBBY, pn)
    end

    if load_lobby then 
        rotate_evt.lobby()
    end
end

function eventPlayerDied(pn)
    pL.alive:remove(pn)
    pL.dead:add(pn)
    rotate_evt.died(pn)
end

function eventPlayerWon(pn, elapsed)
    pL.alive:remove(pn)
    pL.dead:add(pn)
    rotate_evt.won(pn)
end

function eventPlayerLeft(pn)
    pL.room:remove(pn)
    if pL.spectator[pn] then
        pL.spectator:remove(pn)
    end
    if players[pn].pair then
        local target = players[pn].pair
        players[target].pair = nil
    end
    sWindow.clearPlayer(pn)
end

function eventPlayerRespawn(pn)
    pL.dead:remove(pn)
    pL.alive:add(pn)
end

function eventSummoningStart(pn, type, xPos, yPos, angle)
    roundv.startsummon = true  -- workaround b/2
    if type == 44 then  -- totems are banned; TODO: need more aggressive ban since this can be bypassed with (forced) lag
        local player = room.playerList[pn]
		local x, y = player.x, player.y
        tfm.exec.setShamanMode(pn, roundv.mode == TSM_HARD and 1 or 2)
		tfm.exec.movePlayer(pn, x, y, false, 0, 0, false)
	end
end

function eventSummoningEnd(pn, type, xPos, yPos, angle, desc)
    local ping = nil
    if roundv.start_epoch then
        ping = os.time() - roundv.start_epoch
    end
    if roundv.startsummon then  -- workaround b/2: map prespawned object triggers summoning end event
        -- AntiLag™ by Leafileaf
        if playerData[pn]:getToggle(OPT_ANTILAG) and desc.baseType ~= 17 and desc.baseType ~= 32 then
            tfm.exec.moveObject(desc.id, xPos, yPos, false, 0, 0, false, angle, false)
        end
        if not roundv.lobby then
            if type == 0 then  -- arrow
                --points deduct for tdm
            elseif desc.baseType == 28 then  -- balloon
                if band(roundv.mapinfo.flags, MP_NOBALLOON) ~= 0 then
                    tfm.exec.removeObject(desc.id)
                elseif not desc.ghost and roundv.sballoon_count >= 3 then
                    tfm.exec.removeObject(desc.id)
                    tfm.exec.chatMessage("<J>Ξ You may not spawn any more solid balloons.", pn)
                end
            else
                local rightful_turn = roundv.shaman_turn
                if pn ~= roundv.shamans[rightful_turn] then
                    tfm.exec.removeObject(desc.id)
                    tfm.exec.chatMessage("<J>Ξ It is not your turn to spawn yet ya dummy!", pn)
                    --points deduct
                else
                    if #roundv.shamans ~= 2 then return end
                    local s1, s2 = room.playerList[roundv.shamans[1]], room.playerList[roundv.shamans[2]]
                    if roundv.mode == TSM_HARD and not pythag(s1.x, s1.y, s2.x, s2.y, 60) then  -- TODO: lowerSyncDelay for more accurate position
                        local other = rightful_turn == 1 and 2 or 1
                        tfm.exec.removeObject(desc.id)
                        tfm.exec.chatMessage("<J>Ξ Your partner needs to be within your spawning range.", pn)
                        tfm.exec.chatMessage("<J>Ξ You need to be within your partner's spawning range.", roundv.shamans[other])
                    else
                        roundv.shaman_turn = rightful_turn == 1 and 2 or 1
                        UpdateTurnUI()
                        UpdateCircle()

                        local sl = roundv.spawnlist[pn]
                        sl[sl._len+1] = desc.id
                        sl._len = sl._len + 1

                        -- track solid balloons
                        if desc.baseType == 28 and not desc.ghost and roundv.sballoon_count < 3 then
                            roundv.sballoon_count = roundv.sballoon_count + 1
                            tfm.exec.chatMessage(string.format("<ROSE>%s used a solid balloon! (%s left)", pDisp(pn), 3 - roundv.sballoon_count))
                        end
                    end
                end
            end
        end
    elseif roundv.lobby and type == 90 then
        -- ping detector
        if pL.shaman[pn] and ping then
            if ping >= ANTILAG_FORCE_THRESHOLD then
                -- enable antilag
                tfm.exec.chatMessage("<ROSE>Hey there, you appear to be really laggy. We have enabled AntiLag for you.", pn)
                playerData[pn]:setToggle(OPT_ANTILAG, true)
            elseif ping >= ANTILAG_WARN_THRESHOLD and not playerData[pn]:getToggle(OPT_ANTILAG) then
                -- enable antilag if it isn't already so
                tfm.exec.chatMessage("<ROSE>Hey there, you appear to have lagged. You should consider enabling AntiLag via the options menu (press O).", pn)
            end
        end
        tfm.exec.chatMessage("[dbg] the sync is "..pn.." with a ping of "..(ping or "N/A").." ms")
    end
end

function eventTextAreaCallback(id, pn, cb)
    local params = {}
    if cb:find('!') then 
        params = string_split(cb:match('!(.*)'), '&')
        cb = cb:match('(%w+)!')
    end
    -- It is possible for players to alter callback strings
    local success, result = pcall(callbacks[cb], pn, table.unpack(params))
    if not success then
        print(string.format("Exception encountered in eventTextAreaCallback (%s): %s", pn, result))
    end
end

local init = function()
    print("Module is starting...")
    for _,v in ipairs({'AllShamanSkills','AutoNewGame','AutoScore','AutoTimeLeft','PhysicalConsumables'}) do
        tfm.exec['disable'..v](true)
    end
    system.disableChatCommandDisplay(nil,true)
    for name in pairs(room.playerList) do eventNewPlayer(name) end
    tfm.exec.setRoomMaxPlayers(DEFAULT_MAX_PLAYERS)
    tfm.exec.setRoomPassword("")
    rotate_evt.lobby()

    MDHelper.trySync()
end

init()
debug.disableEventLog(true)
