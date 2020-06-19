
local translations = {}
local staff = {["Cass11337#8417"]=true, ["Emeryaurora#0000"]=true, ["Pegasusflyer#0000"]=true, ["Tactcat#0000"]=true, ["Leafileaf#0000"]=true, ["Rini#5475"]=true, ["Rayallan#0000"]=true}
local dev = {["Cass11337#8417"]=true, ["Casserole#1798"]=true}

local players = {}  -- module specific player data
local roundv = {}  -- data spanning the lifetime of the round
local new_game_vars = {}  -- data spanning the lifetime till the next eventNewGame

-- Keeps an accurate list of players and their states by rely on asynchronous events to update
-- This works around playerList issues which are caused by it relying on sync and can be slow to update
local pL = {
    room = {},
    alive = {},
    dead = {},
    shaman = {},
    non_shaman = {},
    spectator = {},
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
local WINDOW_SETTINGS = bit32.lshift(3, 7)

-- TextAreas
local TA_SPECTATING = 9000

-- GUI color defs
local GUI_BTN = "<font color='#EDCC8D'>"

----- Forward declarations (local)
local keys, cmds, cmds_alias, callbacks, sWindow, setSpectate

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
    return pn:find('#') and pn:sub(1,-6) or pn
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
            diff = math.random(1, #mapdb['tdm'])  -- TODO: user-defined diff, and mode!
            map = mapdb['tdm'][diff][ math.random(1,#mapdb['tdm'][diff])]
        until not roundv.previousmap or tonumber(map) ~= roundv.previousmap
        new_game_vars.difficulty = diff

        map_sched.load(map)
    end

    local function lobby()
        for name in pairs(pL.shaman) do
            players[name].internal_score = 0
            tfm.exec.setPlayerScore(name, 0)
        end

        local highest = {-1}
        local second_highest = nil
        for name in pairs(pL.room) do
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
        new_game_vars.previous_round = {
            mapcode = roundv.mapinfo and roundv.mapinfo.code or nil,
            shamans = {pL.shaman[1], pL.shaman[2]},
        }
        new_game_vars.lobby = true
        map_sched.load(7740307)
    end
    
    local function diedwon(type, pn)
        local allplayerdead = true
        local allnonshamdead = true
        for name in pairs(pL.room) do
            if not pL.dead[name] then allplayerdead = false end
            if not pL.dead[name] and pL.non_shaman[name] then allnonshamdead = false end
        end
        if allplayerdead then
            lobby()
        elseif allnonshamdead then
            if type=='won' then tfm.exec.setGameTime(20) end
            if roundv.mapinfo.Opportunist then
                for _,name in pairs(roundv.shaman) do
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
                local T = {{"event:help!Welcome","?"},{"event:playersets","P"},{"event:roomsets","O"}}
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
                    ui.addTextArea(WINDOW_HELP+1,"",pn,75,40,650,340,0x4c1130,0x4c1130,1,true)  -- the background
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
                    local text = [[
<p align="center"><J><font size='14'><b>Welcome to #ShamTeam</b></font></p>
<p align="left"><font size='12'><N>The gameplay is simple: You will pair with another shaman and take turns spawning objects. You earn points at the end of the round depending on mice saved. But be careful! If you make a mistake by spawning when it's not your turn, or dying, you and your partner will lose points! There will be mods that you can enable to make your gameplay a little bit more challenging, and should you win the round, your score will be multiplied accordingly. 
                    ]]
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
<p align="left"><font size='12'><N>#shamteam is brought to you by the Academy of Building! It would not be possible without these people:

<J>Casserole#1798<N> - Developer
<J>Emeryaurora#0000<N> - Module inspiration, module designer & mapcrew
<J>Pegasusflyer#0000<N> - Module inspiration, module designer & mapcrew
<J>Tactcat#0000<N> - Module inspiration

A full list of staff are available via the !staff command. 
                    ]]
                    ui.addTextArea(WINDOW_HELP+51,text,pn,88,95,625,nil,0,0,0,true)
                    local img_id = tfm.exec.addImage("172cde7e326.png", "&"..WINDOW_HELP+51, 571, 180, pn)
                    p_data.images[tab] = {img_id}
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
                ui.addTextArea(WINDOW_LOBBY+21,"<p align='center'><font size='32'><VI>20", nil, 370, 245, 50, nil,gui_bg,gui_b,gui_o,true)

            end,
            close = function(pn, p_data)
                ui.removeTextArea(WINDOW_LOBBY+21)
            end,
            type = INDEPENDENT,
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
            windows[window_id].players[pn].is_open = false
            windows[window_id].close(pn, windows[window_id].players[pn])
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
end

keys = {
    [71] = {
        func = function(pn, enable) -- g (display GUI for shamans)
            if pL.shaman[pn] then
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
        func = function(pn, m)
            local argv = string_split(m, '%s')
            if argv[2] and tfm.exec[argv[2]]~=nil then
                local args = {}
                local buildstring = {false}
                for i = 3, #argv do
                    arg = argv[i]
                    if arg=='true' then args[#args+1]=true
                    elseif arg=='false' then args[#args+1]=false
                    elseif arg=='nil' then args[#args+1]=nil
                    elseif tonumber(arg) ~= nil then args[#args+1]=tonumber(arg)
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
                        args[#args+1] = params
                    elseif arg:find('^"(.*)"$') then
                        args[#args+1] = arg:match('^"(.*)"$'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    elseif arg:find('^"(.*)') then
                        buildstring[1] = true
                        buildstring[2] = arg:match('^"(.*)'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    elseif arg:find('(.*)"$') then
                        buildstring[1] = false
                        args[#args+1] = buildstring[2] .. " " .. arg:match('(.*)"$'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    elseif buildstring[1] then
                        buildstring[2] = buildstring[2] .. " " .. arg:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    else
                        args[#args+1] = arg
                    end
                end
                tfm.exec[argv[2]](table.unpack(args))
            else
                MSG('no such exec '..(argv[2] and argv[2] or 'nil'), pn)
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
    }
}

cmds_alias = {
    m = "mort",
    afk = "spectate",
    unafk = "spectate",
}

-- NOTE: It is possible for players to alter callback strings, ensure
-- that callbacks are designed to protect against bad inputs!
callbacks = {
    help = function(pn, tab)
        if tab == 'Close' then
            sWindow.close(WINDOW_HELP, pn)
        else
            sWindow.open(WINDOW_HELP, pn, tab)
        end
    end,
    unafk = function(pn)
        setSpectate(pn, false)
        tfm.exec.chatMessage("<ROSE>Welcome back! We've been expecting you.", pn)
    end,
}

setSpectate = function(pn, b)
    if b then
        pL.spectator[pn] = true
        players[pn].internal_score = -1
        tfm.exec.setPlayerScore(pn, -5)
        tfm.exec.killPlayer(pn)
        ui.addTextArea(TA_SPECTATING, GUI_BTN.."<font size='14'><p align='center'><a href='event:unafk'>You have entered spectator mode.\nClick here to exit spectator mode.", pn, 190, 355, 420, nil, 1, 0, .7, true)
    else
        pL.spectator[pn] = nil
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
    tfm.exec.chatMessage("<N>"..table.concat(strT, "\n"),pn,"N")
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
    if not tfm.get.room.xmlMapInfo then
        roundv = { running = false }
        return
    end
    roundv = {
        mapinfo = {
            Wind = 0,
            Gravity = 10,
            MGOC = 100,
            mirrored = tfm.get.room.mirroredMap,
            author = tfm.get.room.xmlMapInfo.author,
            code = tonumber(tfm.get.room.currentMap:match('%d+'))
        },
        shamans = {},
        shaman_turn = 1,
        difficulty = new_game_vars.difficulty or 0,
        phase = 0,
        running = true,
        lobby = new_game_vars.lobby,
    }

    pL.dead = {}
    pL.alive = table_copy(pL.room)
    pL.shaman = {}
    pL.non_shaman = {}

    for name, p in pairs(tfm.get.room.playerList) do
        if p.isShaman then
            roundv.shamans[#roundv.shamans+1] = name
            pL.shaman[name] = true
        else
            pL.non_shaman[name] = true
        end
    end
    assert(#roundv.shamans <= 2, "Shaman count is greater than 2: "..#roundv.shamans)

    for name in pairs(pL.spectator) do
        tfm.exec.killPlayer(name)
        tfm.exec.setPlayerScore(name, -5)
    end

    if roundv.lobby then
        if new_game_vars.previous_round then
            -- show back the GUI for the previous round of shamans
            for i = 1, #new_game_vars.previous_round.shamans do
                sWindow.open(WINDOW_GUI, new_game_vars.previous_round.shamans[i])
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
        ui.setMapName("TSM LOBBY")
        tfm.exec.disableMortCommand(true)
    else
        -- hide the GUI for shamans
        for i = 1, #roundv.shamans do
            local name = roundv.shamans[i]
            sWindow.close(WINDOW_GUI, name)
        end
        sWindow.close(WINDOW_LOBBY, nil)
        tfm.exec.setGameTime(180)
        ReadXML()
        ShowMapInfo()
        if #roundv.shamans == 2 then
            tfm.exec.chatMessage(string.format("<ROSE>Ξ <CH>%s <ROSE>& <font color='#FEB1FC'>%s <ROSE>are now the shaman pair!", pDisp(roundv.shamans[1]), pDisp(roundv.shamans[2])))
        else
            tfm.exec.chatMessage("<R>Ξ No shaman pair!")
        end
        UpdateTurnUI()
        ui.setMapName("<VI>[TDM] <ROSE>Difficulty "..roundv.difficulty.." - <VP>@"..roundv.mapinfo.code)
        tfm.exec.disableMortCommand(false)
    end
    new_game_vars = {}
end

function eventNewPlayer(pn)
    local p = tfm.get.room.playerList[pn]
    players[pn] = {
        windows = {
            help = false,
        },
        keys = {},
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
    if #pL.room == 1 and false then  -- TODO: restart to the lobby, doesn't work well atm
        load_lobby = true
    end
    pL.room[pn] = true
    pL.dead[pn] = true

    tfm.exec.chatMessage("\t<VP>Ξ Welcome to <b>Team Shaman (TSM)</b> v0.1 Alpha! Ξ\n<J>TSM is a building module where dual shamans take turns to spawn objects.\nPress H for more information.\n<R>NOTE: <VP>For development purposes this module will only run Team Divine Mode tentatively. As the module starts picking up shape, Team Hard Mode will be available.", pn)

    tfm.exec.setPlayerScore(pn, 0)
    tfm.exec.setShamanMode(pn, 2)  -- Force divine for TDM

    sWindow.open(WINDOW_GUI, pn)

    if load_lobby then 
        rotate_evt.lobby()
    end
end

function eventPlayerDied(pn)
    pL.alive[pn] = nil
    pL.dead[pn] = true
    rotate_evt.died(pn)
end

function eventPlayerWon(pn, elapsed)
    pL.alive[pn] = nil
    pL.dead[pn] = true
    rotate_evt.won(pn)
end

function eventPlayerLeft(pn)
    pL.room[pn] = nil
    pL.spectator[pn] = nil
    if players[pn].pair then
        local target = players[pn].pair
        players[target].pair = nil
    end
    sWindow.clearPlayer(pn)
end

function eventPlayerRespawn(pn)
    pL.dead[pn] = nil
    pL.alive[pn] = true
end

function eventSummoningStart(pn, type, xPos, yPos, angle)
    if type ~= 0 then
        local rightful_turn = roundv.shaman_turn
        if pn ~= roundv.shamans[rightful_turn] then
            --tfm.exec.chatMessage("<J>Ξ It is not your turn to spawn yet! Take a chill pill!", pn)
        end
    end
    roundv.startsummon = true  -- workaround b/2
end

function eventSummoningEnd(pn, type, xPos, yPos, angle, desc)
    -- AntiLag™ by Leafileaf
    -- TODO: !antilag + dynamic detection
    if roundv.startsummon then  -- workaround b/2: map prespawned object triggers summoning end event
        if false and desc.baseType ~= 17 and desc.baseType ~= 32 then
            tfm.exec.moveObject(desc.id, xPos, yPos, false, 0, 0, false, angle, false)
        end
        if desc.baseType ~= 0 then
            local rightful_turn = roundv.shaman_turn
            if pn ~= roundv.shamans[rightful_turn] then
                tfm.exec.removeObject(desc.id)
                tfm.exec.chatMessage("<J>Ξ It is not your turn to spawn yet ya dummy!", pn)
            else
                if #roundv.shamans ~= 2 then return end
                roundv.shaman_turn = rightful_turn == 1 and 2 or 1
                UpdateTurnUI()
            end
        end
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
    for _,v in ipairs({'AfkDeath','AllShamanSkills','AutoNewGame','AutoScore','AutoTimeLeft','PhysicalConsumables'}) do
        tfm.exec['disable'..v](true)
    end
    system.disableChatCommandDisplay(nil,true)
    for name in pairs(tfm.get.room.playerList) do eventNewPlayer(name) end
    rotate_evt.lobby()
end

init()
debug.disableEventLog(true)
