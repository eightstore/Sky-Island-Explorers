# Sky Island Explorers (Petualang Pulau Langit)

Simulator eksplorasi Roblox untuk semua umur: lompat dan terbang dengan glider antar pulau melayang, tangkap Sky Critters, kumpulkan Cloud Essence, lalu upgrade.

Kode ditulis dalam Luau (`--!strict`) dengan arsitektur server-authoritative. Seluruh logika ekonomi berjalan di server.

## Status

- [x] **Tahap 1** — Fondasi data & ekonomi: DataService (session locking, autosave), EconomyService, leaderstats, toko upgrade (Jaring/Glider/Tas)

## Struktur di Explorer

Ekstensi file dibuang saat dimasukkan ke Studio. `*.server.luau` menjadi Script, `*.client.luau` menjadi LocalScript, dan `*.luau` menjadi ModuleScript.

| Explorer | Tipe | File |
|---|---|---|
| ReplicatedStorage › Shared › Types | ModuleScript | `src/ReplicatedStorage/Shared/Types.luau` |
| ReplicatedStorage › Shared › Net | ModuleScript | `src/ReplicatedStorage/Shared/Net.luau` |
| ReplicatedStorage › Shared › Util › Signal | ModuleScript | `src/ReplicatedStorage/Shared/Util/Signal.luau` |
| ReplicatedStorage › Shared › Util › NumberFormat | ModuleScript | `src/ReplicatedStorage/Shared/Util/NumberFormat.luau` |
| ReplicatedStorage › Shared › Config › EconomyConfig | ModuleScript | `src/ReplicatedStorage/Shared/Config/EconomyConfig.luau` |
| ReplicatedStorage › Shared › Config › IslandConfig | ModuleScript | `src/ReplicatedStorage/Shared/Config/IslandConfig.luau` |
| ReplicatedStorage › Shared › Config › UpgradeConfig | ModuleScript | `src/ReplicatedStorage/Shared/Config/UpgradeConfig.luau` |
| ServerScriptService › Main | Script | `src/ServerScriptService/Main.server.luau` |
| ServerScriptService › Services › DataService | ModuleScript | `src/ServerScriptService/Services/DataService.luau` |
| ServerScriptService › Services › EconomyService | ModuleScript | `src/ServerScriptService/Services/EconomyService.luau` |
| ServerScriptService › Services › LeaderboardService | ModuleScript | `src/ServerScriptService/Services/LeaderboardService.luau` |
| ServerScriptService › Util › RemoteGuard | ModuleScript | `src/ServerScriptService/Util/RemoteGuard.luau` |
| StarterPlayer › StarterPlayerScripts › ClientMain | LocalScript | `src/StarterPlayerScripts/ClientMain.client.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › UIController | ModuleScript | `src/StarterPlayerScripts/Controllers/UIController.luau` |

Folder `ReplicatedStorage/Remotes` dibuat otomatis oleh server, jadi tidak perlu dibuat manual.

## Cara memasukkan ke Studio

**Pilihan A — Rojo:** jalankan `rojo serve` di folder ini, lalu sambungkan plugin Rojo di Studio.

**Pilihan B — Claude + MCP Roblox Studio:** di sesi Claude yang berjalan lokal (yang punya akses ke MCP Roblox_Studio), minta Claude membaca repo ini dan membuat setiap objek sesuai tabel di atas, dengan isi script persis seperti file-nya.

**Pilihan C — Manual:** buat objek sesuai tabel, lalu salin isi tiap file.

## Setup wajib

1. Publish place, lalu aktifkan **Game Settings › Security › Enable Studio Access to API Services**. Tanpa ini, DataService memakai mock store di memori dan data hilang setelah Stop.
2. Buat Part bernama `UpgradeShop` (Anchored) di dekat SpawnLocation, lalu tambahkan **tag** `UpgradeShop`. ProximityPrompt toko dibuat otomatis oleh server.

## Cara mengetes singkat

- Saat Play, Output menampilkan `[Main] Sky Island Explorers server siap` dan `[DataService] Data <nama> dimuat`.
- Leaderboard menampilkan Essence 50 dan Pulau Tertinggi "Padang Awan".
- Dekati toko dan tekan E, tap, atau tombol X gamepad, lalu beli upgrade Tas seharga 40 Essence.
- Untuk menambah Essence, gunakan Command Bar dengan tampilan Server:
  `require(game.ServerScriptService.Services.EconomyService).AddEssence(game.Players:GetPlayers()[1], 5000, "Test")`
