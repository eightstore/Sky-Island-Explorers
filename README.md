# Sky Island Explorers (Petualang Pulau Langit)

Simulator eksplorasi Roblox untuk semua umur: lompat dan terbang dengan glider antar pulau melayang, tangkap Sky Critters, kumpulkan Cloud Essence, lalu upgrade.

Kode ditulis dalam Luau (`--!strict`) dengan arsitektur server-authoritative. Seluruh logika ekonomi berjalan di server.

## Status

- [x] **Tahap 1** — Fondasi data & ekonomi: DataService (session locking, autosave), EconomyService, leaderstats, toko upgrade (Jaring/Glider/Tas)
- [x] **Tahap 2** — Pulau & critter: 5 pulau dengan gerbang, 24 critter (6 rarity, shiny 1/500), spawn/gerak/tangkap, tas, Zona Setor
- [x] **Tahap 3** — Glider (LinearVelocity + anti speed-hack), Markas dengan essence pasif & offline earnings (maks. 8 jam), Album koleksi per bioma dengan hadiah
- [x] **Tahap 4** — Telur awan per pulau (odds tampil sebelum membeli, hasil diundi server), 5 gamepass + 6 developer product (ProcessReceipt idempoten), jalur gratis dengan Essence, Jaring Otomatis

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
| ReplicatedStorage › Shared › Config › GliderConfig | ModuleScript | `src/ReplicatedStorage/Shared/Config/GliderConfig.luau` |
| ReplicatedStorage › Shared › Config › BaseConfig | ModuleScript | `src/ReplicatedStorage/Shared/Config/BaseConfig.luau` |
| ReplicatedStorage › Shared › Config › EggConfig | ModuleScript | `src/ReplicatedStorage/Shared/Config/EggConfig.luau` |
| ReplicatedStorage › Shared › Config › ProductConfig | ModuleScript | `src/ReplicatedStorage/Shared/Config/ProductConfig.luau` |
| ServerScriptService › Main | Script | `src/ServerScriptService/Main.server.luau` |
| ServerScriptService › Services › DataService | ModuleScript | `src/ServerScriptService/Services/DataService.luau` |
| ServerScriptService › Services › EconomyService | ModuleScript | `src/ServerScriptService/Services/EconomyService.luau` |
| ServerScriptService › Services › MonetizationService | ModuleScript | `src/ServerScriptService/Services/MonetizationService.luau` |
| ServerScriptService › Services › LeaderboardService | ModuleScript | `src/ServerScriptService/Services/LeaderboardService.luau` |
| ServerScriptService › Services › IslandService | ModuleScript | `src/ServerScriptService/Services/IslandService.luau` |
| ServerScriptService › Services › CritterService | ModuleScript | `src/ServerScriptService/Services/CritterService.luau` |
| ServerScriptService › Services › BaseService | ModuleScript | `src/ServerScriptService/Services/BaseService.luau` |
| ServerScriptService › Services › AlbumService | ModuleScript | `src/ServerScriptService/Services/AlbumService.luau` |
| ServerScriptService › Services › GliderService | ModuleScript | `src/ServerScriptService/Services/GliderService.luau` |
| ServerScriptService › Services › EggService | ModuleScript | `src/ServerScriptService/Services/EggService.luau` |
| ServerScriptService › Util › RemoteGuard | ModuleScript | `src/ServerScriptService/Util/RemoteGuard.luau` |
| ServerScriptService › Util › PromptFactory | ModuleScript | `src/ServerScriptService/Util/PromptFactory.luau` |
| ServerScriptService › Util › StateViews | ModuleScript | `src/ServerScriptService/Util/StateViews.luau` |
| StarterPlayer › StarterPlayerScripts › ClientMain | LocalScript | `src/StarterPlayerScripts/ClientMain.client.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › StateController | ModuleScript | `src/StarterPlayerScripts/Controllers/StateController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › EffectsController | ModuleScript | `src/StarterPlayerScripts/Controllers/EffectsController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › UIController | ModuleScript | `src/StarterPlayerScripts/Controllers/UIController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › IslandController | ModuleScript | `src/StarterPlayerScripts/Controllers/IslandController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › InputController | ModuleScript | `src/StarterPlayerScripts/Controllers/InputController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › GliderController | ModuleScript | `src/StarterPlayerScripts/Controllers/GliderController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › BaseController | ModuleScript | `src/StarterPlayerScripts/Controllers/BaseController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › AlbumController | ModuleScript | `src/StarterPlayerScripts/Controllers/AlbumController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › EggController | ModuleScript | `src/StarterPlayerScripts/Controllers/EggController.luau` |
| StarterPlayer › StarterPlayerScripts › Controllers › StoreController | ModuleScript | `src/StarterPlayerScripts/Controllers/StoreController.luau` |
| StarterPlayer › StarterPlayerScripts › UI › UIKit | ModuleScript | `src/StarterPlayerScripts/UI/UIKit.luau` |

Folder `ReplicatedStorage/Remotes` dan `Workspace/Critters` dibuat otomatis oleh server, jadi tidak perlu dibuat manual.

## Cara memasukkan ke Studio

**Pilihan A — Rojo:** jalankan `rojo serve` di folder ini, lalu sambungkan plugin Rojo di Studio.

**Pilihan B — Claude + MCP Roblox Studio:** di sesi Claude yang berjalan lokal (yang punya akses ke MCP Roblox_Studio), minta Claude membaca repo ini dan membuat setiap objek sesuai tabel di atas, dengan isi script persis seperti file-nya.

**Pilihan C — Manual:** buat objek sesuai tabel, lalu salin isi tiap file.

## Setup wajib

1. Publish place, lalu aktifkan **Game Settings › Security › Enable Studio Access to API Services**. Tanpa ini, DataService memakai mock store di memori dan data hilang setelah Stop.
2. Buat Part bernama `UpgradeShop` (Anchored) di dekat SpawnLocation, lalu tambahkan **tag** `UpgradeShop`. ProximityPrompt toko dibuat otomatis oleh server.
3. **Pulau (Tahap 2).** Bangun 5 pulau dengan ketinggian permukaan (Y) mengikuti `IslandConfig.Height`. Pemain melayang antar pulau dengan glider, jadi atur jarak antar pulau sesuai `MaxDistance` glider di level yang disyaratkan (Lv 3 ±160 stud, Lv 6 ±220, Lv 10 ±300, Lv 15 ±400) dan sediakan titik lompat yang lebih tinggi dari pulau tujuan.

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
7. **Markas (Tahap 3).** Di Padang Awan, buat Part bernama `PlayerBase` (Anchored), misalnya alas bundar 12×1×12, dan beri **tag** `PlayerBase`. Critter markas milik tiap pemain akan melayang mengelilinginya (hanya terlihat oleh pemain itu sendiri).
8. **Toko Telur (Tahap 4).** Di Padang Awan, buat Part bernama `EggShop` (Anchored) dan beri **tag** `EggShop`.
9. **Titik teleport (Tahap 4).** Di tiap pulau, buat Part (Anchored, CanCollide off, Transparency 1) dengan **tag** `IslandSpawn` dan **atribut** `IslandId`.
10. **ID produk (Tahap 4).** Buat 5 Gamepass dan 6 Developer Product di Creator Hub, lalu isi `PassId`/`ProductId` di `ProductConfig` (semua masih `0`, bertanda `-- ISI DENGAN ID ASLI`). Selama ID masih 0, tombol Robux nonaktif tetapi jalur Essence tetap berfungsi.

## Cara mengetes singkat

- Saat Play, Output menampilkan `[Main] Sky Island Explorers server siap` dan `[DataService] Data <nama> dimuat`.
- Leaderboard menampilkan Essence 50 dan Pulau Tertinggi "Padang Awan".
- Dekati toko dan tekan E, tap, atau tombol X gamepad, lalu beli upgrade Tas seharga 40 Essence.
- Klik atau tap critter dalam radius jaring (8 stud). Setelah animasi jaring ±1,5 detik, critter masuk tas (🎒 1/10). Di gamepad, tombol R2 menangkap critter terdekat.
- Setor tas di Zona Setor untuk mendapat Essence, lalu buka pulau berikutnya di gerbangnya.
- Lompat lalu tahan Spasi (gamepad: A, HP: tombol 🪂) untuk melayang. Meteran di bawah layar menunjukkan sisa jarak.
- Buka Markas, taruh critter dari tas, dan tunggu 60 detik sampai muncul teks "+X ✨ markas".
- Tombol 📖 di kiri layar membuka Album. Lengkapi satu bioma untuk mendapat hadiah otomatis.
- Di Toko Telur, pilih telur untuk melihat peluang tiap critter, beli, tunggu waktu eraman, lalu buka lewat tombol 🥚.
- Tombol ⭐ membuka Toko Spesial. Setiap gamepass & ramuan bisa dibuka gratis dengan Essence.
- Untuk menambah Essence, gunakan Command Bar dengan tampilan Server:
  `require(game.ServerScriptService.Services.EconomyService).AddEssence(game.Players:GetPlayers()[1], 5000, "Test")`
