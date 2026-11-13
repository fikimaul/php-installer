# PHP Updater untuk C:\Server

Tool untuk meng-update PHP yang terpasang di `C:\Server` secara otomatis, aman, dan
bisa rollback. Tersedia dalam 3 tampilan yang semuanya memakai mesin update yang sama:

- **GUI** (Windows Forms) — double-click, ada log real-time
- **TUI** (menu console) — untuk terminal murni / RDP
- **CLI** (PowerShell) — untuk script/otomasi

## Fitur

- **Update** instalasi PHP yang ada (backup + rollback otomatis)
- **Install baru** di folder baru (mis. `C:\Server\php-8.4`) + bisa daftarkan
  **vhost mod_fcgid** otomatis ke `httpd-vhosts.conf` (port bebas, gaya sama
  dengan vhost yang sudah ada)
- **Otomatis sinkron `C:\Server\php_bat`** (membuat/memperbarui file `phpXX.bat` untuk memanggil PHP versi tersebut dari CMD/terminal)
- Dialog **Jelajahi** memakai picker folder modern Windows (bisa navigasi & ketik path)

## File

| File | Fungsi |
|---|---|
| `Jalankan-GUI.cmd` | Launcher GUI (double-click) |
| `Jalankan-TUI.cmd` | Launcher TUI (menu console) |
| `update-php-gui.ps1` | GUI Windows Forms (update + install baru) |
| `update-php-tui.ps1` | TUI menu console |
| `update-php.ps1` | CLI / mesin update & install (dipanggil GUI & TUI) |
| `php-updater-lib.ps1` | Library fungsi bersama (deteksi, index windows.php.net) |

## Cara pakai

### GUI (disarankan)

Double-click **`Jalankan-GUI.cmd`**. Kalau belum admin, klik tombol
**"Jalankan sebagai Admin"** di pojok kiri atas (akan muncul prompt UAC).

**Mode Update:**
1. Pilih folder PHP (tombol **Jelajahi...** membuka dialog picker modern,
   bisa ketik path langsung di address bar), info versi/arch/TS terdeteksi otomatis.
2. Pilih versi target: `(Otomatis)`, ketik cabang (`8.4`), atau klik
   **"Cek Versi Tersedia"** lalu pilih versi persis dari dropdown.
3. Klik **"Update Sekarang"**, konfirmasi, lalu tunggu — log tampil real-time.

**Mode Install Baru:**
1. Pilih radio **"Install baru (folder baru)"**, isi folder target
   (mis. `C:\Server\php-8.4`) — wajib folder baru atau folder kosong.
2. Versi **wajib** dipilih/diketik (mis. `8.4` atau `8.4.12`).
3. Centang **"Daftarkan vhost fcgid otomatis di port"** + isi port (mis. `84`)
   kalau langsung mau dipakai via Apache (DocRoot `D:/Development`, sama seperti vhost lain).
   Konfigurasi di-backup dulu dan divalidasi dengan `httpd -t` sebelum restart.
4. Klik **"Install Sekarang"**.

### TUI (console)

Double-click **`Jalankan-TUI.cmd`**, atau:

```powershell
powershell -ExecutionPolicy Bypass -File D:\php-updater\update-php-tui.ps1
```

Menu:
```
[1] Update otomatis (cabang saat ini -> patch terbaru)
[2] Update ke versi tertentu (cabang 8.4 / persis 8.4.12)
[3] Lihat versi yang tersedia di windows.php.net
[4] Ganti folder PHP yang mau di-update   (php, php-7.4, ...)
[5] Buka folder backup terbaru
[6] Install PHP BARU (folder baru + vhost fcgid opsional)
[F] Toggle Force (lewati cek "sudah versi terbaru")
[0] Keluar
```

### CLI (PowerShell)

Buka **PowerShell sebagai Administrator**:

```powershell
cd D:\php-updater

.\update-php.ps1 -ListAvailable          # lihat versi tersedia (tanpa ubah apa pun)
.\update-php.ps1                         # update patch terbaru di cabang saat ini
.\update-php.ps1 -Version 8.4            # naik cabang
.\update-php.ps1 -Version 8.3.14         # versi persis
.\update-php.ps1 -PhpDir C:\Server\php-7.4 -Version 7.4   # folder PHP lain

# INSTALL BARU
.\update-php.ps1 -InstallNew -PhpDir C:\Server\php-8.4 -Version 8.4
.\update-php.ps1 -InstallNew -PhpDir C:\Server\php-8.4 -Version 8.4 -VhostPort 84
    # ^ sekalian daftar vhost fcgid di port 84 -> http://localhost:84/

.\update-php.ps1 -ZipPath D:\download\php-8.2.29-Win32-vs16-x64.zip  # offline
```

## Parameter CLI

| Parameter | Default | Keterangan |
|---|---|---|
| `-PhpDir` | `C:\Server\php` | Folder PHP (untuk install baru: nama folder baru) |
| `-Version` | (cabang saat ini) | `8.2` (cabang) atau `8.2.29` (persis) — **wajib** untuk `-InstallNew` |
| `-InstallNew` | off | Instal PHP segar di folder baru (bukan update) |
| `-VhostPort` | 0 | Khusus `-InstallNew`: tambah vhost fcgid di port ini |
| `-VhostDocRoot` | `D:/Development` | DocumentRoot untuk vhost baru |
| `-ThreadSafe` | otomatis | `TS`/`NTS` — otomatis dari keberadaan `php*apache2_4.dll` |
| `-Arch` | otomatis | `x64`/`x86` — otomatis dari header PE `php*ts.dll` |
| `-ApacheDir` | `C:\Server\Apache24` | Untuk `httpd -t` dan restart |
| `-ZipPath` | — | Pakai zip lokal (offline) |
| `-ListAvailable` | — | Tampilkan daftar build yang tersedia |
| `-NoRestart` | off | Jangan start ulang Apache |
| `-Force` | off | Skip cek versi terbaru & cek admin |

## Apa yang dilakukan saat update

1. Deteksi versi, arsitektur, dan TS/NTS instalasi yang ada.
2. Cari build terbaru yang cocok di `windows.php.net` (fallback ke `/archives/`).
3. Download + ekstrak ke staging, validasi `php.exe -v` **sebelum** menyentuh instalasi lama.
4. Stop Apache dan proses `php-cgi` milik folder itu (mod_fcgid sering masih memegang file).
5. Backup: `C:\Server\php` → `C:\Server\php.bak-<timestamp>` (rename, cepat & aman).
6. Pasang folder baru, lalu:
   - `php.ini` lama **dipertahankan**, hanya `extension_dir` disesuaikan.
   - File custom yang tidak ada di build resmi ikut disalin
     (mis. `ext\php_xdebug.dll`, `extras\ssl\legacy.dll`, `lib\...`).
7. Smoke test `php.exe -v` dan `php.exe -m` (menangkap extension yang gagal dimuat).
8. `httpd -t` lalu start ulang Apache.
9. **Gagal di tengah jalan?** Rollback otomatis: folder baru dibuang, backup dikembalikan,
   Apache dinyalakan lagi.

## Apa yang dilakukan saat **install baru** (`-InstallNew`)

1. Validasi: versi wajib diisi, folder target harus baru atau kosong.
2. Download + ekstrak ke staging, validasi `php.exe -v`.
3. Pasang ke folder target (gagal = folder dibersihkan, tidak menyentuh yang lain).
4. `php.ini` dibuat dari `php.ini-production`, `extension_dir` diset ke folder baru.
5. Smoke test `php.exe -n -v`.
6. Opsional (`-VhostPort`): tambah blok vhost mod_fcgid ke `httpd-vhosts.conf`
   (backup dulu, cek duplikasi port, validasi `httpd -t`; gagal = konfigurasi dikembalikan).
7. Kalau vhost berhasil: **restart** Apache (stop dulu, lalu start) supaya konfigurasi baru terbaca.

## Catatan untuk setup C:\Server

- Vhost lama memakai **mod_fcgid** per port (`php-5.3`:553, `php-5.4`:54, `php-5.6`:56,
  `php-7.2`:72, `php-7.4`:74). Saat **update** tool **tidak mengubah**
  `httpd-vhosts.conf` karena nama folder tetap sama, jadi konfigurasi vhost ikut
  berlaku untuk versi baru. Vhost baru hanya ditambahkan saat **install baru**
  dengan `-VhostPort` (GUI: centang vhost, TUI: isi port).
- Saat **naik cabang** (mis. 8.2 → 8.4), `php_xdebug.dll` yang lama **tidak kompatibel**.
  Cek pesan "PHP Startup" pada hasil smoke test, lalu ganti dengan build Xdebug untuk
  versi baru (https://pecl.php.net/package/xdebug atau windows.php.net/downloads/pecl/releases/xdebug).
- Pastikan **Visual C++ Redistributable 2015–2022 (x64)** terpasang; build PHP 8.x
  butuh `vcruntime140.dll`.
- Backup (`*.bak-*`) tidak dihapus otomatis — hapus manual setelah yakin.

## Troubleshooting

| Gejala | Penyebab / solusi |
|---|---|
| Tombol Update mati (GUI) / "tanpa hak admin" | Jalankan sebagai Administrator (UAC) |
| "Sudah versi terbaru" | Sudah paling baru; centang **Paksa** (GUI) / `[F]` (TUI) / `-Force` (CLI) |
| "Build ... gagal dijalankan" | VC++ Redistributable 2015–2022 (x64) belum terpasang |
| Extension "Unable to load dynamic library" | Extension lama tidak kompatibel dengan versi baru (umumnya Xdebug) — ganti build extension-nya |
| Gagal download | Pakai `-ZipPath` dengan zip hasil download manual dari windows.php.net |

## Rollback manual

```powershell
# Stop Apache dulu, lalu:
Rename-Item C:\Server\php        php.broken
Rename-Item C:\Server\php.bak-YYYYMMDD-HHMMSS  php
# Start Apache
```
