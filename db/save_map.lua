
local db2
do
    -- database2
    -- serialisating objects with known structure
    -- by Leafileaf

    ----- IMPORTANT -----
    -- database2 can decode and encode database1 strings, but encoding to db1 is discouraged

	db2 = {}
	db2.VERSION = "1.3"
	
	local error = error
	
	local log2 = math.log(2)
	
	db2.info = 0
	-- INFO ENUMS --
	db2.INFO_OK = 0
	db2.INFO_INTERNALERROR = -1 -- uh oh!
	db2.INFO_ENCODE_DATAERROR = 1 -- invalid parameter
	db2.INFO_ENCODE_DATASIZEERROR = 2 -- data is too large to store
	db2.INFO_ENCODE_GENERICERROR = 3
	db2.INFO_DECODE_BADSTRING = 4 -- not a db2 string
	db2.INFO_DECODE_MISSINGSCHEMA = 5 -- schema with given version doesn't exist
	db2.INFO_DECODE_CORRUPTSTRING = 6 -- end of parsing but not end of string or vice versa
	db2.INFO_DATATYPE_ERROR = 7 -- errors when initialising datatypes
	db2.INFO_GENERICERROR = 8
	db2.INFO_DECODE_GENERICERROR = 9
	-- END INFO ENUMS --
	
	local lbtn = function( str , b ) -- big-endian byte to number
		local n = 0
		local mult = 2^b
		for i = 1 , str:len() do
			n = n * mult + str:byte( i )
		end
		return n
	end
	local lntb = function( num , b , expected_length ) -- legacy; shouldn't be needed here actually
		local str = ""
		local mult = 2^b
		while num ~= 0 do
			local x = num % mult
			str = string.char( x ) .. str
			num = math.floor( num / mult )
		end
		while str:len() < expected_length do str = string.char( 0 ) .. str end
		return str
	end
	local bytestonumber = function( str , bpb )
		local n = 0
		local mult = 2^bpb
		local strlen = str:len()
		local bytes = {str:byte(1,strlen)}
		for i = 1 , strlen do
			n = n + bytes[i]*(mult^(i-1))
		end
		return n
	end
	local strchar = {}
	for i = 0 , 2^8 - 1 do
		strchar[i] = string.char( i )
	end
	local numbertobytes = function( num , bpb , len )
		local t = {}
		local mult = 2^bpb
		for i = 1 , len do -- ensures no overflow, and forces length to be exactly len
			local x = num % mult
			t[i] = strchar[x]
			num = ( num - num % mult ) / mult -- floored divide
		end
		return table.concat( t )
	end
	local islegacy = false
	
	--local datatypeCopy = function(  ) ------- WIP
	
	local Datatype = function( dtinfo )
		
		if type(dtinfo) ~= "table" or not ( dtinfo.init and dtinfo.encode and dtinfo.decode ) then
			db2.info = -1
			return error( "db2: internal error: incorrect parameters to Datatype" , 2 )
		end
		if type(dtinfo.init) ~= "function" or type(dtinfo.encode) ~= "function" or type(dtinfo.decode) ~= "function" then
			db2.info = -1
			return error( "db2: internal error: invalid type of parameters to Datatype" , 2 )
		end
		local init , encode , decode = dtinfo.init , dtinfo.encode , dtinfo.decode
		local mt
		local r = function( params )
			local o = setmetatable( {key=params.key} , mt )
			init( o , params )
			return o
		end
		mt = { __index = { encode = encode , decode = decode , basetype = r } }
		
		
		return r
	end
	
	db2.UnsignedInt = Datatype{
		init = function( o , params )
			db2.info = 0
			
			local bytes = params.size
			if type(bytes) ~= "number" then db2.info = 7 return error( "db2: UnsignedInt: Expected number, found " .. type(bytes) , 2 ) end
			if math.floor(bytes) ~= bytes then db2.info = 7 return error( "db2: UnsignedInt: Expected integer" , 2 ) end
			
			o.__bytes = bytes
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "number" then db2.info = 1 return error( "db2: UnsignedInt: encode: Expected number, found " .. type(data) ) end
			if math.floor(data) ~= data or data < 0 then db2.info = 1 return error( "db2: UnsignedInt: encode: Can only encode unsigned integers" ) end
			return numbertobytes( data , bpb , o.__bytes )
		end,
		decode = function( o , enc , ptr , bpb )
			local r = bytestonumber( enc:sub( ptr , ptr + o.__bytes - 1 ) , bpb )
			ptr = ptr + o.__bytes
			return r , ptr
		end
	}
	
	db2.Float = Datatype{ -- single-precision floats -- https://stackoverflow.com/questions/14416734/lua-packing-ieee754-single-precision-floating-point-numbers
		init = function( o , params )
			db2.info = 0
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "number" then db2.info = 1 return error( "db2: Float: encode: Expected number, found " .. type(data) ) end
			
			local fullbits = 2^bpb - 1 -- 1111111(1)
			local msb = 2^(bpb-1) -- 1000000(0)
			local fmsb = msb - 1 -- 0111111(1)
			local bytesep = 2^bpb
			
			if data == 0 then
				return string.char( 0 , 0 , 0 , 0 )
			elseif data ~= data then
				return string.char( fullbits , fullbits , fullbits , fullbits ) -- nan
			else
				local sign = 0
				if data < 0 then
					sign = msb
					data = -data
				end
				
				local mant , expo = math.frexp( data )
				
				expo = expo + fmsb
				if expo < 0 then -- small number
					mant = math.ldexp( mant , expo - 1 )
					expo = 0
				elseif expo > 0 then
					if expo >= fullbits then
						return string.char( 0 , 0 , msb , sign + fmsb )
					elseif expo == 1 then
						expo = 0
					else
						mant = mant * 2 - 1
						expo = expo - 1
					end
				end
				mant = math.floor( math.ldexp( mant , 3 * bpb - 1 ) + 0.5 ) -- round to nearest integer mantissa
				return string.char(
					mant % bytesep,
					math.floor( mant / bytesep ) % bytesep,
					( expo % 2 ) * msb + math.floor( mant / bytesep / bytesep ),
					sign + math.floor( expo / 2 )
				)
			end
		end,
		decode = function( o , enc , ptr , bpb )
			local b4 , b3 , b2 , b1 = enc:byte( ptr , ptr + 3 )
			ptr = ptr + 4
			
			local fullbits=  2^bpb - 1
			local msb = 2^(bpb-1)
			local fmsb = msb - 1
			local bytesep = 2^bpb
			
			local expo = ( b1 % msb ) * 2 + math.floor( b2 / msb )
			local mant = math.ldexp( ( ( b2 % msb ) * bytesep + b3 ) * bytesep + b4 , -( 3 * bpb - 1 ) )
			
			if expo == fullbits then
				if mant > 0 then
					return 0/0
				else
					mant = math.huge
					expo = fmsb
				end
			elseif expo > 0 then
				mant = mant + 1
			else
				expo = expo + 1
			end
			if b1 >= msb then
				mant = -mant
			end
			return math.ldexp( mant , expo - fmsb ) , ptr
		end
	}
	
	db2.Double = Datatype{
		init = function( o , params )
			db2.info = 0
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "number" then db2.info = 1 return error( "db2: Double: encode: Expected number, found " .. type(data) ) end
			
			local fullbits = 2^bpb - 1 -- 1111111(1)
			local msb = 2^(bpb-1) -- 1000000(0)
			local fmsb = msb - 1 -- 0111111(1)
			local fullexpo = 2^(bpb+3) - 1 -- 1111111111(1), full bits of expo field
			local mpe = 2^(bpb+2) - 1 -- 0111111111(1), making expo positive
			local top4 = fullbits - ( 2^(bpb-4) - 1 ) -- 1111000(0), top 4 bits filled
			local top4msb = 2^(bpb-4) -- 0001000(0), encoding expo
			local bytesep = 2^bpb
			
			if data == 0 then
				return string.char( 0 , 0 , 0 , 0 , 0 , 0 , 0 , 0 )
			elseif data ~= data then
				return string.char( fullbits , fullbits , fullbits , fullbits , fullbits , fullbits , fullbits , fullbits ) -- nan
			else
				local sign = 0
				if data < 0 then
					sign = msb
					data = -data
				end
				
				local mant , expo = math.frexp( data )
				
				expo = expo + mpe
				if expo < 0 then -- small number
					mant = math.ldexp( mant , expo - 1 )
					expo = 0
				elseif expo > 0 then
					if expo >= fullexpo then
						return string.char( 0 , 0 , 0 , 0 , 0 , 0 , top4 , sign + fmsb )
					elseif expo == 1 then
						expo = 0
					else
						mant = mant * 2 - 1
						expo = expo - 1
					end
				end
				mant = math.floor( math.ldexp( mant , 7 * bpb - 4 ) + 0.5 ) -- round to nearest integer mantissa
				return numbertobytes( mant , bpb , 6 ) .. string.char(
					( expo % 16 ) * top4msb + math.floor( mant / ( bytesep ^ 6 ) ),
					sign + math.floor( expo / 16 )
				)
			end
		end,
		decode = function( o , enc , ptr , bpb )
			local b2 , b1 = enc:byte( ptr + 6 , ptr + 7 )
			local b38 = enc:sub( ptr , ptr + 5 )
			ptr = ptr + 8
			
			local fullbits=  2^bpb - 1
			local msb = 2^(bpb-1)
			local fmsb = msb - 1
			local fullexpo = 2^(bpb+3) - 1
			local mpe = 2^(bpb+2) - 1
			local top4 = fullbits - ( 2^(bpb-4) - 1 )
			local top4msb = 2^(bpb-4)
			local bytesep = 2^bpb
			
			local expo = ( b1 % msb ) * 16 + math.floor( b2 / top4msb )
			local mant = math.ldexp( ( b2 % top4msb ) * ( bytesep ^ 6 ) + bytestonumber( b38 , bpb ) , -( 7 * bpb - 4 ) )
			
			if expo == fullexpo then
				if mant > 0 then
					return 0/0
				else
					mant = math.huge
					expo = fmsb
				end
			elseif expo > 0 then
				mant = mant + 1
			else
				expo = expo + 1
			end
			if b1 >= msb then
				mant = -mant
			end
			return math.ldexp( mant , expo - mpe ) , ptr
		end
	}
	
	db2.VarChar = Datatype{
		init = function( o , params )
			db2.info = 0
			
			local sz , nbits = params.size , math.log( params.size + 1 ) / log2
			if type(sz) ~= "number" then db2.info = 7 return error( "db2: VarChar: Expected number, found " .. type(sz) , 2 ) end
			if math.floor(sz) ~= sz then db2.info = 7 return error( "db2: VarChar: Expected integer" , 2 ) end
			
			o.__sz , o.__nbits = sz , nbits
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "string" then db2.info = 1 return error( "db2: VarChar: encode: Expected string, found " .. type(data) ) end
			if data:len() > o.__sz then db2.info = 2 return error( "db2: VarChar: encode: Data is bigger than is allocated for" ) end
			local lsz = math.ceil(o.__nbits/bpb) -- length of size
			return numbertobytes( data:len() , bpb , lsz ) .. data
		end,
		decode = function( o , enc , ptr , bpb )
			local lsz = math.ceil(o.__nbits/bpb)
			local len = bytestonumber( enc:sub( ptr , ptr + lsz - 1 ) , bpb )
			ptr = ptr + lsz + len
			return enc:sub( ptr - len , ptr - 1 ) , ptr
		end
	}
	
	db2.FixedChar = Datatype{
		init = function( o , params )
			db2.info = 0
			
			local sz = params.size
			if type(sz) ~= "number" then db2.info = 7 return error( "db2: FixedChar: Expected number, found " .. type(sz) , 2 ) end
			if math.floor(sz) ~= sz then db2.info = 7 return error( "db2: FixedChar: Expected integer" , 2 ) end
			
			o.__sz = sz
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "string" then db2.info = 1 return error( "db2: FixedChar: encode: Expected string, found " .. type(data) ) end
			if data:len() > o.__sz then db2.info = 2 return error( "db2: FixedChar: encode: Data is bigger than is allocated for" ) end
			return data .. string.char(0):rep( o.__sz - data:len() )
		end,
		decode = function( o , enc , ptr , bpb )
			local r = enc:sub( ptr , ptr + o.__sz - 1 )
			ptr = ptr + o.__sz
			return r , ptr
		end
	}
	
	db2.Bitset = Datatype{
		init = function( o , params )
			db2.info = 0
			
			local sz = params.size
			if type(sz) ~= "number" then db2.info = 7 return error( "db2: Bitset: Expected number, found " .. type(sz) , 2 ) end
			if math.floor(sz) ~= sz then db2.info = 7 return error( "db2: Bitset: Expected integer" , 2 ) end
			
			o.__sz = sz
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "table" then db2.info = 1 return error( "db2: Bitset: encode: Expected table, found " .. type(data) ) end
			if #data > o.__sz then db2.info = 2 return error( "db2: Bitset: encode: Data is bigger than is allocated for" ) end
			local r = {}
			local nr = 0
			for i = 1 , math.ceil( o.__sz / bpb ) do
				local n = 0
				for j = 1 , bpb do
					n = n + ( data[(i-1)*bpb+j] and 1 or 0 ) * 2^(j-1)
				end
				nr = nr + 1
				r[nr] = strchar[n]
			end
			return table.concat( r )
		end,
		decode = function( o , enc , ptr , bpb )
			local r = {}
			local nr = 0
			local bssz = math.ceil( o.__sz / bpb )
			local bytes = { enc:byte( ptr , ptr+bssz-1 ) }
			for i = 1 , bssz do
				local n = bytes[i]
				for j = 1 , bpb do
					nr = nr+1
					r[nr] = n%2 == 1
					if nr == o.__sz then break end
					n = (n-n%2)/2 -- floored divide
				end
			end
			ptr = ptr + bssz
			return r , ptr
		end
	}
	
	db2.VarBitset = Datatype{
		init = function( o , params )
			db2.info = 0
			
			local sz , nbits = params.size , math.log( params.size + 1 ) / log2
			if type(sz) ~= "number" then db2.info = 7 return error( "db2: VarBitset: Expected number, found " .. type(sz) , 2 ) end
			if math.floor(sz) ~= sz then db2.info = 7 return error( "db2: VarBitset: Expected integer" , 2 ) end
			
			o.__sz , o.__nbits = sz , nbits
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "table" then db2.info = 1 return error( "db2: VarBitset: encode: Expected table, found " .. type(data) ) end
			if #data > o.__sz then db2.info = 2 return error( "db2: VarBitset: encode: Data is bigger than is allocated for" ) end
			local lsz = math.ceil(o.__nbits/bpb)
			local ldata = #data
			local r = { numbertobytes( ldata , bpb , lsz ) }
			local nr = 1
			for i = 1 , math.ceil( ldata / bpb ) do
				local n = 0
				for j = 1 , bpb do
					n = n + ( data[(i-1)*bpb+j] and 1 or 0 ) * 2^(j-1)
				end
				nr = nr + 1
				r[nr] = strchar[n]
			end
			return table.concat( r )
		end,
		decode = function( o , enc , ptr , bpb )
			local lsz = math.ceil(o.__nbits/bpb)
			local num = bytestonumber( enc:sub( ptr , ptr + lsz - 1 ) , bpb )
			local r = {}
			local nr = 0
			local bssz = math.ceil( num / bpb )
			local bytes = { enc:byte( ptr+lsz , ptr+lsz+bssz-1 ) }
			for i = 1 , bssz do
				local n = bytes[i]
				for j = 1 , bpb do
					nr = nr + 1
					r[nr] = n%2 == 1
					if nr == num then break end
					n = (n-n%2)/2 -- floored divide
				end
			end
			ptr = ptr + lsz + bssz
			return r , ptr
		end
	}
	
	db2.VarDataList = Datatype{
		init = function( o , params )
			db2.info = 0
			
			local sz , nbits , dt = params.size , math.log( params.size + 1 ) / log2 , params.datatype
			if type(sz) ~= "number" then db2.info = 7 return error( "db2: VarDataList: Expected number, found " .. type(sz) , 2 ) end
			if math.floor(sz) ~= sz then db2.info = 7 return error( "db2: VarDataList: Expected integer" , 2 ) end
			if type(dt) ~= "table" or not dt.basetype then db2.info = 7 return error( "db2: VarDataList: Expected datatype, found " .. type(dt) , 2 ) end
			
			o.__sz , o.__nbits , o.__dt = sz , nbits , dt
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "table" then db2.info = 1 return error( "db2: VarDataList: encode: Expected table, found " .. type(data) ) end
			if #data > o.__sz then db2.info = 2 return error( "db2: VarDataList: encode: Data is bigger than is allocated for" ) end
			local lsz = math.ceil(o.__nbits/bpb) -- length of size
			local enc = { numbertobytes( #data , bpb , lsz ) }
			for i = 1 , #data do
				enc[i+1] = o.__dt:encode( data[i] , bpb )
			end
			return table.concat( enc )
		end,
		decode = function( o , enc , ptr , bpb )
			local lsz = math.ceil(o.__nbits/bpb)
			local n = bytestonumber( enc:sub( ptr , ptr + lsz - 1 ) , bpb ) -- size of list
			ptr = ptr + lsz
			local out = {}
			for i = 1 , n do
				out[i] , ptr = o.__dt:decode( enc , ptr , bpb )
			end
			return out , ptr
		end
	}
	
	db2.FixedDataList = Datatype{
		init = function( o , params )
			db2.info = 0
			
			local sz , dt = params.size , params.datatype
			if type(sz) ~= "number" then db2.info = 7 return error( "db2: FixedDataList: Expected number, found " .. type(sz) , 2 ) end
			if math.floor(sz) ~= sz then db2.info = 7 return error( "db2: FixedDataList: Expected integer" , 2 ) end
			if type(dt) ~= "table" or not dt.basetype then db2.info = 7 return error( "db2: FixedDataList: Expected datatype, found " .. type(dt) , 2 ) end
			
			o.__sz , o.__dt = sz , dt
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "table" then db2.info = 1 return error( "db2: FixedDataList: encode: Expected table, found " .. type(data) ) end
			if #data ~= o.__sz then db2.info = 2 return error( "db2: FixedDataList: encode: Data size is not as declared" ) end
			local enc = {}
			for i = 1 , o.__sz do
				enc[i] = o.__dt:encode( data[i] , bpb )
			end
			return table.concat( enc )
		end,
		decode = function( o , enc , ptr , bpb )
			local out = {}
			for i = 1 , o.__sz do
				out[i] , ptr = o.__dt:decode( enc , ptr , bpb )
			end
			return out , ptr
		end
	}
	
	db2.VarObjectList = Datatype{
		init = function( o , params )
			db2.info = 0
			
			print("NOTE: VarObjectList is deprecated. Use db2.VarDataList with a db2.Object as the datatype instead")
			
			local sz , nbits , schema = params.size , math.log( params.size + 1 ) / log2 , params.schema
			if type(sz) ~= "number" then db2.info = 7 return error( "db2: VarObjectList: Expected number, found " .. type(sz) , 2 ) end
			if math.floor(sz) ~= sz then db2.info = 7 return error( "db2: VarObjectList: Expected integer" , 2 ) end
			if type(schema) ~= "table" then db2.info = 7 return error( "db2: VarObjectList: Expected table, found " .. type(schema) , 2 ) end
			
			o.__sz , o.__nbits , o.__schema = sz , nbits , schema
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "table" then db2.info = 1 return error( "db2: VarObjectList: encode: Expected table, found " .. type(data) ) end
			if #data > o.__sz then db2.info = 2 return error( "db2: VarObjectList: encode: Data is bigger than is allocated for" ) end
			local lsz = math.ceil(o.__nbits/bpb) -- length of size
			local enc = { numbertobytes( #data , bpb , lsz ) }
			for i = 1 , #data do
				for j = 1 , #o.__schema do -- same loop as db2.encode
					table.insert( enc , o.__schema[j]:encode( data[i][o.__schema[j].key] , bpb ) )
				end
			end
			return table.concat( enc )
		end,
		decode = function( o , enc , ptr , bpb )
			local lsz = math.ceil(o.__nbits/bpb)
			local n = bytestonumber( enc:sub( ptr , ptr + lsz - 1 ) , bpb ) -- size of list
			ptr = ptr + lsz
			local out = {}
			for i = 1 , n do
				out[i] = {}
				for j = 1 , #o.__schema do -- same loop as db2.decode
					out[i][o.__schema[j].key] , ptr = o.__schema[j]:decode( enc , ptr , bpb )
				end
			end
			return out , ptr
		end
	}
	
	db2.FixedObjectList = Datatype{
		init = function( o , params )
			db2.info = 0
			
			print("NOTE: FixedObjectList is deprecated. Use db2.FixedDataList with a db2.Object as the datatype instead")
			
			local sz , schema = params.size , params.schema
			if type(sz) ~= "number" then db2.info = 7 return error( "db2: FixedObjectList: Expected number, found " .. type(sz) , 2 ) end
			if math.floor(sz) ~= sz then db2.info = 7 return error( "db2: FixedObjectList: Expected integer" , 2 ) end
			if type(schema) ~= "table" then db2.info = 7 return error( "db2: FixedObjectList: Expected table, found " .. type(schema) , 2 ) end
			
			o.__sz , o.__schema = sz , schema
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "table" then db2.info = 1 return error( "db2: FixedObjectList: encode: Expected table, found " .. type(data) ) end
			if #data ~= o.__sz then db2.info = 2 return error( "db2: FixedObjectList: encode: Data size is not as declared" ) end
			local enc = {}
			for i = 1 , o.__sz do
				for j = 1 , #o.__schema do
					table.insert( enc , o.__schema[j]:encode( data[i][o.__schema[j].key] , bpb ) )
				end
			end
			return table.concat( enc )
		end,
		decode = function( o , enc , ptr , bpb )
			local out = {}
			for i = 1 , o.__sz do
				out[i] = {}
				for j = 1 , #o.__schema do
					out[i][o.__schema[j].key] , ptr = o.__schema[j]:decode( enc , ptr , bpb )
				end
			end
			return out , ptr
		end
	}
	
	db2.Switch = Datatype{
		init = function( o , params )
			db2.info = 0
			
			local typekey , typedt , dtmap = params.typekey == nil and "type" or params.typekey , params.typedatatype , params.datatypemap
			if type(dtmap) ~= "table" then db2.info = 7 return error( "db2: Switch: Expected table, found " .. type(dtmap) , 2 ) end
			if type(typedt) ~= "table" or not typedt.basetype then db2.info = 7 return error( "db2: Switch: Expected datatype, found " .. type(typedt) , 2 ) end
			
			o.__typekey , o.__typedt , o.__dtmap = typekey , typedt , dtmap
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "table" then db2.info = 1 return error( "db2: Switch: encode: Expected table, found " .. type(data) ) end
			if data[o.__typekey] and o.__dtmap[data[o.__typekey]] then
				local dt = o.__dtmap[data[o.__typekey]]
				if type(dt) ~= "table" or not dt.basetype then db2.info = 1 return error( "db2: Switch: encode: datatypemap is not a map of typekey->datatype" ) end
				local enc = {}
				return o.__typedt:encode( data[o.__typekey] , bpb ) .. dt:encode( data , bpb )
			else db2.info = 1 return error( "db2: Switch: encode: Typekey value not found or datatypemap does not contain key" ) end
		end,
		decode = function( o , enc , ptr , bpb )
			local typ , ptr = o.__typedt:decode( enc , ptr , bpb )
			local dt = o.__dtmap[typ]
			if type(dt) ~= "table" or not dt.basetype then db2.info = 9 return error( "db2: Switch: decode: datatype of decoded type is not available" ) end
			local out , ptr = dt:decode( enc , ptr , bpb )
			out[o.__typekey] = typ
			return out , ptr
		end
	}
	
	db2.SwitchObject = Datatype{
		init = function( o , params )
			db2.info = 0
			
			print("NOTE: SwitchObject is deprecated. Use db2.Switch with a db2.Object as the datatype instead")
			
			local typekey , typedt , schemamap = params.typekey == nil and "type" or params.typekey , params.typedt , params.schemamap
			if type(schemamap) ~= "table" then db2.info = 7 return error( "db2: SwitchObject: Expected table, found " .. type(schemamap) , 2 ) end
			if type(typedt) ~= "table" or not typedt.basetype then db2.info = 7 return error( "db2: SwitchObject: Expected datatype, found " .. type(typedt) , 2 ) end
			
			o.__typekey , o.__typedt , o.__schemamap = typekey , typedt , schemamap
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "table" then db2.info = 1 return error( "db2: SwitchObject: encode: Expected table, found " .. type(data) ) end
			if data[o.__typekey] and o.__schemamap[data[o.__typekey]] then
				local schema = o.__schemamap[data[o.__typekey]]
				if type(schema) ~= "table" then db2.info = 1 return error( "db2: SwitchObject: encode: schemamap is not a map of typekey->schema" ) end
				local enc = {}
				enc[1] = o.__typedt:encode( data[o.__typekey] , bpb )
				for i = 1 , #schema do
					enc[i+1] = schema[i]:encode( data[schema[i].key] , bpb )
				end
				return table.concat( enc )
			else db2.info = 1 return error( "db2: SwitchObject: encode: Typekey value not found or schemamap does not contain key" ) end
		end,
		decode = function( o , enc , ptr , bpb )
			local typ , ptr = o.__typedt:decode( enc , ptr , bpb )
			local schema = o.__schemamap[typ]
			if type(schema) ~= "table" then db2.info = 9 return error( "db2: SwitchObject: decode: schema of decoded type is not available" ) end
			local out = {[o.__typekey]=typ}
			for i = 1 , #schema do
				out[schema[i].key] , ptr = schema[i]:decode( enc , ptr , bpb )
			end
			return out , ptr
		end
	}
	
	db2.Object = Datatype{
		init = function( o , params )
			db2.info = 0
			
			local schema = params.schema
			if type(schema) ~= "table" then db2.info = 7 return error( "db2: Object: Expected table, found " .. type(schema) , 2 ) end
			
			o.__schema = schema
		end,
		encode = function( o , data , bpb )
			if type(data) ~= "table" then db2.info = 1 return error( "db2: Object: encode: Expected table, found " .. type(data) ) end
			local enc = {}
			for i = 1 , #o.__schema do
				enc[i] = o.__schema[i]:encode( data[o.__schema[i].key] , bpb )
			end
			return table.concat( enc )
		end,
		decode = function( o , enc , ptr , bpb )
			local out = {}
			for i = 1 , #o.__schema do
				out[o.__schema[i].key] , ptr = o.__schema[i]:decode( enc , ptr , bpb )
			end
			return out , ptr
		end
	}
	
	local togglelegacy = function()
		local a , b = bytestonumber , numbertobytes
		bytestonumber , numbertobytes = lbtn , lntb
		lbtn , lntb = a , b
		islegacy = not islegacy
	end
	
	local checklegacy = function() -- maybe an error occurred while encoding/decoding in legacy mode
		if islegacy then togglelegacy() end
	end
	
	local legacy = function( f , ... )
		togglelegacy()
		local r = f( ... )
		togglelegacy()
		return r
	end
	
	local function encode( schema , data , params ) -- schema , data
		db2.info = 0
		--checklegacy()
		
		params = params or {}
		local USE_SETTINGS = params.USE_SETTINGS or true
		local USE_EIGHTBIT = params.USE_EIGHTBIT or false
		local USE_MAGIC = params.USE_MAGIC or true
		local USE_VERSION = params.USE_VERSION
		local USE_LEGACY = params.USE_LEGACY
		local VERSION = params.VERSION or schema.VERSION
		
		if USE_LEGACY then
			return legacy( encode , schema , data , {
				USE_SETTINGS = false,
				USE_EIGHTBIT = USE_EIGHTBIT,
				USE_MAGIC = false,
				USE_VERSION = USE_VERSION or 2
			} )
		end
		if params.USE_SCHEMALIST then db2.info = 3 return error("db2: encode: Cannot treat schema as a list",2) end
		
		local bpb = USE_EIGHTBIT and 8 or 7
		
		local vl = params.USE_VERSION or ( ( not VERSION ) and 0 or math.ceil((math.log(VERSION+1)/log2)/bpb) )
		local enc = {
			USE_SETTINGS and numbertobytes( vl + 8 + ( USE_MAGIC and 16 or 0 ) + 32 + ( USE_EIGHTBIT and 128 or 0 ) , bpb , 1 ) or "",
			USE_MAGIC and numbertobytes( 9224 + ( USE_EIGHTBIT and 32768 or 0 ) , bpb , 2 ) or "",
			numbertobytes( VERSION or 0 , bpb , vl ),
		}
        for i = 1 , #schema do
			enc[i+3] = schema[i]:encode( data[schema[i].key] , bpb )
			if db2.info ~= 0 then return end
		end
		return table.concat( enc )
	end
	
	local function decode( t , enc , params )
		db2.info = 0
		--checklegacy()
		
		params = params or {}
		local USE_SETTINGS = params.USE_SETTINGS or true
		local USE_EIGHTBIT = params.USE_EIGHTBIT or false
		local USE_MAGIC = params.USE_MAGIC or true
		local USE_VERSION = params.USE_VERSION or nil
		local USE_LEGACY = params.USE_LEGACY
		
		if USE_LEGACY then
			return legacy( decode , t , enc , {
				USE_SETTINGS = false,
				USE_EIGHTBIT = USE_EIGHTBIT,
				USE_MAGIC = false,
				USE_VERSION = USE_VERSION or 2
			} )
		end
		
		local bpb = USE_EIGHTBIT and 8 or 7
		
		local ptr = 1
		local vl = USE_VERSION
		
		if USE_SETTINGS then
			local settings = enc:byte(ptr)
			
			if not ( settings % 2^6 >= 2^5 and settings % 2^4 >= 2^3 ) then db2.info = 4 return error("db2: decode: Invalid settings byte",2) end
			
			vl = settings % 2^3
			USE_MAGIC = settings % 2^5 >= 2^4
			USE_EIGHTBIT = settings >= 2^7
			bpb = USE_EIGHTBIT and 8 or 7
			
			ptr = ptr + 1
		end
		
		if USE_MAGIC then
			local n = bytestonumber( enc:sub(ptr,ptr+1) , bpb )
			if ( not ( n % 32768 == 9224 ) ) or ( n > 32768 and n - 32768 ~= 9224 ) then db2.info = 4 return error("db2: decode: Invalid magic number",2) end
			
			ptr = ptr + 2
		end
		
		local vn = bytestonumber( enc:sub(ptr,ptr+vl-1) , bpb )
		ptr = ptr + vl
		
		local schema = vl == 0 and ( not params.USE_SCHEMALIST and t or t[0] ) or t[vn]
		
		if not schema then db2.info = 5 return error("db2: decode: Missing schema",2) end
		
		local dat = {}
		for i = 1 , #schema do
			dat[ schema[i].key ] , ptr = schema[i]:decode( enc , ptr , bpb )
			if ptr > enc:len() + 1 then db2.info = 6 return error("db2: decode: End of string reached while parsing",2) end
			if db2.info ~= 0 then return end
		end
		
		if ptr ~= enc:len() + 1 then db2.info = 6 return error("db2: decode: End of schema reached while parsing",2) end
		
		return dat
	end
	
	local test = function( enc , params )
		db2.info = 0
		--checklegacy()
		
		params = params or {}
		local USE_SETTINGS = params.USE_SETTINGS or true
		local USE_EIGHTBIT = params.USE_EIGHTBIT or false
		local USE_MAGIC = params.USE_MAGIC or true
		
		local bpb = USE_EIGHTBIT and 8 or 7
		
		local ptr = 1
		
		if USE_SETTINGS then
			local settings = enc:byte(ptr)
			
			if not ( settings % 2^6 >= 2^5 and settings % 2^4 >= 2^3 ) then db2.info = 4 return false end
			
			USE_MAGIC = settings % 2^5 >= 2^4
			USE_EIGHTBIT = settings >= 2^7
			bpb = USE_EIGHTBIT and 8 or 7
			
			ptr = ptr + 1
		end
		
		if USE_MAGIC then
			local n = bytestonumber( enc:sub(ptr,ptr+1) , bpb )
			if ( not ( n % 32768 == 9224 ) ) or ( n > 32768 and n - 32768 ~= 9224 ) then db2.info = 4 return false end
			
			ptr = ptr + 2
		end
		
		return true
	end
	local errorfunc = function( f )
		db2.info = 0
		
		if type(f) == "function" then error = f
		else db2.info = 8 return error( "db2: errorfunc: Expected function, found " .. type(f) , 2 ) end
	end
	
	db2.Datatype = Datatype
	db2.encode = encode
	db2.decode = decode
	db2.test = test
	db2.errorfunc = errorfunc
	db2.bytestonumber = bytestonumber
	db2.numbertobytes = numbertobytes
	db2.lbtn = lbtn
	db2.lntb = lntb
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

-- Module ID (this is per-Lua dev, careful not to let your data get overridden!)
local MODULE_ID = 2

-- Module data helper
local MDHelper = {}
do
    local FILE_NUMBER = MODULE_ID
    local FILE_LOAD_INTERVAL = 60005  -- in milliseconds
    local LATEST_MD_VER = 1

    local db_cache = {}
    local db_commits = {}
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
                db2.Switch{ key="op", typekey = "op_id", typedatatype = db2.UnsignedInt{ size = 2 }, datatypemap = {
                    [MDHelper.OP_ADD_MAP] = db2.Object{schema={
                        db2.UnsignedInt{ key="code", size=4 },
                    }},
                    [MDHelper.OP_REMOVE_MAP] = db2.Object{schema={
                        db2.UnsignedInt{ key="code", size=4 },
                    }},
                    [MDHelper.OP_UPDATE_MAP_HARD] = db2.Object{schema={
                        db2.UnsignedInt{ key="diff", size=1 },
                    }},
                    [MDHelper.OP_UPDATE_MAP_DIV] = db2.Object{schema={
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

    local default_db = {
        maps = {},
        banned = {},
        module_log = {},
    }

    local operations = {
        [MDHelper.OP_ADD_MAP] = {
            init = function(self, map)
                self.map = map
            end,
            merge = function(self, db)
            end,
        },
        [MDHelper.OP_REMOVE_MAP] = {
            init = function(self, map)
                self.map = map
            end,
            merge = function(self, db)
            end,
        },
        [MDHelper.OP_UPDATE_MAP_HARD] = {
            init = function(self, diff)
                self.diff = diff
            end,
            merge = function(self, db)
            end,
        },
        [MDHelper.OP_UPDATE_MAP_DIV] = {
            init = function(self, diff)
                self.diff = diff
            end,
            merge = function(self, db)
            end,
        },
        [MDHelper.OP_ADD_MAP_COMPLETION] = {
            init = function(self, completed)
                self.completed = completed
            end,
            merge = function(self, db)
            end,
        },
        [MDHelper.OP_ADD_BAN] = {
            init = function(self, pn)
                self.pn = pn
            end,
            merge = function(self, db)
            end,
        },
        [MDHelper.OP_REMOVE_BAN] = {
            init = function(self, pn)
                self.map = map
            end,
            merge = function(self, db)
            end,
        },
        [MDHelper.OP_REPLACE_MAPS] = {
            init = function(self, map_table)
				self.map_table = map_table
            end,
            merge = function(self, db)
				db.maps = self.map_table
            end,
        },
    }

    local get_maps = function()
        return db_cache.maps
    end

    local commit = function(pn, op_id, a1, a2, a3, a4)
        local op = operations[op_id]
        if op then
            local op_mt = setmetatable({}, { __index = {
                init = op.init,
                merge = op.merge
            }})
            op_mt:init(a1, a2, a3, a4)
            op_mt:merge(db_cache)
            db_commits[#db_commits+1] = op_mt
        else
            return error("Invalid operation.")
        end
    end

    local save = function(db)
        local encoded_md = db2.encode(MD_SCHEMA[LATEST_MD_VER], db)
        system.saveFile(encoded_md, FILE_NUMBER)
        print("module data save")
    end

    local parse = function(file, data)
        if tonumber(file) ~= FILE_NUMBER then return end
        local data_sz = #data
        local new_db = data_sz > 0 and db2.decode(MD_SCHEMA, data) or default_db
        local commit_sz = #db_commits
		if data_sz == 0 then
			print("init and save default db")
			save(new_db)
		elseif commit_sz > 0 then
			for i = 1, commit_sz do
				db_commits[i]:merge(new_db)
			end
            save(new_db)
            db_commits = {}
        end
        db_cache = new_db
        if _G.eventFileParsed then
            _G.eventFileParsed()
        end
        module_data_loaded = true
        print("module data load")
    end

    local try_sync = function()
        if not next_module_sync or os.time() >= next_module_sync then
            system.loadFile(FILE_NUMBER)
            next_module_sync = os.time() + FILE_LOAD_INTERVAL
        end
    end

    local get_md_loaded = function()
        return module_data_loaded
    end

    --local set_loaded_callback = function(cb)
    --    loaded_callback = cb
    --end

	MDHelper.getMaps = get_maps
	MDHelper.commit = commit
    MDHelper.parse = parse
    --MDHelper.syncAsap = sync_asap  -- ?_?
    MDHelper.trySync = try_sync
    MDHelper.getMdLoaded = get_md_loaded
    --MDHelper.setLoadedCallback = set_loaded_callback
end

local maps = {{code=1852359, hard_diff=4, div_diff=3, completed=0, rounds=0},{code=294822, hard_diff=2, div_diff=0, completed=0, rounds=0},{code=1289915, hard_diff=1, div_diff=0, completed=0, rounds=0},{code=1236698, hard_diff=1, div_diff=1, completed=0, rounds=0},{code=3587523, hard_diff=2, div_diff=3, completed=0, rounds=0},{code=6114320, hard_diff=0, div_diff=2, completed=0, rounds=0},{code=2611862, hard_diff=3, div_diff=3, completed=0, rounds=0},{code=3292713, hard_diff=4, div_diff=4, completed=0, rounds=0},{code=5479449, hard_diff=3, div_diff=2, completed=0, rounds=0},{code=1287411, hard_diff=3, div_diff=3, completed=0, rounds=0},{code=3833268, hard_diff=3, div_diff=3, completed=0, rounds=0},{code=6244577, hard_diff=1, div_diff=2, completed=0, rounds=0},{code=6400012, hard_diff=3, div_diff=3, completed=0, rounds=0},{code=3630912, hard_diff=3, div_diff=3, completed=0, rounds=0},{code=5417400, hard_diff=3, div_diff=3, completed=0, rounds=0},{code=6684914, hard_diff=0, div_diff=1, completed=0, rounds=0},{code=7294988, hard_diff=3, div_diff=4, completed=0, rounds=0},{code=2183071, hard_diff=1, div_diff=1, completed=0, rounds=0},{code=2187511, hard_diff=2, div_diff=3, completed=0, rounds=0},{code=3518304, hard_diff=1, div_diff=1, completed=0, rounds=0},{code=473464, hard_diff=1, div_diff=2, completed=0, rounds=0},{code=4730674, hard_diff=4, div_diff=3, completed=0, rounds=0},{code=2116888, hard_diff=4, div_diff=4, completed=0, rounds=0},{code=586103, hard_diff=2, div_diff=4, completed=0, rounds=0},{code=3376768, hard_diff=3, div_diff=3, completed=0, rounds=0},{code=2670753, hard_diff=2, div_diff=3, completed=0, rounds=0},{code=1593943, hard_diff=3, div_diff=4, completed=0, rounds=0},{code=387529, hard_diff=5, div_diff=5, completed=0, rounds=0},{code=7747230, hard_diff=4, div_diff=4, completed=0, rounds=0},{code=653426, hard_diff=2, div_diff=3, completed=0, rounds=0},{code=4113708, hard_diff=2, div_diff=3, completed=0, rounds=0},{code=6328976, hard_diff=1, div_diff=1, completed=0, rounds=0},{code=7747641, hard_diff=2, div_diff=4, completed=0, rounds=0},{code=7747649, hard_diff=3, div_diff=4, completed=0, rounds=0},{code=7747238, hard_diff=5, div_diff=5, completed=0, rounds=0},{code=3688810, hard_diff=2, div_diff=3, completed=0, rounds=0},{code=4066292, hard_diff=2, div_diff=3, completed=0, rounds=0},{code=7747241, hard_diff=3, div_diff=2, completed=0, rounds=0},{code=7749467, hard_diff=3, div_diff=3, completed=0, rounds=0},{code=7749472, hard_diff=5, div_diff=5, completed=0, rounds=0},{code=7748557, hard_diff=4, div_diff=4, completed=0, rounds=0},{code=6727382, hard_diff=3, div_diff=2, completed=0, rounds=0},{code=5978741, hard_diff=2, div_diff=2, completed=0, rounds=0},{code=7749479, hard_diff=1, div_diff=1, completed=0, rounds=0},{code=7749488, hard_diff=2, div_diff=3, completed=0, rounds=0},{code=6518642, hard_diff=2, div_diff=2, completed=0, rounds=0},{code=7746353, hard_diff=3, div_diff=4, completed=0, rounds=0},{code=7746357, hard_diff=5, div_diff=5, completed=0, rounds=0},{code=7746359, hard_diff=2, div_diff=2, completed=0, rounds=0},{code=1597117, hard_diff=2, div_diff=2, completed=0, rounds=0},}
local done = false
local commited = false

function eventLoop()
	if not done then
		MDHelper.trySync()
	end
end

function eventFileLoaded(file, data)
    local success, result = pcall(MDHelper.parse, file, data)
    if not success then
        print(string.format("Exception encountered in eventFileLoaded: %s", result))
    end
end

function eventFileParsed()
	if not done then
		print("parsed, committing")
		MDHelper.commit("cass", MDHelper.OP_REPLACE_MAPS, maps)
		commited = true
	end
end

function eventFileSaved(n)
	if commited then
		done = true
	end
	print("file "..n.." was saved!")
    tfm.exec.chatMessage("file "..n.." was saved!")
end

MDHelper.trySync()
