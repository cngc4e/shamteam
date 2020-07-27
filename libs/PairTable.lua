local PairTable
do
    local function cnext(tbl, k)
        local v
        k, v = next(tbl, k)
        if k ~= "_len" then 
            return k,v
        else
            k, v = next(tbl, k)
            return k,v
        end
    end
    local PairTableProto = {
        add = function(self, key)
            self[key] = true
            self._len = self._len + 1
        end,
        remove = function(self, key)
            self[key] = nil
            self._len = self._len - 1
        end,
        len = function(self)
            return self._len
        end,
        pairs = function(self)
            return cnext, self, nil
        end,
    }
    PairTableProto.__index = PairTableProto
    PairTable = {
        new = function(self, t)
            local tbl
            if t then
                tbl = {}
                local len = 0
                for k, v in cnext, t do
                    tbl[k] = v
                    len = len + 1
                end
                tbl._len = len
            else
                tbl = { _len = 0 }
            end
            return setmetatable(tbl, PairTableProto)
        end,
    }
end
