-- Module data helper
local MDHelper = {}
do
    local FILE_NUMBER = MODULE_ID
    local FILE_LOAD_INTERVAL = 60005  -- in milliseconds
    local LATEST_MD_VER = 1

    local db_cache = {
        maps = {},
        banned = {},
        module_log = {},
    }
    local db_commits = {}
    local inform_filesave = {}
    local module_data_loaded = false
    local next_module_sync = nil  -- when the next module data syncing can occur

    -- DB operations/commits
    MDHelper.OP_ADD_MAP = 1
    MDHelper.OP_REMOVE_MAP = 2
    MDHelper.OP_UPDATE_MAP_HARD = 3
    MDHelper.OP_UPDATE_MAP_DIV = 4
    MDHelper.OP_ADD_MAP_COMPLETION = 5
    MDHelper.OP_ADD_BAN = 6
    MDHelper.OP_REMOVE_BAN = 7
    MDHelper.OP_REPLACE_MAPS = 8
    MDHelper.OP_ADD_MODULE_LOG = 9

    -- Module data DB2 schemas
    local MD_SCHEMA = {
        [1] = {
            VERSION = 1,
            db2.VarDataList{ key="maps", size=10000, datatype=db2.Object{schema={
                db2.UnsignedInt{ key="code", size=4 },
                db2.UnsignedInt{ key="hard_diff", size=1 },
                db2.UnsignedInt{ key="div_diff", size=1 },
                db2.UnsignedInt{ key="completed", size=5 },
                db2.UnsignedInt{ key="rounds", size=5 },
            }}},
            db2.VarDataList{ key="banned", size=1000, datatype=db2.Object{schema={
                db2.VarChar{ key="name", size=25 },
                db2.VarChar{ key="reason", size=100 },
                db2.UnsignedInt{ key="time", size=5 },  -- in seconds
            }}},
            db2.VarDataList{ key="module_log", size=1000, datatype=db2.Object{schema={
                db2.VarChar{ key="committer", size=25 },
                db2.UnsignedInt{ key="time", size=5 },  -- in seconds
                db2.Switch{ key="op", typekey = "op_id", typedatatype = db2.UnsignedInt{ size = 2 }, datatypemap = {
                    [MDHelper.OP_ADD_MAP] = db2.Object{schema={
                        db2.UnsignedInt{ key="code", size=4 },
                    }},
                    [MDHelper.OP_REMOVE_MAP] = db2.Object{schema={
                        db2.UnsignedInt{ key="code", size=4 },
                    }},
                    [MDHelper.OP_UPDATE_MAP_HARD] = db2.Object{schema={
                        db2.UnsignedInt{ key="code", size=4 },
                        db2.UnsignedInt{ key="old_diff", size=1 },
                        db2.UnsignedInt{ key="diff", size=1 },
                    }},
                    [MDHelper.OP_UPDATE_MAP_DIV] = db2.Object{schema={
                        db2.UnsignedInt{ key="code", size=4 },
                        db2.UnsignedInt{ key="old_diff", size=1 },
                        db2.UnsignedInt{ key="diff", size=1 },
                    }},
                    [MDHelper.OP_ADD_BAN] = db2.Object{schema={
                        db2.VarChar{ key="name", size=25 },
                    }},
                    [MDHelper.OP_REMOVE_BAN] = db2.Object{schema={
                        db2.VarChar{ key="name", size=25 },
                    }},
                    [MDHelper.OP_REPLACE_MAPS] = db2.Object{schema={}},
                }},
            }}},
        }
    }

    MDHelper.MERGE_OK = 0
    MDHelper.MERGE_NOTHING = 1
    MDHelper.MERGE_FAIL = 2

    local operations = {
        [MDHelper.OP_ADD_MAP] = {
            init = function(self, mapcode)
                self.mapcode = mapcode
            end,
            merge = function(self, db)
                local maps = db.maps
                local found = false
                for i = 1, #maps do
                    if maps[i].code == self.mapcode then
                        found = true
                        break
                    end
                end
                if found then
                    return MDHelper.MERGE_NOTHING, "@"..self.mapcode.." already exists in the database."
                end
                maps[#maps+1] = {code=self.mapcode, hard_diff=0, div_diff=0, completed=0, rounds=0}
                return MDHelper.MERGE_OK, "@"..self.mapcode.." successfully added."
            end,
            logobject = function(self)
                return {
                    code = self.mapcode
                }
            end,
            changelog = function(log)
                return "Added @"..log.code
            end,
        },
        [MDHelper.OP_REMOVE_MAP] = {
            init = function(self, mapcode)
                self.mapcode = mapcode
            end,
            merge = function(self, db)
                local maps = db.maps
                local found = false
                for i = 1, #maps do
                    if maps[i].code == self.mapcode then
                        table.remove(maps, i)
                        found = true
                        break
                    end
                end
                if not found then
                    return MDHelper.MERGE_NOTHING, "@"..self.mapcode.."  does not exist in the database."
                end
                return MDHelper.MERGE_OK, "@"..self.mapcode.." successfully removed."
            end,
            logobject = function(self)
                return {
                    code = self.mapcode
                }
            end,
            changelog = function(log)
                return "Removed @"..log.code
            end,
        },
        [MDHelper.OP_UPDATE_MAP_HARD] = {
            init = function(self, mapcode, diff)
                self.mapcode = mapcode
                self.diff = diff
            end,
            merge = function(self, db)
                local maps = db.maps
                local found = false
                for i = 1, #maps do
                    if maps[i].code == self.mapcode then
                        if not self.old_diff then
                            self.old_diff = maps[i].hard_diff
                        end
                        maps[i].hard_diff = self.diff
                        found = true
                        break
                    end
                end
                if not found then
                    return MDHelper.MERGE_NOTHING, "@"..self.mapcode.." does not exist in the database."
                end
                return MDHelper.MERGE_OK, "@"..self.mapcode.." Hard difficulty updated to "..self.diff
            end,
            logobject = function(self)
                return {
                    code = self.mapcode,
                    old_diff = self.old_diff or 0,
                    diff = self.diff
                }
            end,
            changelog = function(log)
                return "Updated @"..log.code.." - Hard difficulty: "..log.old_diff.." -&gt; "..log.diff
            end,
        },
        [MDHelper.OP_UPDATE_MAP_DIV] = {
            init = function(self, mapcode, diff)
                self.mapcode = mapcode
                self.diff = diff
            end,
            merge = function(self, db)
                local maps = db.maps
                local found = false
                for i = 1, #maps do
                    if maps[i].code == self.mapcode then
                        if not self.old_diff then
                            self.old_diff = maps[i].div_diff
                        end
                        maps[i].div_diff = self.diff
                        found = true
                        break
                    end
                end
                if not found then
                    return MDHelper.MERGE_NOTHING, "@"..self.mapcode.." does not exist in the database."
                end
                return MDHelper.MERGE_OK, "@"..self.mapcode.." Divine difficulty updated to "..self.diff
            end,
            logobject = function(self)
                return {
                    code = self.mapcode,
                    old_diff = self.old_diff or 0,
                    diff = self.diff
                }
            end,
            changelog = function(log)
                return "Updated @"..log.code.." - Divine difficulty: "..(log.old_diff or 0).." -&gt; "..log.diff
            end,
        },
        [MDHelper.OP_ADD_MAP_COMPLETION] = {
            init = function(self, mapcode, completed)
                self.mapcode = mapcode
                self.completed = tonumber(completed)
            end,
            merge = function(self, db)
                local maps = db.maps
                local found = false
                for i = 1, #maps do
                    if maps[i].code == self.mapcode then
                        found = maps[i]
                        break
                    end
                end
                if not found then
                    return MDHelper.MERGE_NOTHING, "@"..self.mapcode.." does not exist in the database."
                end

                if self.completed then
                    found.completion = found.completion + 1
                end
                found.rounds = found.rounds + 1
                return MDHelper.MERGE_OK
            end,
            logobject = function(self)
                return nil
            end,
            PASSIVE_ON_NOR = true
        },
        [MDHelper.OP_ADD_BAN] = {
            init = function(self, pn, reason)
                self.pn = pn
                self.reason = reason or ""
            end,
            merge = function(self, db)
                local banned = db.banned
                for i = 1, #banned do
                    if banned[i].name == self.pn then
                        found = true
                        break
                    end
                end
                if found then
                    return MDHelper.MERGE_NOTHING, self.pn.." is already banned."
                end

                banned[#banned+1] = {
                    name = self.pn,
                    reason = self.reason,
                    time = math.floor(os.time()/1000)
                }
                return MDHelper.MERGE_OK, self.pn.." has been added to the ban list."
            end,
            logobject = function(self)
                return {
                    name = self.pn
                }
            end,
            changelog = function(log)
                return "Permanently banned "..log.name
            end,
        },
        [MDHelper.OP_REMOVE_BAN] = {
            init = function(self, pn)
                self.pn = pn
            end,
            merge = function(self, db)
                local banned = db.banned
                local found = false
                for i = 1, #banned do
                    if banned[i].name == self.pn then
                        table.remove(banned, i)
                        found = true
                        break
                    end
                end
                if not found then
                    return MDHelper.MERGE_NOTHING, "No existing player was banned."
                end
                return MDHelper.MERGE_OK, self.pn.." was removed from the ban list."
            end,
            logobject = function(self)
                return {
                    name = self.pn
                }
            end,
            changelog = function(log)
                return "Revoked permanent ban on "..log.name
            end,
        },
        [MDHelper.OP_REPLACE_MAPS] = {
            init = function(self, map_table)
				self.map_table = map_table
            end,
            merge = function(self, db)
                db.maps = self.map_table
                return MDHelper.MERGE_OK
            end,
            logobject = function(self)
                return {}
            end,
            changelog = function(log)
                return "Mass update map database"
            end,
        },
        [MDHelper.OP_ADD_MODULE_LOG] = {
            init = function(self, committer, op_id, logobj)
                local nlogobj = table_copy(logobj)
                nlogobj.op_id = op_id
                self.logobj = nlogobj
                self.committer = committer
                self.time = math.floor(os.time()/1000)
            end,
            merge = function(self, db)
                local md_log = db.module_log
                local entry = {
                    committer = self.committer,
                    time = self.time,
                    op = self.logobj
                }
                md_log[#md_log+1] = entry
                return MDHelper.MERGE_OK
            end,
            logobject = function(self)
                return nil
            end,
        },
    }

    MDHelper.commit = function(pn, op_id, a1, a2, a3, a4)
        local op = operations[op_id]
        if op then
            local op_mt = setmetatable({}, { __index = {
                init = op.init,
                merge = op.merge,
                logobject = op.logobject,
                op_id = op_id
            }})
            op_mt:init(a1, a2, a3, a4)
            local status, result = op_mt:merge(db_cache)
            if status ~= MDHelper.MERGE_OK then
                return status, result or "Merge unsuccessful"
            else
                local logobj = op_mt:logobject()
                if logobj then
                    -- add module log
                    MDHelper.commit(nil, MDHelper.OP_ADD_MODULE_LOG, pn, op_id, logobj)
                end
                -- don't schedule and sync commit if the operation specifies to be passive in non-official rooms
                if is_official_room or not op_mt.PASSIVE_ON_NOR then
                    -- Schedule the commit to be done again during the next syncing
                    db_commits[#db_commits+1] = { op_mt, pn }
                end
                return status, result or ""
            end
        else
            return MDHelper.MERGE_FAIL, "Invalid operation."
        end
    end

    MDHelper.getTable = function(tbl_name)
        return db_cache[tbl_name]
    end

    MDHelper.getMapInfo = function(mapcode)
        mapcode = int_mapcode(mapcode)
        if not mapcode then return end
        local maps = MDHelper.getTable("maps")
        for i = 1, #maps do
            if maps[i].code == mapcode then
                return maps[i]
            end
        end
        return nil
    end

    MDHelper.getChangelog = function(logobj)
        if type(logobj) == "table" then
            local op_id = logobj.op_id
            if op_id and operations[op_id].changelog then
                return operations[op_id].changelog(logobj)
            end
        end
    end

    local save = function(db)
        local encoded_md = db2.encode(MD_SCHEMA[LATEST_MD_VER], db)
        system.saveFile(encoded_md, FILE_NUMBER)
        print("module data save")
    end

    MDHelper.getMdLoaded = function()
        return module_data_loaded
    end

    MDHelper.eventFileLoaded = function(file, data)
        if tonumber(file) ~= FILE_NUMBER then return end
        if #data == 0 then
			print("init and save default db")
            save(db_cache)
        else
            local new_db = db2.decode(MD_SCHEMA, data)
            local commit_sz = #db_commits
            if commit_sz > 0 then
                for i = 1, commit_sz do
                    local op = db_commits[i][1]
                    local committer = db_commits[i][2]
                    local status, result = op:merge(new_db)
                    print("new db: did "..op.op_id)
                    if status ~= MDHelper.MERGE_OK then
                        print("Error occurred while merging on the new database: "..result or "No reason")
                    elseif committer then
                        inform_filesave[committer] = true
                    end
                end
                save(new_db)
                db_commits = {}
            end
            db_cache = new_db
        end
        if _G.eventFileParsed then
            _G.eventFileParsed()
        end
        module_data_loaded = true
        print("module data load")
    end

    MDHelper.eventFileSaved = function(file)
        if tonumber(file) ~= FILE_NUMBER then return end
        for name in pairs(inform_filesave) do
            tfm.exec.chatMessage("<J>All changes have been successfully saved to the database!", name)
        end
        inform_filesave = {}
    end

    MDHelper.trySync = function()
        if not next_module_sync or os.time() >= next_module_sync then
            system.loadFile(FILE_NUMBER)
            next_module_sync = os.time() + FILE_LOAD_INTERVAL
        end
    end
end
