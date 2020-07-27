-- Player data helper
local PDHelper
do
    -- Global player data structure - SHARED ACROSS MODULES; DO NOT CHANGE
    local GLOBAL_PD_SCHEMA = {
        db2.VarDataList{ key="modules", size=128, datatype=db2.Object{schema={
            db2.UnsignedInt{ key="id", size=1 },
            db2.VarChar{ key="encoded", size=2097152 },
        }}},
    }

    -- Nested module-specific player data structure
    local MODULE_PD_SCHEMA = {
        [1] = {
            VERSION = 1,
            db2.UnsignedInt{ key="exp", size=7 },  -- experience points
            db2.UnsignedInt{ key="toggles", size=4 },  -- player options bit set (togglebles)
        }
    }
    local LATEST_PD_VER = 1
    local SAVE_PD_WAITTIME = 5000  -- in milliseconds, minimum waiting time for saving player data when saving is requested via md.scheduleSave

    local save_at = {}
    local PDOps = {}

    ----- Player data methods
    --- Module specific
    local function set_toggle(self, toggle_id, on)
        if on == nil then
            on = true
        end
        local pd = self.module_pd
        local op = on and bor or bnot
        pd.toggles = op(pd.toggles, toggle_id)
    end

    local function flip_toggle(self, toggle_id)
        local pd = self.module_pd
        pd.toggles = bxor(pd.toggles, toggle_id)
    end

    local function get_toggle(self, toggle_id)
        local pd = self.module_pd
        return band(pd.toggles, toggle_id) ~= 0
    end

    --- Saving / Loading
    local schedule_save = function(self)
        local pn = self.pn
        if not save_at[pn] then
            save_at[pn] = os.time() + SAVE_PD_WAITTIME
        end
    end

    local save_now = function(self)
        local global_pd = self.global_pd
        local pn = self.pn
        local modules = global_pd.modules
        local found = nil
        for i = 1, #modules do
            if modules[i].id == MODULE_ID then
                found = modules[i]
                break
            end
        end
        local encoded_module_pd = db2.encode(MODULE_PD_SCHEMA[LATEST_PD_VER], self.module_pd)
        if found then
            -- Existing module specific player data, just update it
            found.encoded = encoded_module_pd
            print("save existing "..pn)
        else
            -- Initialise fresh module specific player data
            modules[#modules+1] = {
                id = MODULE_ID,
                encoded = encoded_module_pd
            }
            print("save new "..pn)
        end
        local encoded_global_pd = db2.encode(GLOBAL_PD_SCHEMA, global_pd)
        system.savePlayerData(pn, encoded_global_pd)
    end

    local load_now = function(self, data)
        local pn = self.pn
        local global_pd = db2.decode(GLOBAL_PD_SCHEMA, data)
        local modules = global_pd.modules
        self.global_pd = global_pd
    
        local encoded_module_pd = nil
        for i = 1, #modules do
            if modules[i].id == MODULE_ID then
                encoded_module_pd = modules[i].encoded
                break
            end
        end
        if encoded_module_pd then
            self.module_pd = db2.decode(MODULE_PD_SCHEMA, encoded_module_pd)
            print("load existing "..pn)
        end
    end

    ----- Helper methods
    local new = function(pn, default_pd)
        local data = {
            pn = pn,
            global_pd = {
                modules = {}
            },
            module_pd = default_pd,
        }
        return setmetatable(data, PDOps)
    end

    local check_saves = function()
        local now = os.time()
        local yeetaway = { _len=0 }
        for name, at in pairs(save_at) do
            if now >= at then
                save_now(playerData[name])
                yeetaway[yeetaway._len + 1] = name
                yeetaway._len = yeetaway._len + 1
            end
        end
        for i = 1, yeetaway._len do
            save_at[yeetaway[i]] = nil
        end
    end

    PDOps = {
        setToggle = set_toggle,
        flipToggle = flip_toggle,
        getToggle = get_toggle,
        scheduleSave = schedule_save,
        save = save_now,
        load = load_now,
    }
    PDOps.__index = PDOps

    PDHelper = {
        new = new,
        checkSaves = check_saves,
    }
end
