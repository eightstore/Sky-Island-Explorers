--!strict
--[[
	PromptFactory
	-------------
	Membuat ProximityPrompt di Part/Model ber-tag (toko, zona setor, gerbang pulau).
	ProximityPrompt otomatis mendukung keyboard, layar sentuh, dan gamepad,
	sehingga cocok untuk kontrol "jalan, lompat, klik/tap".
]]

local PromptFactory = {}

export type PromptOptions = {
	Name: string,
	ActionText: string,
	ObjectText: string,
	MaxActivationDistance: number,
	HoldDuration: number?,
}

-- Part tempat prompt dipasang: Part itu sendiri, atau PrimaryPart / Part pertama di dalam Model
function PromptFactory.GetHostPart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	elseif instance:IsA("Model") then
		local primary = instance.PrimaryPart
		if primary then
			return primary
		end
		local found = instance:FindFirstChildWhichIsA("BasePart", true)
		if found and found:IsA("BasePart") then
			return found
		end
	end
	return nil
end

-- Memasang (atau mengembalikan yang sudah ada) ProximityPrompt pada instance
function PromptFactory.Attach(instance: Instance, options: PromptOptions): ProximityPrompt?
	local host = PromptFactory.GetHostPart(instance)
	if not host then
		warn("[PromptFactory] " .. instance:GetFullName() .. " harus berupa Part atau Model berisi Part")
		return nil
	end

	local existing = host:FindFirstChild(options.Name)
	if existing and existing:IsA("ProximityPrompt") then
		return existing
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = options.Name
	prompt.ActionText = options.ActionText
	prompt.ObjectText = options.ObjectText
	prompt.HoldDuration = options.HoldDuration or 0
	prompt.MaxActivationDistance = options.MaxActivationDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = host
	return prompt
end

return PromptFactory
