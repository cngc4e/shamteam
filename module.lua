local translations = {}
local players = {}  -- module room player data
local playerData = {}  -- module persistent player data
local roundv = {}  -- data spanning the lifetime of the round
local new_game_vars = {}  -- data spanning the lifetime till the next eventNewGame
local module_started = false

-- Keeps an accurate list of players and their states by rely on asynchronous events to update
-- This works around playerList issues which are caused by it relying on sync and can be slow to update
local pL = {
    room = { _len = 0 },
    alive = { _len = 0 },
    dead = { _len = 0},
    shaman = { _len = 0 },
    non_shaman = { _len = 0 },
    spectator = { _len = 0 },
}

-- TODO: temporary..
local mapdb = {
    tdm = {
        {"1803400", "6684914", "3742299", "3630912"},
        {"1852359", "6244577"},
        {"294822", "6400012"},
        {"5417400", "2611862", "3292713", "3587523", "6114320", "1287411", "5479449", "1289915"},
        {"1236698", "3833268", "7294988", "6971076"}
    }
}

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
local WINDOW_GUI = bit32.lshift(0, 7)
local WINDOW_HELP = bit32.lshift(1, 7)
local WINDOW_LOBBY = bit32.lshift(2, 7)
local WINDOW_OPTIONS = bit32.lshift(3, 7)

-- TextAreas
local TA_SPECTATING = 9000

-- MOD FLAGS
local MOD_TELEPATHY = bit32.lshift(1, 0)
local MOD_WORK_FAST = bit32.lshift(1, 1)
local MOD_BUTTER_FINGERS = bit32.lshift(1, 2)
local MOD_SNAIL_NAIL = bit32.lshift(1, 3)

-- OPTIONS FLAGS
local OPT_ANTILAG = bit32.lshift(1, 0)
local OPT_GUI = bit32.lshift(1, 1)
local OPT_LANGUAGE = bit32.lshift(1, 2)

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
local IMG_TOGGLE_ON = "172e5c315f1.png" -- 30px width
local IMG_TOGGLE_OFF = "172e5c335e7.png" -- 30px width
local IMG_LOBBY_BG = "172e68f8d24.png"
local IMG_HELP = "172e72750d9.png" -- 18px width
local IMG_OPTIONS_BG = "172eb766bdd.png" -- 240 x 325

-- Others
local staff = {["Cass11337#8417"]=true, ["Emeryaurora#0000"]=true, ["Pegasusflyer#0000"]=true, ["Tactcat#0000"]=true, ["Leafileaf#0000"]=true, ["Rini#5475"]=true, ["Rayallan#0000"]=true}
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
}

local default_playerData = {
    toggles = 0,
}

-- Toggles enabled by default
default_playerData.toggles = bit32.bor(default_playerData.toggles, OPT_GUI)

----- Forward declarations (local)
local keys, cmds, cmds_alias, callbacks, sWindow, getExpMult, setSpectate

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

-- iterate over a key-value pair table, skipping the "_len" key
local function cnext(tbl, k)
    local v
    k, v = next(tbl, k)
    if k~="_len" then 
        return k,v
    else
        k, v = next(tbl, k)
        return k,v
    end
end
local function cpairs(tbl)
    return cnext, tbl, nil
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
    for name in pairs(tfm.get.room.playerList) do
        if string.lower(name):find(ign) then return name end
    end
    if pn then tfm.exec.chatMessage("<R>error: no such target", pn) end
end

local function pDisp(pn)
    -- TODO: check if the player has the same name as another existing player in the room.
    return pn and (pn:find('#') and pn:sub(1,-6)) or nil
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

----- LIBS / HELPERS
local map_sched = {}
do
    local queued_code
    local queued_mirror
    local call_after
    local is_waiting = false

    local function load(code, mirror)
        queued_code = code
        queued_mirror = mirror
        if not call_after or call_after <= os.time() then
            is_waiting = false
            call_after = os.time() + 3000
            tfm.exec.newGame(code, mirror)
        else
            is_waiting = true
        end
    end

   local function run()
        if is_waiting and call_after <= os.time() then
            call_after = nil
            load(queued_code, queued_mirror)
        end
    end

    map_sched.load = load
    map_sched.run = run
end

-- Handles map rotation and scoring
local rotate_evt
do
    local function rotate()
        local diff,map
        repeat
            diff = math.random(roundv.diff1, roundv.diff2)  -- TODO: user-defined diff, and mode!
            map = mapdb[roundv.mode][diff][ math.random(1,#mapdb[roundv.mode][diff])]
        until not roundv.previousmap or tonumber(map) ~= roundv.previousmap
        new_game_vars.difficulty = diff
        new_game_vars.mods = roundv.mods

        map_sched.load(map)
    end

    local function lobby()
        for name in cpairs(pL.shaman) do
            players[name].internal_score = 0
            tfm.exec.setPlayerScore(name, 0)
        end

        local highest = {-1}
        local second_highest = nil
        for name in cpairs(pL.room) do
            if not pL.spectator[name] then
                players[name].internal_score = players[name].internal_score + 1
                if players[name].internal_score >= highest[1] then
                    second_highest = highest[2]
                    highest[1] = players[name].internal_score
                    highest[2] = name
                end
            end
            tfm.exec.chatMessage("[dbg] int score "..name..": "..players[name].internal_score)
        end

        tfm.exec.setPlayerScore(highest[2], 100)
        if players[highest[2]] and players[highest[2]].pair then
            tfm.exec.setPlayerScore(players[highest[2]].pair, 100)
        elseif second_highest then
            tfm.exec.setPlayerScore(second_highest, 100) -- TODO: prioritise the pre-defined pair or soulmate
        end

        -- pass statistics and info on the previous round
        if roundv.running then
            new_game_vars.previous_round = {
                mapcode = roundv.mapinfo and roundv.mapinfo.code or nil,
                shamans = table_copy(roundv.shamans),
            }
        end
        new_game_vars.lobby = true
        map_sched.load(7740307)
    end
    
    local function diedwon(type, pn)
        local allplayerdead = true
        local allnonshamdead = true
        for name in cpairs(pL.room) do
            if not pL.dead[name] then allplayerdead = false end
            if not pL.dead[name] and pL.non_shaman[name] then allnonshamdead = false end
        end
        if allplayerdead then
            lobby()
        elseif allnonshamdead then
            if type=='won' then tfm.exec.setGameTime(20) end
            if roundv.mapinfo.Opportunist then
                for name in cpairs(pL.shaman) do
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
                local tabs = {'Welcome','Rules','Commands','Contributors','Close'}
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
                    local opacity = (v == tab) and 0 or 1 
                    ui.addTextArea(WINDOW_HELP+1+i, GUI_BTN.."<font size='2'><br><font size='12'><p align='center'><a href='event:help!"..v.."'>"..v.."</a>",pn,92+((i-1)*130),50,100,24,0x666666,0x676767,opacity,true)
                end
                p_data.tab = tab

                if tab == "Welcome" then
                    local text = string.format([[
<p align="center"><J><font size='14'><b>Welcome to #ShamTeam</b></font></p>
<p align="left"><font size='12'><N>Welcome to Team Shaman Mode (TSM)! The gameplay of TSM is simple: You will pair with another shaman and take turns spawning objects. You earn points at the end of the round depending on mice saved. But be careful! If you make a mistake by spawning when it's not your turn, or dying, you and your partner will lose points! There will be mods that you can enable to make your gameplay a little bit more challenging, and should you win the round, your score will be multiplied accordingly.

Join our discord server for help and more information!
Link: %s<a href="event:link!%s">discord.gg/YkzM4rh</a>
                    ]], GUI_BTN, LINK_DISCORD)
                    ui.addTextArea(WINDOW_HELP+21,text,pn,88,95,625,nil,0,0,0,true)
                elseif tab == "Commands" then
                    local text = [[
<p align="center"><J><font size='14'><b>Commands</b></font></p>
<p align="left"><font size='12'><N>!m/!mort - kills yourself
!afk - mark yourself as a spectator
!pair [player] - request to pair up with a player
!cancel - cancels existing forced pairing or pairing request

!stats [player] - view your stats or another player’s
                    ]]
                    ui.addTextArea(WINDOW_HELP+41,text,pn,88,95,625,nil,0,0,0,true)
                elseif tab == "Contributors" then
                    local text = [[
<p align="center"><J><font size='14'><b>Contributors</b></font></p>
<p align="left"><font size='12'><N>#shamteam is brought to you by the Academy of Building! It would not be possible without the following people:

<J>Casserole#1798<N> - Developer
<J>Emeryaurora#0000<N> - Module inspiration, module designer & mapcrew
<J>Pegasusflyer#0000<N> - Module inspiration, module designer & mapcrew
<J>Tactcat#0000<N> - Module inspiration

A full list of staff are available via the !staff command. 
                    ]]
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
            open = function(pn, p_data, tab)
                p_data.images = { main={}, help={}, toggle={} }

                --ui.addTextArea(WINDOW_LOBBY+1,"",pn,75,40,650,340,1,0,.8,true)  -- the background
                local header = pL.shaman[pn] and "You’ve been chosen to pair up for the next round!" or "Every second, 320 baguettes are eaten in France!"
                ui.addTextArea(WINDOW_LOBBY+2,"<p align='center'><font size='13'>"..header,pn,75,50,650,nil,1,0,1,true)
                p_data.images.main[1] = {tfm.exec.addImage(IMG_LOBBY_BG, ":"..WINDOW_LOBBY, 70, 40, pn)}

                -- shaman cards
                --ui.addTextArea(WINDOW_LOBBY+3,"",pn,120,85,265,200,0xcdcdcd,0xbababa,.1,true)
                --ui.addTextArea(WINDOW_LOBBY+4,"",pn,415,85,265,200,0xcdcdcd,0xbababa,.1,true)
                ui.addTextArea(WINDOW_LOBBY+5,"<p align='center'><font size='13'><b>"..pDisp(roundv.shamans[1]),pn,118,90,269,nil,1,0,1,true)
                ui.addTextArea(WINDOW_LOBBY+6,"<p align='center'><font size='13'><b>"..(pDisp(roundv.shamans[2]) or 'N/A'),pn,413,90,269,nil,1,0,1,true)

                -- mode
                p_data.images.main[2] = {tfm.exec.addImage(IMG_FEATHER_HARD, ":"..WINDOW_LOBBY, 202, 120, pn)}
                p_data.images.main[3] = {tfm.exec.addImage(IMG_FEATHER_DIVINE, ":"..WINDOW_LOBBY, 272, 120, pn)}

                -- difficulty
                ui.addTextArea(WINDOW_LOBBY+7,"<p align='center'><font size='13'><b>Difficulty",pn,120,184,265,nil,1,0,.2,true)
                ui.addTextArea(WINDOW_LOBBY+8,"<p align='center'><font size='13'>to",pn,240,240,30,nil,1,0,0,true)
                ui.addTextArea(WINDOW_LOBBY+9,"<p align='center'><font size='13'><b>"..roundv.diff1,pn,190,240,20,nil,1,0,.2,true)
                ui.addTextArea(WINDOW_LOBBY+10,"<p align='center'><font size='13'><b>"..roundv.diff2,pn,299,240,20,nil,1,0,.2,true)
                ui.addTextArea(WINDOW_LOBBY+11,GUI_BTN.."<p align='center'><font size='17'><b><a href='event:diff!1&1'>&#x25B2;</a><br><a href='event:diff!1&-1'>&#x25BC;",pn,132,224,20,nil,1,0,0,true)
                ui.addTextArea(WINDOW_LOBBY+12,GUI_BTN.."<p align='center'><font size='17'><b><a href='event:diff!2&1'>&#x25B2;</a><br><a href='event:diff!2&-1'>&#x25BC;",pn,350,224,20,nil,1,0,0,true)

                -- mods
                local mods_str = {}
                local mods_helplink_str = {}
                local i = 1
                for k, mod in pairs(mods) do
                    mods_str[#mods_str+1] = string.format("<a href='event:modtoggle!%s'>%s", k, mod[1])
                    local is_set = bit32.band(roundv.mods, k) ~= 0
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
                ui.addTextArea(WINDOW_LOBBY+17,"<p align='center'><font size='13'><N>Exp multiplier:<br><font size='15'>"..expDisp(getExpMult()),pn,330,333,140,nil,1,0,0,true)

                -- ready
                ui.addTextArea(WINDOW_LOBBY+18, GUI_BTN.."<font size='2'><br><font size='12'><p align='center'><a href='event:ready'>".."&#9744; Ready".."</a>",pn,200,340,100,24,0x666666,0x676767,1,true)
                ui.addTextArea(WINDOW_LOBBY+19, GUI_BTN.."<font size='2'><br><font size='12'><p align='center'><a href='event:ready'>".."&#9744; Ready".."</a>",pn,500,340,100,24,0x666666,0x676767,1,true)
            end,
            close = function(pn, p_data)
                for i = 1, 19 do
                    ui.removeTextArea(WINDOW_LOBBY+i)
                end
                for _, imgs in pairs(p_data.images) do
                    for k, img_dat in pairs(imgs) do
                        tfm.exec.removeImage(img_dat[1], pn)
                    end
                end
                p_data.images = {}
            end,
            type = INDEPENDENT,
            players = {}
        },
        [WINDOW_OPTIONS] = {
            open = function(pn, p_data, tab)
                p_data.images = { main={}, toggle={}, help={} }

                p_data.images.main[1] = {tfm.exec.addImage(IMG_OPTIONS_BG, ":"..WINDOW_OPTIONS, 520, 47, pn)}
                ui.addTextArea(WINDOW_OPTIONS+1, "<font size='3'><br><p align='center'><font size='13'><J><b>Settings", pn, 588,52, 102,30, 1, 0, 0, true)
                ui.addTextArea(WINDOW_OPTIONS+2, "<a href='event:options!close'><font size='30'>\n", pn, 716,48, 31,31, 1, 0, 0, true)

                local opts_str = {}
                local opts_helplink_str = {}
                local i = 1
                for k, opt in pairs(options) do
                    opts_str[#opts_str+1] = string.format("<a href='event:opttoggle!%s'>%s", k, opt[1])
                    local is_set = bit32.band(playerData[pn].toggles, k) ~= 0
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
                    ui.removeTextArea(WINDOW_OPTIONS+i)
                end
                for _, imgs in pairs(p_data.images) do
                    for k, img_dat in pairs(imgs) do
                        tfm.exec.removeImage(img_dat[1], pn)
                    end
                end
                p_data.images = {}
            end,
            type = MUTUALLY_EXCLUSIVE,
            players = {}
        },
    }

    sWindow.open = function(window_id, pn, ...)
        if not windows[window_id] then
            return
        elseif not pn then
            for name in pairs(tfm.get.room.playerList) do
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
            for name in pairs(tfm.get.room.playerList) do
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
            if not pL.shaman[pn] or bit32.band(roundv.mods, MOD_BUTTER_FINGERS) == 0 then return end
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
                    if arg=='true' then args[args._len+1]=true
                    elseif arg=='false' then args[args._len+1]=false
                    elseif arg=='nil' then args[args._len+1]=nil
                    elseif tonumber(arg) ~= nil then args[args._len+1]=tonumber(arg)
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
                    elseif arg:find('^"(.*)"$') then
                        args[args._len+1] = arg:match('^"(.*)"$'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    elseif arg:find('^"(.*)') then
                        buildstring[1] = true
                        buildstring[2] = arg:match('^"(.*)'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    elseif arg:find('(.*)"$') then
                        buildstring[1] = false
                        args[args._len+1] = buildstring[2] .. " " .. arg:match('(.*)"$'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    elseif buildstring[1] then
                        buildstring[2] = buildstring[2] .. " " .. arg:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    else
                        args[args._len+1] = arg
                    end
                    args._len = args._len+1
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
    np = {
        func = function(pn, m, w1, w2)
            map_sched.load(w2)
        end,
        perms = GROUP_STAFF
    },
    score = {
        func = function(pn, m, w1, w2, w3)
            local num = tonumber(w2) or tonumber(w3) or 0
            local target = pFind(w1) or pFind(w2) or pn
            if num<0 or num>999 then MSG("score (0-999)",pn,'R')
            elseif w2=='all' or w3=='all' then
                for name in pairs(tfm.get.room.playerList) do tfm.exec.setPlayerScore(name, num) end
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
                        setSpectate(target, false)
                    end
                elseif not pL.spectator[target] and not pL.shaman[target] then
                    setSpectate(target, true)
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
    }
}

cmds_alias = {
    m = "mort",
    afk = "spectate",
    unafk = "spectate",
    ui = "exec",
    system = "exec",
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
        else
            sWindow.open(WINDOW_OPTIONS, pn)
        end
    end,
    unafk = function(pn)
        setSpectate(pn, false)
        tfm.exec.chatMessage("<ROSE>Welcome back! We've been expecting you.", pn)
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
    diff = function(pn, id, add)
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

        if new_diff < 1 or new_diff > #mapdb[roundv.mode]
                or (id == 1 and roundv.diff2 - new_diff < 1)
                or (id == 2 and new_diff - roundv.diff1 < 1) then  -- range error
            tfm.exec.chatMessage(string.format("<R>error: range must have a value of 1-%s and have a difference of at least 1", #mapdb[roundv.mode]), pn)
            return
        end

        roundv[diff_id] = new_diff
        ui.updateTextArea(WINDOW_LOBBY+9,"<p align='center'><font size='13'><b>"..roundv.diff1)
        ui.updateTextArea(WINDOW_LOBBY+10,"<p align='center'><font size='13'><b>"..roundv.diff2)
    end,
    ready = function(pn)
        if not roundv.running or not roundv.lobby then return end
        if roundv.shamans[1] == pn then
            local is_ready = not roundv.shaman_ready[1]
            roundv.shaman_ready[1] = is_ready

            local blt = is_ready and "&#9745;" or "&#9744;";
            ui.updateTextArea(WINDOW_LOBBY+18, GUI_BTN.."<font size='2'><br><font size='12'><p align='center'><a href='event:ready'>"..blt.." Ready".."</a>")
        elseif roundv.shamans[2] == pn then
            local is_ready = not roundv.shaman_ready[2]
            roundv.shaman_ready[2] = is_ready

            local blt = is_ready and "&#9745;" or "&#9744;";
            ui.updateTextArea(WINDOW_LOBBY+19, GUI_BTN.."<font size='2'><br><font size='12'><p align='center'><a href='event:ready'>"..blt.." Ready".."</a>")
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
        roundv.mods = bit32.bxor(roundv.mods, mod_id)  -- flip and toggle the flag
        local is_set = bit32.band(roundv.mods, mod_id) ~= 0
        for name in cpairs(pL.room) do
            local imgs = sWindow.getImages(WINDOW_LOBBY, name)
            local img_dats = imgs.toggle
            if img_dats and img_dats[mod_id] then
                tfm.exec.removeImage(img_dats[mod_id][1])
                img_dats[mod_id][1] = tfm.exec.addImage(is_set and IMG_TOGGLE_ON or IMG_TOGGLE_OFF, ":"..WINDOW_LOBBY, img_dats[mod_id][2], img_dats[mod_id][3])
            end
        end
        ui.updateTextArea(WINDOW_LOBBY+17,"<p align='center'><font size='13'><N>Exp multiplier:<br><font size='15'>"..expDisp(getExpMult()))
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
        playerData[pn].toggles = bit32.bxor(playerData[pn].toggles, opt_id)  -- flip and toggle the flag
        
        local is_set = bit32.band(playerData[pn].toggles, opt_id) ~= 0
        for name in cpairs(pL.room) do
            local imgs = sWindow.getImages(WINDOW_OPTIONS, name)
            local img_dats = imgs.toggle
            if img_dats and img_dats[opt_id] then
                tfm.exec.removeImage(img_dats[opt_id][1])
                img_dats[opt_id][1] = tfm.exec.addImage(is_set and IMG_TOGGLE_ON or IMG_TOGGLE_OFF, ":"..WINDOW_OPTIONS, img_dats[opt_id][2], img_dats[opt_id][3])
            end
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
    end,
    opthelp = function(pn, opt_id)
        opt_id = tonumber(opt_id) or -1
        local opt = options[opt_id]
        if opt then
            tfm.exec.chatMessage("<J>"..opt[1]..": "..opt[2], pn)
        end
    end,

}

getExpMult = function()
    local ret = 0
    for k, mod in pairs(mods) do
        if bit32.band(roundv.mods, k) ~= 0 then
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

setSpectate = function(pn, b)
    if b and not pL.spectator[pn] then
        pL.spectator[pn] = true
        pL.spectator._len = pL.spectator._len + 1
        players[pn].internal_score = -1
        tfm.exec.killPlayer(pn)
        tfm.exec.setPlayerScore(pn, -5)
        ui.addTextArea(TA_SPECTATING, GUI_BTN.."<font size='14'><p align='center'><a href='event:unafk'>You have entered spectator mode.\nClick here to exit spectator mode.", pn, 190, 355, 420, nil, 1, 0, .7, true)
    elseif pL.spectator[pn] then
        pL.spectator[pn] = nil
        pL.spectator._len = pL.spectator._len - 1
        players[pn].internal_score = 0
        tfm.exec.setPlayerScore(pn, 0)
        ui.removeTextArea(TA_SPECTATING, pn)
    end
end

local ShowMapInfo = function(pn)
    local sT, tags = roundv.mapinfo, {}
    if sT.Portals then tags[#tags+1] = "Portals" end
    if sT.No_Balloon then tags[#tags+1] = "No Balloon" end
    if sT.Opportunist then tags[#tags+1] = "Opportunist" end
    if sT.No_B then tags[#tags+1] = "No-B" end
    local strT = {string.format("<ROSE>[Map Info]<J> @%s <N>by <VP>%s%s", sT.code, sT.author, sT.mirrored and ' (mirrored)' or ''),
        string.format("<VP>Wind: <J>%s <VP>| Gravity: <J>%s <VP>| MGOC: <J>%s",sT.Wind or '0',sT.Gravity or '10', sT.MGOC or '100', sT.Portals and '<VP>' or '<R>')}
    if #tags > 0 then
        strT[#strT+1] = string.format("Tags: %s", table.concat(tags, ", "))
    end
    tfm.exec.chatMessage("<N>"..table.concat(strT, "\n"),pn)
end

local ShowMods = function(pn)
    local m = { _len = 0 }
    for k, mod in pairs(mods) do
        if bit32.band(roundv.mods, k) ~= 0 then
            m[m._len+1] = mod[1]
            m._len = m._len+1
        end
    end
    tfm.exec.chatMessage("<J>Mods: <N>"..table.concat(m, ", "), pn)
end

local ReadXML = function()
    local xml = tfm.get.room.xmlMapInfo.xml
    if not xml then
        return
    end
    local sT = roundv.mapinfo
    for attr, val in xml:match('<P .->'):gmatch('(%S+)="(%S*)"') do
        local a = string.upper(attr)
        if a == 'P' then sT.Portals = true
        elseif a == 'G' then
            sT.Gravity = string_split(val or "")
            sT.Wind, sT.Gravity = tonumber(sT.Gravity[1]), tonumber(sT.Gravity[2])
        elseif a == 'MGOC' then sT.MGOC = tonumber(val)
        elseif a:find('NOBALLOON') then sT.No_Balloon = true
        elseif a:find('OPPORTUNIST') then sT.Opportunist = true
        elseif a:find('NOB') and string.lower(val) == "true" then sT.No_B = true
        end
    end
end

local UpdateTurnUI = function()
    local color = "CH"
    local shaman = roundv.shamans[roundv.shaman_turn]
    ui.setShamanName(string.format("<%s>%s's <J>Turn", color, pDisp(shaman)))
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

function eventKeyboard(pn, k, d, x, y)
    if keys[k] then
        keys[k].func(pn, d, x, y)
    end
end

function eventLoop(elapsed, remaining)
    map_sched.run()
    if not roundv.running then return end
    if roundv.phase < 3 and remaining <= 0 then
        rotate_evt.timesup()
        roundv.phase = 3
    elseif roundv.lobby then
        ui.setMapName(string.format("<N>Next Shamans: <CH>%s <N>- <font color='#FEB1FC'>%s  <G>|  <N>Game starts in: <V>%s  <G>|  <N>Mice: <V>%s<", pDisp(roundv.shamans[1]), pDisp(roundv.shamans[2]) or '', math_round(remaining/1000), pL.room._len))
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
    local mapcode = tonumber(tfm.get.room.currentMap:match('%d+'))
    if (not module_started and mapcode ~= 7740307) or not tfm.get.room.xmlMapInfo then  -- workaround for b/4: init race condition
        roundv = { running = false }
        return
    end
    if not module_started then module_started = true end
    roundv = {
        mapinfo = {
            Wind = 0,
            Gravity = 10,
            MGOC = 100,
            mirrored = tfm.get.room.mirroredMap,
            author = tfm.get.room.xmlMapInfo.author,
            code = mapcode
        },
        shamans = {},
        shaman_turn = 1,
        undo_count = 0,
        spawnlist = {},
        difficulty = new_game_vars.difficulty or 0,
        phase = 0,
        lobby = new_game_vars.lobby,
        start_epoch = os.time(),
        mods = new_game_vars.mods or 0,
    }

    pL.dead = { _len = 0 }
    pL.alive = table_copy(pL.room)
    pL.shaman = { _len = 0 }
    pL.non_shaman = { _len = 0 }

    for name, p in pairs(tfm.get.room.playerList) do
        if p.isShaman then
            roundv.shamans[#roundv.shamans+1] = name
            pL.shaman[name] = true
            pL.shaman._len = pL.shaman._len + 1
        else
            pL.non_shaman[name] = true
            pL.non_shaman._len = pL.non_shaman._len + 1
        end
    end
    assert(#roundv.shamans <= 2, "Shaman count is greater than 2: "..#roundv.shamans)

    for name in cpairs(pL.spectator) do
        tfm.exec.killPlayer(name)
        tfm.exec.setPlayerScore(name, -5)
    end

    if roundv.lobby then
        roundv.diff1 = 1
        roundv.diff2 = 3
        roundv.mode = 'tdm'
        roundv.shaman_ready = {}
        if new_game_vars.previous_round then
            -- show back the GUI for the previous round of shamans
            for i = 1, #new_game_vars.previous_round.shamans do
                local name = new_game_vars.previous_round.shamans[i]
                if bit32.band(playerData[name].toggles, OPT_GUI) ~= 0 then
                    sWindow.open(WINDOW_GUI, name)
                end
            end
            roundv.previousmap = new_game_vars.previous_round.mapcode
        end
        sWindow.open(WINDOW_LOBBY, nil)
        tfm.exec.setGameTime(20)
        if #roundv.shamans == 2 then
            tfm.exec.chatMessage(string.format("<ROSE>Ξ <CH>%s <ROSE>& <font color='#FEB1FC'>%s <ROSE>are the next shaman pair!", pDisp(roundv.shamans[1]), pDisp(roundv.shamans[2])))
        else
            tfm.exec.chatMessage("<R>Ξ No shaman pair!")
        end
        tfm.exec.disableMortCommand(true)
        tfm.exec.disablePrespawnPreview(false)
    else
        for i = 1, #roundv.shamans do
            local name = roundv.shamans[i]

            roundv.spawnlist[name] = { _len = 0 }

            -- hide the GUI for shamans
            sWindow.close(WINDOW_GUI, name)
            
            -- Set mode there and back; this teleports both shamans to the first spawnpoint
            -- TODO: flip order for THM
            tfm.exec.setShamanMode(name, 1)
            tfm.exec.setShamanMode(name, 2)

        end

        ReadXML()
        ShowMapInfo()
        ShowMods()
        if #roundv.shamans == 2 then
            tfm.exec.chatMessage(string.format("<ROSE>Ξ <CH>%s <ROSE>& <font color='#FEB1FC'>%s <ROSE>are now the shaman pair!", pDisp(roundv.shamans[1]), pDisp(roundv.shamans[2])))
        else
            tfm.exec.chatMessage("<R>Ξ No shaman pair!")
        end
        UpdateTurnUI()
        ui.setMapName("<VI>[TDM] <ROSE>Difficulty "..roundv.difficulty.." - <VP>@"..roundv.mapinfo.code)
        
        tfm.exec.disableMortCommand(false)
        tfm.exec.disablePrespawnPreview(bit32.band(roundv.mods, MOD_TELEPATHY) ~= 0)

        local time_limit = 180  -- TODO: 200 for THM
        if bit32.band(roundv.mods, MOD_WORK_FAST) ~= 0 then
            time_limit = time_limit - 60
        end
        if bit32.band(roundv.mods, MOD_SNAIL_NAIL) ~= 0 then
            time_limit = time_limit + 30
        end
        tfm.exec.setGameTime(time_limit)
    end
    new_game_vars = {}
    roundv.running = true
end

function eventNewPlayer(pn)
    local p = tfm.get.room.playerList[pn]
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
    playerData[pn] = table_copy(default_playerData)  -- temp until database done
    if translations[p.community] then
        players[pn].lang = p.community
    end

    if dev[pn] then
        players[pn].group = GROUP_DEV
    elseif staff[pn] then
        players[pn].group = GROUP_STAFF
    elseif tfm.get.room.name:find(ZeroTag(pn)) or (p.tribeName and tfm.get.room.name:find(p.tribeName)) then
        players[pn].group = GROUP_ADMIN
    end

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
    if pL.room._len == 1 and false then  -- TODO: restart to the lobby, doesn't work well atm
        load_lobby = true
    end
    pL.room[pn] = true
    pL.room._len = pL.room._len + 1
    pL.dead[pn] = true
    pL.dead._len = pL.dead._len + 1

    tfm.exec.chatMessage("\t<VP>Ξ Welcome to <b>Team Shaman (TSM)</b> v0.4 Alpha! Ξ\n<J>TSM is a building module where dual shamans take turns to spawn objects.\nPress H for more information.\n<R>NOTE: <VP>For development purposes this module will only run Team Divine Mode tentatively. As the module starts picking up shape, Team Hard Mode will be available.", pn)

    tfm.exec.setPlayerScore(pn, 0)
    tfm.exec.setShamanMode(pn, 2)  -- Force divine for TDM

    if bit32.band(playerData[pn].toggles, OPT_GUI) ~= 0 then
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
    pL.alive[pn] = nil
    pL.alive._len = pL.alive._len - 1
    pL.dead[pn] = true
    pL.dead._len = pL.dead._len + 1
    rotate_evt.died(pn)
end

function eventPlayerWon(pn, elapsed)
    pL.alive[pn] = nil
    pL.alive._len = pL.alive._len - 1
    pL.dead[pn] = true
    pL.dead._len = pL.dead._len + 1
    rotate_evt.won(pn)
end

function eventPlayerLeft(pn)
    pL.room[pn] = nil
    pL.room._len = pL.room._len - 1
    if pL.spectator[pn] then
        pL.spectator[pn] = nil
        pL.spectator._len = pL.spectator._len - 1
    end
    if players[pn].pair then
        local target = players[pn].pair
        players[target].pair = nil
    end
    sWindow.clearPlayer(pn)
end

function eventPlayerRespawn(pn)
    pL.dead[pn] = nil
    pL.dead._len = pL.dead._len - 1
    pL.alive[pn] = true
    pL.alive._len = pL.alive._len + 1
end

function eventSummoningStart(pn, type, xPos, yPos, angle)
    roundv.startsummon = true  -- workaround b/2
end

function eventSummoningEnd(pn, type, xPos, yPos, angle, desc)
    local ping = nil
    if roundv.start_epoch then
        ping = os.time() - roundv.start_epoch
    end
    if roundv.startsummon then  -- workaround b/2: map prespawned object triggers summoning end event
        -- AntiLag™ by Leafileaf
        if bit32.band(playerData[pn].toggles, OPT_ANTILAG) ~= 0 and desc.baseType ~= 17 and desc.baseType ~= 32 then
            tfm.exec.moveObject(desc.id, xPos, yPos, false, 0, 0, false, angle, false)
        end
        if not roundv.lobby then
            if type == 0 then  -- arrow
                --points deduct for tdm
            else
                local rightful_turn = roundv.shaman_turn
                if pn ~= roundv.shamans[rightful_turn] then
                    tfm.exec.removeObject(desc.id)
                    tfm.exec.chatMessage("<J>Ξ It is not your turn to spawn yet ya dummy!", pn)
                    --points deduct
                else
                    if #roundv.shamans ~= 2 then return end
                    roundv.shaman_turn = rightful_turn == 1 and 2 or 1
                    UpdateTurnUI()

                    local sl = roundv.spawnlist[pn]
                    sl[sl._len+1] = desc.id
                    sl._len = sl._len + 1
                end
            end
        end
    elseif roundv.lobby and type == 90 then
        -- ping detector
        if pL.shaman[pn] and ping then
            if ping >= ANTILAG_FORCE_THRESHOLD then
                -- enable antilag
                tfm.exec.chatMessage("<ROSE>Hey there, you appear to be really laggy. We have enabled AntiLag for you.", pn)
                playerData[pn].toggles = bit32.bor(playerData[pn].toggles, OPT_ANTILAG)
            elseif ping >= ANTILAG_WARN_THRESHOLD and bit32.band(playerData[pn].toggles, OPT_ANTILAG) == 0 then
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
    for _,v in ipairs({'AfkDeath','AllShamanSkills','AutoNewGame','AutoScore','AutoTimeLeft','PhysicalConsumables'}) do
        tfm.exec['disable'..v](true)
    end
    system.disableChatCommandDisplay(nil,true)
    for name in pairs(tfm.get.room.playerList) do eventNewPlayer(name) end
    rotate_evt.lobby()
end

init()
debug.disableEventLog(true)
