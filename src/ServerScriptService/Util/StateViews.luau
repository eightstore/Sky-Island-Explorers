--!strict
--[[
	StateViews
	----------
	Membuat versi ringkas data pemain untuk dikirim ke client.
	Client hanya menerima yang dibutuhkan untuk tampilan (tanpa timestamp internal, dsb.).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)

type CritterView = Types.CritterView
type CollectionView = Types.CollectionView

local StateViews = {}

-- Daftar critter (isi tas atau markas) -> { {CritterId, Shiny}, ... }
function StateViews.Critters(list: { any }): { CritterView }
	local result: { CritterView } = {}
	for _, item in list do
		table.insert(result, { CritterId = item.CritterId, Shiny = item.Shiny == true })
	end
	return result
end

function StateViews.Collection(collection: { [string]: Types.CollectionEntry }): CollectionView
	local result: CollectionView = {}
	for critterId, entry in collection do
		result[critterId] = { Caught = entry.Caught, Shiny = entry.Shiny }
	end
	return result
end

return StateViews
