--!strict
--[[
	UIKit
	-----
	Kumpulan helper UI yang dipakai bersama oleh semua controller (toko, markas, album, glider).
	Menjaga semua jendela tampil seragam: font, warna, tombol besar ramah sentuh.
]]

local TweenService = game:GetService("TweenService")

local UIKit = {}

UIKit.THEME = table.freeze({
	Font = Enum.Font.FredokaOne,
	HudBackground = Color3.fromRGB(28, 44, 84),
	Panel = Color3.fromRGB(235, 245, 255),
	PanelStroke = Color3.fromRGB(120, 170, 240),
	Card = Color3.fromRGB(255, 255, 255),
	IconBackground = Color3.fromRGB(200, 225, 255),
	Locked = Color3.fromRGB(150, 158, 175),
	Text = Color3.fromRGB(35, 45, 70),
	TextMuted = Color3.fromRGB(95, 105, 130),
	TextLight = Color3.fromRGB(255, 255, 255),
	Buy = Color3.fromRGB(70, 195, 105),
	Action = Color3.fromRGB(80, 150, 240),
	CannotAfford = Color3.fromRGB(165, 172, 188),
	Max = Color3.fromRGB(255, 190, 50),
	Close = Color3.fromRGB(235, 95, 95),
	Positive = Color3.fromRGB(60, 170, 90),
	Negative = Color3.fromRGB(215, 85, 85),
	BagFull = Color3.fromRGB(200, 60, 60),
	Gold = Color3.fromRGB(255, 215, 70),
	NextValue = "#2E9E50",
	Ok = "#2E9E50",
	NotOk = "#D04545",
})

-- Jendela modal yang dikelola UIController (hanya satu terbuka pada satu waktu)
export type Modal = {
	Frame: Frame,
	Pop: UIScale,
	IsInRange: () -> boolean, -- false = jendela ditutup otomatis (pemain menjauh)
	FirstSelectable: () -> GuiObject?, -- tombol pertama untuk gamepad
	OnRefresh: () -> (), -- dipanggil saat state berubah selama jendela terbuka
}

-- Membuat instance dengan properti. Parent diset terakhir (lebih efisien).
function UIKit.Make(className: string, props: { [string]: any }): any
	local instance = Instance.new(className :: any)
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	if props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

local make = UIKit.Make

function UIKit.Corner(parent: Instance, radius: number): ()
	make("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

function UIKit.Stroke(parent: Instance, color: Color3, thickness: number): ()
	make("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

function UIKit.Padding(parent: Instance, pixels: number): ()
	make("UIPadding", {
		PaddingTop = UDim.new(0, pixels),
		PaddingBottom = UDim.new(0, pixels),
		PaddingLeft = UDim.new(0, pixels),
		PaddingRight = UDim.new(0, pixels),
		Parent = parent,
	})
end

function UIKit.Pop(scale: UIScale, from: number): ()
	scale.Scale = from
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- Tombol besar (min. 64 px tinggi sebelum skala) yang mudah ditekan di HP
function UIKit.BigButton(props: { [string]: any }): TextButton
	local button: TextButton = make("TextButton", {
		Name = props.Name or "Button",
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		Position = props.Position or UDim2.new(),
		Size = props.Size,
		BackgroundColor3 = props.Color or UIKit.THEME.Action,
		Text = props.Text or "",
		TextColor3 = UIKit.THEME.TextLight,
		TextSize = props.TextSize or 26,
		TextWrapped = true,
		Font = UIKit.THEME.Font,
		AutoButtonColor = true,
		Selectable = true,
		LayoutOrder = props.LayoutOrder or 0,
		Parent = props.Parent,
	})
	UIKit.Corner(button, props.Radius or 18)
	make("UIStroke", {
		Color = Color3.fromRGB(40, 60, 90),
		Thickness = 2,
		Transparency = 0.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = button,
	})
	return button
end

-- Bingkai jendela modal di tengah layar (tersembunyi sampai dibuka)
function UIKit.ModalFrame(name: string, size: Vector2, parent: Instance): (Frame, UIScale)
	local frame: Frame = make("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.53),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = UIKit.THEME.Panel,
		Visible = false,
		Parent = parent,
	})
	UIKit.Corner(frame, 26)
	UIKit.Stroke(frame, UIKit.THEME.PanelStroke, 4)
	local pop: UIScale = make("UIScale", { Parent = frame })
	return frame, pop
end

function UIKit.Title(parent: Instance, text: string): TextLabel
	return make("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(24, 10),
		Size = UDim2.new(1, -120, 0, 60),
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = UIKit.THEME.Text,
		TextSize = 36,
		TextScaled = false,
		Font = UIKit.THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = parent,
	})
end

function UIKit.CloseButton(parent: Instance, onClose: () -> ()): TextButton
	local button = UIKit.BigButton({
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(64, 64),
		Color = UIKit.THEME.Close,
		Text = "✕",
		TextSize = 34,
		Parent = parent,
	})
	button.Activated:Connect(onClose)
	return button
end

function UIKit.ScrollList(parent: Instance, position: UDim2, size: UDim2, padding: number): ScrollingFrame
	local list: ScrollingFrame = make("ScrollingFrame", {
		Name = "List",
		Position = position,
		Size = size,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = UIKit.THEME.PanelStroke,
		Selectable = false,
		Parent = parent,
	})
	make("UIListLayout", {
		Padding = UDim.new(0, padding),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = list,
	})
	make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = list })
	return list
end

-- Menghapus semua anak GuiObject (baris lama) dari sebuah daftar
function UIKit.ClearList(list: Instance): ()
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

return UIKit
