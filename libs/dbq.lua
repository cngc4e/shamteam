-- Database Query by Leafileaf
do
	local dbq = {}
	dbq.VERSION = "1.0"
	
	-- notes on dbq
	-- pass in an array during initialisation containing an array of structured objects, according to the schema
	-- schema defines primary key(s) and gives query optimisation information required to precompute certain anticipated common queries
	
	-- enums
	dbq.COMPARATOR_EQ = 1
	dbq.COMPARATOR_LT = 2
	dbq.COMPARATOR_LE = 3
	dbq.COMPARATOR_GT = 4
	dbq.COMPARATOR_GE = 5
	
	-- static functions
	dbq.EQ = function( column_name , value ) -- tests equality for value
		return {test="eq",column_name=column_name,value=value}
	end
	dbq.LT = function( column_name , value ) -- tests column less than value
		return {test="lt",column_name=column_name,value=value}
	end
	dbq.LE = function( column_name , value ) -- tests column less than or equal value
		return {test="le",column_name=column_name,value=value}
	end
	dbq.GT = function( column_name , value ) -- tests column greater than value
		return {test="gt",column_name=column_name,value=value}
	end
	dbq.GE = function( column_name , value ) -- tests column greater than or equal value
		return {test="ge",column_name=column_name,value=value}
	end
	dbq.WITHIN = function( column_name , lower_value , upper_value ) -- tests lower_value <= column <= upper_value
		return {test="sw",column_name=column_name,lower=lower_value,upper=upper_value}
	end
	dbq.AND = function( ... ) -- combines multiple conditions
		return {results="intersection",operations={...}}
	end
	dbq.OR = function( ... ) -- either/or conditions
		return {results="union",operations={...}}
	end
	
	-- non-static functions
	dbq.init = function( db , arr ) -- db dbqobject, arr array of rows
		db.__inited = true
		db.__precomp = { point = {} , pointsize = {} , range = {} , strings = {} } -- strings is a map of string->number
		db.__db = {}
		db.__all = {}
		db.__size = 0
		for i = 1 , #arr do
			db.__db[i] = arr[i]
			db.__all[arr[i]] = true
			db.__size = db.__size + 1
		end
	end
	dbq.point_index = function( db , column_name ) -- does a point index of column_name
		if not db.__inited then error("dbq: point_index: call dbqobject:init() first",2) end
		local index = {}
		local valsize = {}
		for i , obj in ipairs( db.__db ) do
			if index[obj[column_name]] then
				index[obj[column_name]][obj] = true
				valsize[obj[column_name]] = valsize[obj[column_name]] + 1
			else
				index[obj[column_name]] = { [obj] = true }
				valsize[obj[column_name]] = 1
			end
		end
		db.__precomp.point[column_name] = index
		db.__precomp.pointsize[column_name] = valsize
		return true
	end
	dbq.range_index = function( db , column_name ) -- does a range index of column_name
		-- implement later, skip list not present
	end
	local function query( db , query_pattern , result_set , result_set_size )
		local result_set = result_set or db.__all
		local result_set_size = result_set_size or db.__size
		local ret = {}
		local retlen = 0
		if query_pattern.results then -- operation on multiple result sets
			if query_pattern.results == "intersection" then
				for i , qp in ipairs( query_pattern.operations ) do
					result_set , result_set_size = query( db , qp , result_set , result_set_size )
				end
				ret , retlen = result_set , result_set_size
			elseif query_pattern.results == "union" then -- unions are fucking expensive, save them until last
				for i , qp in ipairs( query_pattern.operations ) do
					local crs = query( db , qp , result_set , result_set_size )
					for obj in pairs( crs ) do
						if not ret[obj] then
							ret[obj] = true
							retlen = retlen + 1
						end
					end
				end
			else
				error("dbq: query: query_pattern is invalid (bad set operation)")
			end
		elseif query_pattern.test then -- single-column test
			if query_pattern.test == "eq" then -- point query
				if db.__precomp.point[query_pattern.column_name] then -- excellent, indexed!
					local opres = db.__precomp.point[query_pattern.column_name][query_pattern.value]
					local opressz = db.__precomp.pointsize[query_pattern.column_name][query_pattern.value]
					if opres then
						if opressz <= result_set_size then -- perform intersection using the smaller set as a base
							for obj in pairs( opres ) do
								if result_set[obj] then
									ret[obj] = true
									retlen = retlen + 1
								end
							end
						else -- the original result set is smaller than the precomputed result set for this operation
							for obj in pairs( result_set ) do
								if opres[obj] then
									ret[obj] = true
									retlen = retlen + 1
								end
							end
						end
					end
				else -- time to go through the whole potential result set
					for obj in pairs( result_set ) do
						if obj[query_pattern.column_name] == query_pattern.value then
							ret[obj] = true
							retlen = retlen + 1
						end
					end
				end
			else
				if query_pattern.test == "lt" then
				elseif query_pattern.test == "le" then
				elseif query_pattern.test == "gt" then
				elseif query_pattern.test == "ge" then
				elseif query_pattern.test == "sw" then
				else
					error("dbq: query: query_pattern is invalid (bad test)")
				end
			end
		else
			error("dbq: query: query_pattern is invalid (bad operation)")
		end
		
		return ret , retlen
	end
	dbq.query = function( db , query_pattern )
		if not db.__inited then error("dbq: query: call dbqobject:init() first",2) end
		local result_set = query( db , query_pattern )
		local ret = {}
		for obj in pairs( result_set ) do
			ret[#ret+1] = obj
		end
		return ret
	end
	
	-- instantiation
	local mt = { __index = dbq,
		__call = dbq.query,
	}
	dbq.new = function()
		return setmetatable( {} , mt )
	end
	
	_G.dbq = dbq
end
