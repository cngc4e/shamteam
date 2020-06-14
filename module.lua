
local translations = {}
local staff = {["Cass11337#8417"]=true, ["Emeryaurora#0000"]=true, ["Pegasusflyer#0000"]=true, ["Tactcat#0000"]=true}
local dev = {["Cass11337#8417"]=true, ["Casserole#1798"]=true}

local players = {}  -- module specific player data
local roundv  -- data spanning the lifetime of the round
local new_game_vars = {}  -- data spanning the lifetime till the next eventNewGame

-- TODO: temporary..
local mapdb = {
    tdm = {
        {"1803400", "6684914", "3742299", "3630912"},
        {"1852359", "6244577"},
        {"294822", "6400012"}
    }
}

----- ENUMS / CONST DEFINES
-- Permission levels
local GROUP_GUEST = 1
local GROUP_PLAYER = 2
local GROUP_ADMIN = 3
local GROUP_STAFF = 4
local GROUP_DEV = 5

-- Windows
local WINDOW_HELP = bit32.lshift(0, 8)

-- GUI color defs
local GUI_BTN = "<font color='#EDCC8D'>"

----- Forward declarations (local)
local keys, cmds, callbacks, sWindow

----- GENERAL UTILS
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
		p = pn:find('#0000') and pn:sub(1,-6) or pn
		return p
	end
end

local function pFind(target, pn)
	local ign = string.lower(target or ' ')
	for name in pairs(tfm.get.room.playerList) do
		if string.lower(name):find(ign) then return name end
	end
	if pn then tfm.exec.chatMessage("<R>error: no such target", pn) end
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
        is_waiting = true
        if not call_after or call_after <= os.time() then
            is_waiting = false
            call_after = os.time() + 3000
            tfm.exec.newGame(code, mirror)
        end
    end

   local function run()
        if is_waiting and (call_after or call_after <= os.time()) then
            call_after = nil
            load(queued_code, queued_mirror)
        end
    end

    map_sched.load = load
    map_sched.run = run
end

-- Adapted from Player Flow (performatic).lua, original author: Bolodefchoco
local player_state
do
    local room  = { _count = 0 }
    local alive = { _count = 0 }
    local dead  = { _count = 0 }
    local shaman = { _count = 0 }
    local non_shaman = { _count = 0 }
    local spectator = { _count = 0 }  -- TODO

    local players_insert = function(where, playerName)
        if not where[playerName] then
            where._count = where._count + 1
            where[where._count] = playerName
            where[playerName] = where._count
        end
    end

    local players_remove = function(where, playerName)
        if where[playerName] then
            where._count = where._count - 1
            where[where[playerName]] = nil
            where[playerName] = nil
        end
    end

    player_state = {
        room = room,
        alive = alive,
        dead = dead,
        shaman = shaman,
        non_shaman = non_shaman,
        spectator = spectator,
        add = players_insert,
        remove = players_remove
    }
end

-- Handles map rotation and scoring
local rotate_evt
do
    local function rotate()
        local diff,map
        repeat
            diff = math.random(1, #mapdb['tdm'])  -- TODO: user-defined diff, and mode!
            map = mapdb['tdm'][diff][ math.random(1,#mapdb['tdm'][diff])]
        until not roundv or tonumber(map) ~= roundv.mapinfo.code
        new_game_vars.difficulty = diff

        for _,name in ipairs(player_state.shaman) do
            players[name].internal_score = 0
            tfm.exec.setPlayerScore(name, 0)
        end

        local highest = {-1}
        local second_highest = nil
        for _,name in ipairs(player_state.room) do
            if not player_state.shaman[name] then
                players[name].internal_score = players[name].internal_score + 1
                if players[name].internal_score >= highest[1] then
                    second_highest = highest[2]
                    highest[1] = players[name].internal_score
                    highest[2] = name
                end
            end
        end

        tfm.exec.setPlayerScore(highest[2], 100)
        if players[highest[2]].pair then
            tfm.exec.setPlayerScore(players[highest[2]].pair, 100)
        else
            tfm.exec.setPlayerScore(second_highest, 100) -- TODO: prioritise the pre-defined pair or soulmate
        end

        map_sched.load(map)
    end
    
    local function diedwon(type, pn)
        if not roundv then
            return
        end
        local allplayerdead = true
        local allnonshamdead = true
        local allshamdead = true
        for name, p in pairs(tfm.get.room.playerList) do
            if not player_state.dead[name] then allplayerdead = false end
            if not player_state.dead[name] and player_state.non_shaman[name] then allnonshamdead = false end
            if player_state.shaman[name] then
                if not player_state.dead[name] then allshamdead = false end
            end
        end
        if allplayerdead then
            rotate()
        elseif allnonshamdead then
            if type=='won' then tfm.exec.setGameTime(20) end
            if roundv.mapinfo.Opportunist then  -- TODO: nil
                for _,name in pairs(roundv.shaman) do
                    tfm.exec.giveCheese(name)
                    tfm.exec.playerVictory(name)
                end
            end
        elseif allshamdead then
            tfm.exec.setGameTime(20)
        end
    end

    local function died(pn)
        diedwon('died', pn)
    end

    local function won(pn)
        diedwon('won', pn)
    end

    local function timesup()
        rotate()
    end

    rotate_evt = {
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
        ['Welcome'] = {WINDOW_HELP+11, WINDOW_HELP+12},
        ['Contributors'] = {WINDOW_HELP+41, WINDOW_HELP+42},
    }  -- TODO: define somewhere more appropriate..
    -- WARNING: No error checking, ensure that all your windows have all the required attributes (open, close, type, players)
    local windows = {
        [WINDOW_HELP] = {
            open = function(pn, p_data, tab)
                local tabs = {'Welcome','Rules','Commands','Contributors','Close'}
                local tabs_k = {['Welcome']=true,['Rules']=true,['Commands']=true,['Contributors']=true}
                tab = tab or 'Welcome'

                if not tabs_k[tab] then return end
                if not p_data.tab then
                    ui.addTextArea(WINDOW_HELP+1,"",pn,75,40,650,340,0x4c1130,0x4c1130,1,true)  -- the background
                    local buttonstr = {}
                    for _, v in pairs(tabs) do
                        buttonstr[#buttonstr+1] = "<a href='event:help!"..v.."'>"..v.."</a>"
                    end
                    ui.addTextArea(WINDOW_HELP+2, GUI_BTN.."<p align='center'>"..table.concat(buttonstr,'                      '),pn,75,35,650,20,gui_bg,gui_b,gui_o,true)
                    p_data.tab = tab
                else  -- already opened before
                    if help_ta_range[p_data.tab] then
                        for i = help_ta_range[p_data.tab][1], help_ta_range[p_data.tab][1] do
                            ui.removeTextArea(i, pn)
                        end
                    end
                    p_data.tab = tab
                end

                if tab == "Welcome" then
                    local text = [[
<p align="center"><font size='13'><ROSE>Welcome to #shamteam</font></p>
<p align="left"><font size='12'><N>The gameplay is simple: You will pair with another shaman and take turns spawning objects. You earn points at the end of the round depending on mice saved. But be careful! If you make a mistake by spawning when it's not your turn, or dying, you and your partner will lose points! There will be mods that you can enable to make your gameplay a little bit more challenging, and should you win the round, your score will be multiplied accordingly. 
                    ]]
                    ui.addTextArea(WINDOW_HELP+11,text,pn,75,80,650,nil,0,0,0,true)
                elseif tab == "Contributors" then
                    local text = [[
<p align="center"><font size='13'><ROSE>Contributors</font></p>
<p align="left"><font size='12'><N>#shamteam is brought to you by the Academy of Building! It would not be possible without these people:

<J>Casserole#1798<N> - Developer
<J>Emeryaurora#0000<N> - Module inspiration, module designer & mapcrew
<J>Pegasusflyer#0000<N> - Module inspiration, module designer & mapcrew
<J>Tactcat#0000<N> - Module inspiration

Translators:
<J>Pinoyboy#9999<N> (PH)
A full list of mapcrew staff are available via the !mapcrew command. 
                    ]]
                    ui.addTextArea(WINDOW_HELP+41,text,pn,75,80,650,nil,0,0,0,true)
                end

            end,
            close = function(pn, p_data)
                ui.removeTextArea(WINDOW_HELP+1, pn)
                ui.removeTextArea(WINDOW_HELP+2, pn)
                if help_ta_range[p_data.tab] then
                    for i = help_ta_range[p_data.tab][1], help_ta_range[p_data.tab][1] do
                        ui.removeTextArea(i, pn)
                    end
                end
                p_data.tab = nil
            end,
            type = MUTUALLY_EXCLUSIVE,
            players = {}
        },
    }

    sWindow.open = function(window_id, pn, ...)
        if not windows[window_id] then
            return
        elseif not windows[window_id].players[pn] then
            windows[window_id].players[pn] = {images={}, data={}}
        end
        if windows[window_id].type == MUTUALLY_EXCLUSIVE then
            for w_id, w in pairs(windows) do
                if w_id ~= window_id and w.type == MUTUALLY_EXCLUSIVE then
                    sWindow.close(w_id, pn)
                end
            end
        end
        windows[window_id].players[pn].is_open = true
        windows[window_id].open(pn, windows[window_id].players[pn].data, table.unpack(arg))
    end

    sWindow.close = function(window_id, pn)
        if sWindow.isOpened(window_id, pn) then
            windows[window_id].players[pn].is_open = false
            windows[window_id].close(pn, windows[window_id].players[pn].data)
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
    [72] = function(pn) -- h (display help)
        if sWindow.isOpened(WINDOW_HELP, pn) then
            sWindow.close(WINDOW_HELP, pn)
            players[pn].windows.help = false
        else
            sWindow.open(WINDOW_HELP, pn)
        end
    end,
}

cmds = {
    a = {
        func = function(pn, m)
            local msg = m:match("^%a+%s+(.*)")
            if msg then
                tfm.exec.chatMessage(string.format("<ROSE>[Shamteam Moderation] %s", msg))
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
                        args[#args+1] = arg:match('^"(.*)"$'):gsub('&lt;', '<'):gsub('&gt;', '>')
                    elseif arg:find('^"(.*)') then
                        buildstring[1] = true
                        buildstring[2] = arg:match('^"(.*)'):gsub('&lt;', '<'):gsub('&gt;', '>')
                    elseif arg:find('(.*)"$') then
                        buildstring[1] = false
                        args[#args+1] = buildstring[2] .. " " .. arg:match('(.*)"$'):gsub('&lt;', '<'):gsub('&gt;', '>')
                    elseif buildstring[1] then
                        buildstring[2] = buildstring[2] .. " " .. arg:gsub('&lt;', '<'):gsub('&gt;', '>')
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
            if player_state.shaman[pn] then  -- TODO: both shams must vote!
                rotate_evt.timesup()
            end
        end,
        perms = GROUP_PLAYER
    },
    afk = {
        func = function(pn, m, w1, w2)
            if true then -- TODO
                return
            end
            local target
            if w2 and admins[pn] then target = pFind(w2,pn) else target = pn end
            if target and not afk[target] and not tfm.get.room.playerList[target].isShaman then
                afk[target] = true
                tfm.exec.killPlayer(target)
                tfm.exec.setPlayerScore(target, -5)
                tfm.exec.chatMessage(target.." has been marked afk!")
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
            if w2 then
                local target = pFind(w2)
                if target then  -- TODO: and player is not already paired up
                    tfm.exec.chatMessage("Your request to pair up has been sent to "..target, pn)
                    tfm.exec.chatMessage(pn.." is requesting to pair up with you. Type !accept or !reject to respond.", target)
                end
            end
        end,
        perms = GROUP_PLAYER
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
                if not players[target].request_from then  -- TODO: and player is not already paired up
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
}

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
    local shaman = player_state.shaman[roundv.shaman_turn]
    ui.setShamanName(string.format("<%s>%s's <J>Turn", color, shaman))
end

----- EVENTS
function eventChatCommand(pn, msg)
    local words = string_split(string.lower(msg), "%s")
    if cmds[words[1]] then
        print(players[pn].group.." vs "..cmds[words[1]].perms)
        if not cmds[words[1]].perms or (cmds[words[1]].perms and players[pn].group >= cmds[words[1]].perms) then
            cmds[words[1]].func(pn, msg, table.unpack(words))
        else
            tfm.exec.chatMessage('<R>error: no authority', pn)
        end
    else
       tfm.exec.chatMessage('<R>error: invalid command', pn)
	end
    
end

function eventKeyboard(pn, k, d, x, y)
	if keys[k] then
		keys[k](pn, d, x, y)
	end
end

function eventLoop(elapsed, remaining)
    map_sched.run()
    if not roundv then return end
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
        roundv = nil
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
        shaman_turn = 1,
        difficulty = new_game_vars.difficulty or 0,
        phase = 0,
    }
    new_game_vars = {}
    player_state.dead = { _count = 0 }
    player_state.alive = table_copy(player_state.room)
    player_state.shaman = { _count = 0 }
    player_state.non_shaman = { _count = 0 }
    for name, p in pairs(tfm.get.room.playerList) do
        local tbl = p.isShaman and player_state.shaman or player_state.non_shaman
        player_state.add(tbl, name)
    end

    tfm.exec.setGameTime(180)
    ReadXML()
    ShowMapInfo()
    if player_state.shaman._count == 2 then
        tfm.exec.chatMessage(string.format("<ROSE>Ξ <CH>%s <ROSE>& <font color='#FEB1FC'>%s <ROSE>are now the shaman pair!", player_state.shaman[1], player_state.shaman[2]))
    else
        tfm.exec.chatMessage("<R>Ξ No shaman pair!")
    end
    UpdateTurnUI()
    ui.setMapName("<VI>[TDM] <ROSE>Difficulty "..roundv.difficulty.." - <VP>@"..roundv.mapinfo.code)
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
    for key in pairs(keys) do
		system.bindKeyboard(pn, key, true)
    end
    player_state.add(player_state.room, pn)
    player_state.add(player_state.dead, pn)

    tfm.exec.chatMessage("\t<VP>Ξ Welcome to <b>Team Shaman (TSM)</b> v1.0! Ξ\n<J>Also known as Team Hard Mode, TSM is a building module where dual shamans take turns to spawn objects.\nPress H for more information.\n<R>NOTE: <VP>For development purposes this module will only run Team Divine Mode tentatively. As the module starts picking up shape, we'll gradually implement Team Hard Mode.", pn)

    tfm.exec.setPlayerScore(pn, 0)
    tfm.exec.setShamanMode(pn, 2)  -- Force divine for TDM
end

function eventPlayerDied(pn)
    player_state.remove(player_state.alive, pn)
    player_state.add(player_state.dead, pn)
    rotate_evt.died(pn)
end

function eventPlayerWon(pn, elapsed)
    player_state.remove(player_state.alive, pn)
    player_state.add(player_state.dead, pn)
    rotate_evt.won(pn)
end

function eventPlayerLeft(pn)
    player_state.remove(player_state.room, pn)
    sWindow.clearPlayer(pn)
end

function eventPlayerRespawn(pn)
    player_state.remove(player_state.dead, pn)
    player_state.add(player_state.alive, pn)
end

function eventSummoningStart(pn, type, xPos, yPos, angle)
    if type ~= 0 then
        local rightful_turn = roundv.shaman_turn
        if pn ~= player_state.shaman[rightful_turn] then
            --tfm.exec.chatMessage("<J>Ξ It is not your turn to spawn yet! Take a chill pill!", pn)
        end
    end
end

function eventSummoningEnd(pn, type, xPos, yPos, angle, desc)
    -- AntiLag™ by Leafileaf
    -- TODO: !antilag + dynamic detection
    if false and desc.baseType ~= 17 and desc.baseType ~= 32 then
        tfm.exec.moveObject(desc.id, xPos, yPos, false, 0, 0, false, angle, false)
    end
    if desc.baseType ~= 0 then
        local rightful_turn = roundv.shaman_turn
        if pn ~= player_state.shaman[rightful_turn] then
            tfm.exec.removeObject(desc.id)
            tfm.exec.chatMessage("<J>Ξ It is not your turn to spawn yet ya dummy!", pn)
        else
            roundv.shaman_turn = rightful_turn == 1 and 2 or 1
            UpdateTurnUI()
        end
    end
end

function eventTextAreaCallback(id, pn, cb)
	local params
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
	rotate_evt.rotate()
end

init()
debug.disableEventLog(true)
