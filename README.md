# Sky Island Explorers (Petualang Pulau Langit)

Simulator eksplorasi Roblox untuk semua umur: lompat dan terbang dengan glider antar pulau melayang, tangkap Sky Critters, kumpulkan Cloud Essence, lalu upgrade.

Kode ditulis dalam Luau (`--!strict`) dengan arsitektur server-authoritative. Seluruh logika ekonomi berjalan di server.

## Status

- [x] **Tahap 1** — Fondasi data & ekonomi: DataService (session locking, autosave), EconomyService, leaderstats, toko upgrade (Jaring/Glider/Tas)
- [x] **Tahap 2** — Pulau & critter: 5 pulau dengan gerbang, 24 critter (6 rarity, shiny 1/500), spawn/gerak/tangkap, tas, Zona Setor

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
| ReplicatedStorage › Shared › Config › CritterConfig | ModuleScript | `src/ReplicatedStorage/Shared/Config/CritterConfig.luau` |
| ServerScriptService › Main | Script | `src/ServerScriptService/Main.server.luau` |
| ServerScriptService › Services › DataService | ModuleScript | `src/ServerScriptService/Services/DataService.luau` |
| ServerScriptService › Services › EconomyService | ModuleScript | `src/ServerScriptService/Services/EconomyService.luau` |
| ServerScriptService › Services › LeaderboardService | ModuleScript | `src/ServerScriptService/Services/LeaderboardService.luau` |
| ServerScriptService › Services › IslandService | ModuleScript | `src/ServerScriptService/Services/IslandService.luau` |
| ServerScriptService › Services › CritterService | ModuleScript | `src/ServerScriptService/Services/CritterService.luau` |
| ServerScriptService › Util › RemoteGuard | ModuleScript | `src/ServerScriptService/Util/RemoteGuard.luau` |
| ServerScriptService › Util › PromptFactory | ModuleScript | `src/ServerScriptService/Util/PromptFactory.luau` |
| StarterPlayer › StarterPlayerScripts › ClientMain | LocalScript | `src/StarterPlayerScripts/ClientMain.client.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › StateController | ModuleScript | `src/StarterPlayerScripts/Controllers/StateController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › EffectsController | ModuleScript | `src/StarterPlayerScripts/Controllers/EffectsController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › UIController | ModuleScript | `src/StarterPlayerScripts/Controllers/UIController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › IslandController | ModuleScript | `src/StarterPlayerScripts/Controllers/IslandController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › InputController | ModuleScript | `src/StarterPlayerScripts/Controllers/InputController.luau` |

Folder `ReplicatedStorage/Remotes` dan `Workspace/Critters` dibuat otomatis oleh server, jadi tidak perlu dibuat manual.

## Cara memasukkan ke Studio

**Pilihan A — Rojo:** jalankan `rojo serve` di folder ini, lalu sambungkan plugin Rojo di Studio.

**Pilihan B — Claude + MCP Roblox Studio:** di sesi Claude yang berjalan lokal (yang punya akses ke MCP Roblox_Studio), minta Claude membaca repo ini dan membuat setiap objek sesuai tabel di atas, dengan isi script persis seperti file-nya.

**Pilihan C — Manual:** buat objek sesuai tabel, lalu salin isi tiap file.

## Setup wajib

1. Publish place, lalu aktifkan **Game Settings › Security › Enable Studio Access to API Services**. Tanpa ini, DataService memakai mock store di memori dan data hilang setelah Stop.
2. Buat Part bernama `UpgradeShop` (Anchored) di dekat SpawnLocation, lalu tambahkan **tag** `UpgradeShop`. ProximityPrompt toko dibuat otomatis oleh server.
3. **Pulau (Tahap 2).** Bangun 5 pulau dengan ketinggian permukaan (Y) mengikuti `IslandConfig.Height`. Selama glider belum ada, sediakan tangga, jembatan, atau jump pad untuk mencapai pulau atas.

   | IslandId | Nama | Y | Harga | Glider |
   |---|---|---|---|---|
   | `Meadow` | Padang Awan | 50 | – | – |
   | `MistForest` | Hutan Kabut | 150 | 750 | Lv 3 |
   | `ThunderDesert` | Gurun Petir | 300 | 6.000 | Lv 6 |
   | `IceCrystal` | Kristal Es | 500 | 40.000 | Lv 10 |
   | `RainbowPalace` | Istana Pelangi | 750 | 250.000 | Lv 15 |

4. **Titik spawn critter.** Untuk setiap pulau, buat 2–4 Part (Anchored, CanCollide off, Transparency 1) di permukaan pulau. Beri **tag** `CritterSpawn` dan **atribut** `IslandId` (string, mis. `Meadow`). Atribut `SpawnRadius` (number) bersifat opsional.
5. **Gerbang pulau.** Untuk pulau 2–5, buat Part atau Model yang menghalangi jalan masuk ke pulau. Beri **tag** `IslandGate` dan **atribut** `IslandId` sesuai pulau yang dijaga.
6. **Zona Setor.** Di markas (Padang Awan), buat Part bernama `SellZone` (Anchored) dan beri **tag** `SellZone`.

## Cara mengetes singkat

- Saat Play, Output menampilkan `[Main] Sky Island Explorers server siap` dan `[DataService] Data <nama> dimuat`.
- Leaderboard menampilkan Essence 50 dan Pulau Tertinggi "Padang Awan".
- Dekati toko dan tekan E, tap, atau tombol X gamepad, lalu beli upgrade Tas seharga 40 Essence.
- Klik atau tap critter dalam radius jaring (8 stud). Setelah animasi jaring ±1,5 detik, critter masuk tas (🎒 1/10). Di gamepad, tombol R2 menangkap critter terdekat.
- Setor tas di Zona Setor untuk mendapat Essence, lalu buka pulau berikutnya di gerbangnya.
- Untuk menambah Essence, gunakan Command Bar dengan tampilan Server:
  `require(game.ServerScriptService.Services.EconomyService).AddEssence(game.Players:GetPlayers()[1], 5000, "Test")`
