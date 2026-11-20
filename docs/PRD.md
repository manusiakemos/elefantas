# PRD — Elefantas: Klien Database PostgreSQL & TimescaleDB untuk macOS (Swift)

Nov 15, 2026 · hafiz nugraha

## Ringkasan & latar belakang

Elefantas adalah klien database native macOS untuk PostgreSQL dan TimescaleDB, ditulis penuh dengan Swift, dengan alur dan nuansa UI/UX yang meniru Sequel Ace.

Sequel Ace gratis, open source, dan terasa ringan, tetapi hanya mendukung MySQL dan MariaDB. Alat Postgres yang ada di Mac sebagian berbayar atau dibatasi di versi gratisnya (misalnya TablePlus dan Postico) atau memakai UI yang berbeda dari yang sudah familiar bagi pengguna Sequel Ace. Belum ada klien yang menjadikan fitur TimescaleDB (hypertable, chunk, compression, continuous aggregate) sebagai bagian inti.

Keputusan arsitektur: membangun dari nol dengan Swift, memakai Sequel Ace hanya sebagai acuan alur dan tampilan, bukan mem-fork kodenya. Hasil audit menunjukkan kode Sequel Ace berukuran sekitar 108 ribu baris Objective-C dan 42 ribu baris Swift, dengan 76 file yang bergantung langsung ke lapisan MySQL. Fork akan mewarisi beban itu, sedangkan versi dari nol bisa ringan dan fokus ke Postgres sejak awal.

## Keputusan yang sudah diambil

| Hal | Keputusan |
|---|---|
| Nama produk | Elefantas (ketersediaan belum dicek) |
| Platform | macOS saja |
| Pendekatan | Dari nol, bukan fork Sequel Ace |
| Bahasa dan UI | Swift; SwiftUI untuk layar umum, AppKit untuk grid data dan editor SQL |
| Library database | libpq, di-link statis dan dibungkus tipis dengan Swift |
| Cakupan MVP | Koneksi, penjelajah objek, dan Content |

## Tujuan, non-tujuan, dan prinsip desain

Tujuan utamanya: pengguna Sequel Ace bisa pindah ke Postgres dan Timescale tanpa belajar ulang, dengan app yang tetap ringan dan cepat.

### Tujuan
- Menjadi klien Postgres/TimescaleDB native macOS yang terasa sekelas Sequel Ace: cepat dibuka, hemat memori, nyaman dipakai harian.
- Menyediakan alur kerja yang sama dikenal: sidebar database dan tabel, tab Structure, Content, Query, dan Import/Export.
- Menjadikan fitur TimescaleDB sebagai fitur kelas satu, bukan tambahan.
- Gratis dan open source, dengan lisensi yang kompatibel dengan atribusi ke Sequel Ace dan Sequel Pro bila ada kode atau aset yang dipakai.

### Non-tujuan (versi 1.0)
- Dukungan database selain PostgreSQL dan TimescaleDB (MySQL, SQLite, dan lainnya).
- Dukungan Linux atau Windows.
- Fitur kolaborasi, cloud sync, atau ER diagram.
- Mengganti alat administrasi server penuh seperti pgAdmin (manajemen role, replikasi, dan backup tingkat server).

### Prinsip desain
- Native dulu: AppKit/SwiftUI, tanpa webview.
- Data besar tidak boleh dimuat utuh ke memori: baca per potongan dan alirkan hasil.
- Gunakan jalur cepat Postgres (COPY) untuk import dan export.
- Dependensi seminimal mungkin dengan library ringan, agar pengalamannya seringan Sequel Ace; sederhana lebih penting daripada lengkap.

## Pengguna target & use case

Pengguna utamanya adalah pengembang dan admin database di tim kecil yang mengelola PostgreSQL atau TimescaleDB, sering di server remote lewat SSH tunnel, dan bekerja di macOS.

### Persona
- **Pengembang backend:** menelusuri data, menjalankan query, mengecek skema selama pengembangan.
- **Admin database kecil:** memantau tabel besar, memeriksa index, memindahkan data antar server.
- **Pengguna data time-series:** mengelola hypertable, memeriksa chunk, compression, dan retention.

### Use case utama
1. Menyambung ke server lokal atau remote (SSH tunnel, SSL) dan menyimpan koneksi favorit.
2. Menelusuri tabel besar dengan paginasi, filter, dan pengurutan tanpa membuat app lambat.
3. Menulis dan menjalankan query, melihat hasil yang dialirkan, dan menyimpan query favorit.
4. Melihat dan mengubah struktur tabel: kolom, index, constraint, dan DDL.
5. Mengimpor dan mengekspor data antar server dengan cepat, termasuk lewat koneksi remote.
6. Mengelola objek Timescale: melihat hypertable dan chunk, mengatur compression dan retention, memeriksa continuous aggregate.

## Lingkup fitur inti

MVP mencakup tiga fitur pertama: koneksi, penjelajah objek, dan Content. Sisanya masuk fase berikutnya sampai versi 1.0.

| Fitur | Isi | Fase | Prioritas |
|---|---|---|---|
| Koneksi | Host/port, user/password, SSL, SSH tunnel, koneksi favorit tersimpan di Keychain, tes koneksi | Fase 1 (MVP) | P0 |
| Penjelajah objek | Sidebar database, schema, tabel, view, fungsi; pencarian cepat | Fase 1 (MVP) | P0 |
| Content | Browse data dengan paginasi, filter, urut, edit sel, tambah dan hapus baris; grid berbasis NSTableView | Fase 1 (MVP) | P0 |
| Query | Editor SQL dengan syntax highlighting, hasil dialirkan, riwayat, query favorit, batalkan query | Fase 2 | P0 |
| Structure | Kolom, tipe, index, constraint, foreign key, trigger; tampilan DDL; ubah struktur | Fase 2 | P1 |
| Tipe data Postgres | Array, JSONB, enum, range, UUID, timestamptz, dengan editor sel yang sesuai | Fase 2 | P1 |
| Import | SQL, CSV, dan COPY FROM STDIN yang dibaca per potongan | Fase 3 | P1 |
| Export | SQL, CSV, dan COPY TO STDOUT yang dialirkan; opsi per tabel | Fase 3 | P1 |
| Fitur Timescale | Lihat bagian berikutnya | Fase 3 | P1 |
| Info server | Proses aktif, variabel, ekstensi terpasang, ukuran tabel | Fase 4 | P2 |
| Manajemen role dan hak akses | Daftar role dan grant dasar | Fase 4 | P2 |
| Polesan 1.0 | Dukungan dark mode, shortcut keyboard setara Sequel Ace, lokalisasi (Indonesia dan Inggris) | Fase 4 | P2 |

## Fitur TimescaleDB

Fitur Timescale membedakan produk ini dari klien Postgres lain, dan dibangun di atas view metadata `timescaledb_information` yang disediakan ekstensi. Nama view dan istilah (misalnya compression versus columnstore) harus diverifikasi terhadap versi TimescaleDB yang menjadi target sebelum implementasi.

| Fitur | Yang ditampilkan atau bisa dilakukan | Fase |
|---|---|---|
| Deteksi ekstensi | Deteksi apakah ekstensi timescaledb terpasang dan versinya; fitur Timescale disembunyikan bila tidak ada | Fase 3 |
| Hypertable | Daftar hypertable, kolom waktu dan dimensi partisi, interval chunk, ukuran total | Fase 3 |
| Chunk | Daftar chunk per hypertable: rentang waktu, ukuran, status compression | Fase 3 |
| Compression | Lihat pengaturan dan status; aktifkan atau jalankan compression pada chunk | Fase 3 |
| Retention | Lihat dan atur kebijakan retensi data | Fase 3 |
| Continuous aggregate | Daftar continuous aggregate, definisi query, kebijakan refresh, tombol refresh manual | Fase 3 |
| Jobs | Daftar background job, jadwal, hasil run terakhir | Fase 4 |
| Badge di sidebar | Penanda ikon untuk hypertable dan continuous aggregate di penjelajah objek | Fase 3 |

## Persyaratan non-fungsional

Persyaratan ini berupa usulan awal; angka performa belum diukur dan perlu divalidasi lewat prototipe di Fase 1.

| Area | Persyaratan |
|---|---|
| Performa | Startup cepat tanpa jeda terasa; browse tabel jutaan baris lewat paginasi sisi server dan scroll mulus; query dan export dialirkan, memori tidak tumbuh seiring ukuran hasil |
| Memori | Tetap ringan dibanding klien berbasis JVM atau webview; tidak memuat seluruh hasil query atau file import ke memori |
| Jaringan | Aman dipakai lewat koneksi remote; meminimalkan round trip; query dapat dibatalkan; deteksi dan pulih dari koneksi putus |
| Keamanan | Kredensial di Keychain; dukungan mode SSL Postgres; SSH tunnel dengan key; tanpa telemetri bawaan; konfirmasi untuk operasi destruktif |
| Kompatibilitas | macOS versi terbaru dan satu atau dua rilis sebelumnya (batas minimum ditentukan saat implementasi), Apple Silicon dan Intel; PostgreSQL versi yang masih didukung upstream; TimescaleDB versi terkini |
| Aksesibilitas dan UX | Dark mode, navigasi keyboard, shortcut setara Sequel Ace, dukungan VoiceOver dasar |
| Lokalisasi | Indonesia dan Inggris pada versi 1.0 |
| Kualitas | Tes unit untuk lapisan data dan parser query; tes integrasi terhadap Postgres dan Timescale di Docker |

## Arsitektur & tech stack

Aplikasi berlapis: UI memanggil logika aplikasi, yang meminta lapisan data; hanya lapisan dialect yang menulis SQL khusus Postgres dan Timescale. Pemisahan ini menghindari masalah Sequel Ace, di mana SQL khusus MySQL tersebar di puluhan file.

| Komponen | Pilihan |
|---|---|
| Bahasa | Swift |
| UI | SwiftUI untuk layar umum; AppKit (NSTableView, NSTextView) untuk grid data besar dan editor SQL |
| Koneksi database | libpq (C interop), di-link statis dan dibungkus tipis dengan Swift; dipilih karena ringan dan lengkap (COPY, batalkan query, SSL) |
| SSH tunnel | Cara implementasi ditentukan saat Fase 1 |
| Kredensial | Keychain macOS |
| Build | Xcode dan Swift Package Manager |
| Tes | XCTest; tes integrasi terhadap Postgres dan TimescaleDB di Docker |

## Lisensi, atribusi, dan penamaan

Sequel Ace berlisensi MIT-style atas nama Moballo, LLC (2020), dengan notice terpisah untuk Sequel Pro (2002–2019). Selama tidak ada kode atau aset Sequel Ace yang disalin, produk ini tidak terikat syarat lisensi itu; bila ada yang disalin, kedua notice hak cipta harus disertakan.

- **Penamaan:** jangan memakai nama atau logo "Sequel Ace" atau "Sequel Pro". Nama produk: Elefantas; ketersediaan dan merek dagang belum dicek (lihat pertanyaan terbuka).
- **Aset:** ikon, ilustrasi, dan layout XIB tidak disalin; tampilan dibuat ulang agar mirip secara alur, bukan salinan piksel.
- **Dependensi:** libpq dan library lain harus dicek lisensinya sebelum dibundel; hanya lisensi permisif atau kompatibel dengan lisensi produk yang dipakai.
- **Lisensi produk:** belum diputuskan (lihat pertanyaan terbuka); MIT dipertimbangkan agar sejalan dengan Sequel Ace.

> Catatan ini bukan nasihat hukum; verifikasi lisensi dan merek sebelum rilis publik.

## Roadmap bertahap

Pengerjaan berjalan dalam empat fase berurutan; setiap fase ditutup gerbang yang harus lolos sebelum lanjut. Durasi belum diperkirakan dan ditetapkan setelah prototipe Fase 1.

Panah menunjukkan urutan fase, dan belah ketupat di sudut tiap fase adalah gerbangnya. Kriteria gerbang adalah usulan dan dapat diubah.

> Diagram roadmap tidak ikut di versi teks ini.

## Metrik keberhasilan

Keberhasilan diukur dari satu pertanyaan: apakah pembuatnya meninggalkan klien lain untuk pekerjaan harian di Postgres dan Timescale. Target angka ditetapkan setelah prototipe Fase 1 memberi baseline.

| Metrik | Ukuran | Pembanding |
|---|---|---|
| Pemakaian harian | MVP dipakai untuk pekerjaan nyata di server sendiri tanpa kembali ke klien lain | Pengalaman pembuat |
| Kecepatan import/export | Waktu mengimpor dan mengekspor tabel yang sama lewat koneksi remote | Sequel Ace (MySQL) dan klien Postgres yang ada sebagai pembanding |
| Memori saat idle dan saat membuka tabel besar | RAM terpakai dengan beberapa koneksi terbuka | Sequel Ace dan DBeaver |
| Cakupan fitur Timescale | Persentase fitur di bagian Timescale yang selesai | Daftar fitur di PRD |
| Stabilitas | Jumlah crash dan koneksi putus tak terpulihkan per minggu pemakaian | Dicatat sejak Fase 1 |

## Risiko & pertanyaan terbuka

Risiko terbesar adalah lingkup: membangun ulang semua fitur Sequel Ace bisa memakan waktu berbulan-bulan, sehingga urutan fase dan MVP kecil menjadi pengaman utama.

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Lingkup membengkak | Proyek tak kunjung rilis | MVP hanya koneksi, penjelajah, dan Content; fase berikutnya masuk setelah MVP dipakai |
| Grid data besar kurang mulus di SwiftUI | App terasa berat, tidak seperti Sequel Ace | Pakai NSTableView untuk grid dan komponen AppKit untuk editor SQL; ukur di prototipe |
| Tidak bisa build di lingkungan pengembangan AI | Siklus uji lebih lambat | Build dan tes dilakukan di Mac pengguna; kode dan struktur proyek disiapkan terpisah |
| Perbedaan versi TimescaleDB | Fitur atau view metadata berubah | Deteksi versi saat runtime; verifikasi nama view terhadap versi target |
| Perawatan jangka panjang bergantung pada sedikit orang | Proyek mandek | Cakupan kecil, kode bersih, dokumentasi, dan lisensi terbuka |

### Pertanyaan terbuka
- [ ] Cek ketersediaan nama Elefantas (App Store, GitHub, domain, merek dagang).
- [ ] Lisensi apa yang dipilih (MIT atau lainnya) dan apakah dirilis publik atau hanya untuk pemakaian sendiri?
- [ ] Cara membundel libpq (dan OpenSSL) agar tetap ringan dan lolos distribusi macOS (notarization, sandbox)?
- [ ] Versi macOS minimum dan apakah perlu dukungan Intel?
- [ ] Apakah perlu Linux atau Windows di masa depan? Bila ya, keputusan Swift penuh perlu ditinjau ulang.
