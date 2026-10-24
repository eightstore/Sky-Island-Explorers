--!strict
--[[
	NumberFormat
	------------
	Format angka agar mudah dibaca anak-anak di UI.
	  Abbreviate(1530)      -> "1.53K"
	  Abbreviate(2500000)   -> "2.5M"
	  WithSeparator(12345)  -> "12.345"
	Angka selalu dibulatkan KE BAWAH supaya UI tidak pernah menampilkan saldo lebih besar dari aslinya.
]]

local NumberFormat = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi" }

function NumberFormat.Abbreviate(value: number): string
	if value ~= value then
		return "0" -- NaN
	end

	local negative = value < 0
	local n = math.abs(value)

	if n < 1000 then
		return (if negative then "-" else "") .. tostring(math.floor(n))
	end

	local index = 1
	while n >= 1000 and index < #SUFFIXES do
		n /= 1000
		index += 1
	end

	local decimals = if n < 10 then 2 elseif n < 100 then 1 else 0
	local factor = 10 ^ decimals
	local text = string.format("%." .. decimals .. "f", math.floor(n * factor) / factor)

	-- Buang nol di belakang koma: "2.50" -> "2.5", "3.00" -> "3"
	if string.find(text, "%.") then
		text = (string.gsub(text, "0+$", ""))
		text = (string.gsub(text, "%.$", ""))
	end

	return (if negative then "-" else "") .. text .. SUFFIXES[index]
end

function NumberFormat.WithSeparator(value: number): string
	local text = tostring(math.floor(math.abs(value)))
	local result = text:reverse():gsub("(%d%d%d)", "%1."):reverse()
	if string.sub(result, 1, 1) == "." then
		result = string.sub(result, 2)
	end
	return (if value < 0 then "-" else "") .. result
end

return NumberFormat
