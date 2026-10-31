# Desain Database Cloud POS

**Versi:** 0.1 (rancangan logis)  
**Tanggal:** 31 Oktober 2026  
**Status:** Draft untuk review; belum DDL/migration dan belum production-ready  
**Basis:** Spesifikasi fungsional POS v8.0, database lokal migration 001–004, dan DATABASE-BOUNDARIES-LOCAL-CLOUD.md.

## 1. Tujuan dan prinsip

Database cloud adalah database pusat yang terpisah dari database operasional setiap toko. Cloud menjadi pemilik master data, IAM pusat, konfigurasi, registry node, penerima transaksi toko, monitoring, dan sumber laporan konsolidasi.

Prinsip wajib:
1. Satu database cloud untuk seluruh toko; satu database operasional untuk setiap toko.
2. Tidak ada logical replication atau penulisan langsung lintas database.
3. ID UUID asal transaksi dipertahankan; setiap fakta transaksi juga menyimpan `source_store_id`, `source_node_id`, dan identitas record asal.
4. Transaksi PAID/refund yang sudah selesai di cloud bersifat immutable. Koreksi berasal dari event refund/reversal baru, bukan update diam-diam.
5. Inbox event dan proyeksi bisnis di-commit dalam satu transaksi. Event tidak di-ACK sebagai processed sebelum proyeksi berhasil.
6. Master cloud dipublikasikan melalui change log berurutan; toko menarik perubahan dan meng-ACK cursor setelah menerapkan.
7. Tabel laporan/agregasi adalah proyeksi yang dapat dibangun ulang, bukan sumber kebenaran transaksi.
8. Database cloud tidak menampung cart dan Hold Order operasional toko.

## 2. Batas schema dan namespace

Gunakan PostgreSQL dengan schema terpisah:
- `cloud`: organisasi, IAM, master data, konfigurasi, dan publikasi master.
- `ingest`: penerimaan event, idempotency, cursor, processing lease, dan delivery status.
- `replica`: salinan immutable transaksi, pembayaran, refund, kas, dan audit dari toko.
- `reporting`: agregasi/proyeksi untuk dashboard dan ekspor.

Nama di atas adalah logical schema. DDL final dapat menyesuaikan setelah review constraint dan akses.

## 3. Kelompok tabel cloud

### 3.1 Registry organisasi dan node

| Tabel | Fungsi | Kunci/aturan penting |
|---|---|---|
| `cloud.stores` | Master seluruh toko | UUID PK; code unique; timezone dan currency |
| `cloud.store_servers` | Satu local server aktif/terdaftar per toko, termasuk penggantian | UUID PK; store FK; server_code unique; status dan app_version |
| `cloud.terminals` | Registry terminal | UUID PK; (store_id, terminal_code) unique; disabled_at |
| `cloud.sync_nodes` | Identitas node pengirim/penerima | node_id unique; node_type; store_id; terminal_id bila relevan |
| `cloud.node_credentials` | Identitas OAuth client per node | node_id FK; client_id unique; client_secret_hash; allowed_scopes; valid_from/expires_at/revoked_at; credential_version; metadata rotasi; secret tidak disimpan plaintext |
| `cloud.node_heartbeats` | Telemetri node | node_id + observed_at; append-only/partitioned |

Node store-server adalah principal sinkronisasi utama ke cloud. Terminal mengirim transaksi ke store-server; terminal tidak mendapat kredensial cloud langsung pada rancangan awal.
Autentikasi node memakai OAuth 2.0 Client Credentials. Setiap store-server memiliki client_id/client_secret unik dan meminta JWT access token 5 menit melalui cloud authorization endpoint. Cloud menyimpan hash secret, bukan secret plaintext; signing key JWT dikelola KMS/secret manager. Klaim token mengikat sub ke node_id dan store_id serta membawa scope terbatas. Terminal POS tidak memiliki credential cloud. Rotasi/revocation credential dicatat dan tidak menghapus outbox pending di toko.

### 3.2 IAM dan otorisasi pusat

| Tabel | Fungsi |
|---|---|
| `cloud.users` | Identitas pegawai pusat |
| `cloud.roles`, `cloud.permissions` | Role dan permission |
| `cloud.role_permissions` | Relasi role-permission |
| `cloud.user_store_assignments` | Penempatan pegawai per toko |
| `cloud.user_role_assignments` | Role global atau scope toko |
| `cloud.terminal_authorizations` | Otorisasi terminal non-primary |
| `cloud.user_security_events` | Reset PIN, lock/unlock, deaktivasi, transfer toko |

Hash PIN dan data role/permission yang diperlukan untuk autentikasi offline didistribusikan hanya ke toko terkait melalui master package terenkripsi/terproteksi. Cloud tidak mengirim seluruh data IAM ke semua toko. Cache otorisasi offline berlaku maksimal 24 jam sejak sinkronisasi otorisasi terakhir yang berhasil. Waktu server toko menjadi acuan dan harus disinkronkan melalui NTP. Sistem mendeteksi perubahan jam yang mencurigakan (misalnya clock rollback atau lompatan waktu yang tidak wajar); jika integritas waktu tidak dapat dipastikan, cache dianggap kedaluwarsa dan login offline ditolak sampai waktu tervalidasi serta sinkronisasi otorisasi terbaru berhasil. Setelah 24 jam, login offline ditolak sampai store server terhubung kembali ke cloud dan berhasil menyinkronkan otorisasi terbaru. Sesi kasir yang sudah aktif boleh menyelesaikan transaksi yang sedang berjalan atau ditutup, tetapi tidak boleh memulai sesi/transaksi baru setelah cache kedaluwarsa. Revocation/deaktivasi diterapkan pada sinkronisasi berikutnya; saat offline perubahan tersebut belum dapat diketahui toko, tetapi batas cache 24 jam membatasi jendela stale authorization.

### 3.3 Master data dan konfigurasi

Cloud menjadi pemilik tabel logis:
- `cloud.categories`
- `cloud.products`
- `cloud.product_barcodes`
- `cloud.product_prices`
- `cloud.product_tax_rules`
- `cloud.product_store_availability`
- `cloud.product_display_order`
- `cloud.uoms`
- `cloud.promotions`, `cloud.promotion_conditions`, `cloud.promotion_benefits`, `cloud.promotion_products`, `cloud.promotion_quotas`, `cloud.promotion_quota_allocations`
- `cloud.payment_methods`
- `cloud.store_hours`, `cloud.store_exceptions`
- `cloud.cash_drawer_policies` (nominal modal tetap per terminal/laci)
- `cloud.receipt_policies` (batas cetak ulang dan konfigurasi struk)
- `cloud.customers`, `cloud.customer_phone_aliases`, `cloud.customer_merge_events`. Nomor telepon dinormalisasi ke format E.164 sebelum pencocokan dan diberi unique constraint pada identitas nomor aktif.

**Kebijakan konflik pelanggan (diputuskan): auto-merge berdasarkan nomor telepon yang sama.** Saat pelanggan baru/perubahan pelanggan masuk dari toko, cloud menormalisasi nomor telepon lalu mencari nomor aktif yang sama. Jika cocok, cloud langsung menggabungkan record ke satu customer canonical; tidak menunggu verifikasi manual. Proses harus race-safe (unique constraint/transaction) agar dua event bersamaan tidak membuat duplikat.

Aturan konservasi data untuk auto-merge:
- Record pelanggan canonical yang lebih dahulu dibuat tetap menjadi ID utama; ID toko/record lain dicatat sebagai alias dan merge event.
- Field canonical yang kosong boleh diisi dari record yang digabung. Field yang sama-sama terisi tetapi berbeda tidak boleh saling menimpa otomatis; simpan perbedaan sebagai conflict metadata/merge audit untuk koreksi admin bila diperlukan.
- Riwayat transaksi lama tidak diubah atau dihapus. Relasi pelanggan asal tetap tersimpan; laporan/lookup pelanggan menggunakan pemetaan canonical/alias.
- Nomor telepon yang kosong atau tidak valid tidak menjadi dasar auto-merge. Normalisasi harus konsisten (kode negara Indonesia +62 untuk nomor Indonesia).

Versi master melekat pada entitas atau record efektif. Harga dan pajak menggunakan rentang efektif yang tidak overlap untuk key bisnis yang sama. Master yang sudah dipakai transaksi tidak diubah secara historis; buat versi baru.
**Kebijakan kuota promosi offline (diputuskan): alokasi per toko.** Cloud memegang batas kuota global dan mengalokasikan jatah secara atomik per promosi/per toko. Total seluruh alokasi aktif tidak boleh melebihi kuota global. Store server menerima grant yang memuat allocation_id, promotion_id, store_id, jumlah kuota, periode berlaku, versi, dan tanda tangan/validasi integritas. Saat offline, toko hanya boleh menggunakan sisa kuota grant miliknya; tidak boleh meminjam kuota toko lain atau melampaui grant.

Penggunaan kuota dicatat lokal secara durable dan atomik dengan finalisasi sale PAID. Event sale.paid membawa promotion_id, allocation_id, dan jumlah unit kuota yang dikonsumsi; cloud merekonsiliasi penggunaan secara idempotent. Kuota yang belum digunakan tidak otomatis dipindahkan ke toko lain saat toko offline atau hanya karena heartbeat hilang. Re-alokasi hanya boleh dilakukan setelah toko mengonfirmasi grant dihentikan/ditutup dan tidak ada transaksi lokal tertunda yang dapat menggunakannya, atau setelah periode grant berakhir dan prosedur penutupan memastikan grant tidak dapat dipakai lagi. Ini mencegah kuota yang sama dipakai dua toko.

Jika toko membutuhkan tambahan kuota selama masih online, cloud memeriksa sisa kuota global yang belum dialokasikan lalu menerbitkan grant tambahan secara atomik. Saat jatah grant habis, promosi tersebut tidak diterapkan di toko itu sampai grant baru diterima. Alokasi dan konsumsi harus dapat diaudit.

### 3.4 Distribusi master

| Tabel | Fungsi |
|---|---|
| `cloud.master_change_log` | Log append-only perubahan master untuk seluruh toko atau target toko tertentu |
| `cloud.master_stream_counter` | Counter global yang dialokasikan secara transaksional/serialized |
| `cloud.store_master_cursors` | Cursor terakhir yang sudah diterapkan tiap store-server |
| `cloud.master_snapshots` | Metadata snapshot bootstrap per versi/cursor, bila diperlukan |

Kolom inti `master_change_log`: `change_seq BIGINT`, `entity_type`, `entity_id`, `entity_version`, `operation` (upsert/deactivate), `target_store_id nullable`, `effective_at`, `payload`, `published_at`.

**Aturan cursor:** counter diambil dengan row lock dan ditulis dalam transaksi yang sama dengan perubahan master dan change-log. Ini membuat urutan publikasi commit-ordered. Sequence PostgreSQL biasa tanpa mekanisme serialisasi tidak boleh diasumsikan commit-ordered. Toko hanya memajukan cursor setelah semua perubahan dalam batch berhasil diterapkan lokal. Di database lokal toko, cursor ini disimpan pada tabel baru `sync_master_cursors` (scope node/stream, applied_change_seq, updated_at) yang diperbarui atomik bersama penerapan batch; jangan memakai `sync_checkpoints` lama sebagai cursor resume karena tabel tersebut hanya watermark observasional.

### 3.5 Event ingestion dan recovery cloud

| Tabel | Fungsi | Kunci/aturan penting |
|---|---|---|
| `ingest.received_events` | Envelope event asal toko dan payload untuk retry/audit | unique (source_node_id,event_id); unique (source_node_id,idempotency_key); payload_hash |
| `ingest.aggregate_cursors` | Versi terakhir yang berhasil diproyeksikan per source + aggregate | PK (source_node_id,aggregate_type,aggregate_id) |
| `ingest.delivery_attempts` | Riwayat request/response/retry | received_event_id; attempted_at; outcome |
| `ingest.replay_actions` | Replay/skip manual yang diaudit | event_id; action; actor; reason; timestamp |
| `ingest.node_sync_status` | Pending count, last success, oldest pending, last error | satu status ringkas per node/stream |

Envelope wajib membawa `event_id`, `idempotency_key`, `source_node_id`, `source_store_id`, `aggregate_type`, `aggregate_id`, `aggregate_version`, `event_type`, `schema_version`, `occurred_at`, `correlation_id`, dan `payload`. Simpan hash payload untuk mendeteksi penggunaan ulang event_id dengan isi berbeda.

Constraint unik aggregate: (source_node_id, aggregate_type, aggregate_id, aggregate_version). Event dengan versi lompat tidak boleh diproyeksikan sebelum versi sebelumnya diproses atau diselesaikan melalui prosedur skip yang diaudit. Dependency lintas aggregate juga diperiksa: misalnya `refund.paid` harus ditahan sampai `original_sale_id` tersedia di replica, walaupun sequence aggregate refund sendiri sudah berurutan.

### 3.6 Replika transaksi immutable

Cloud hanya menyimpan transaksi final yang dibutuhkan konsolidasi. Semua tabel replika menyimpan `source_store_id`, `source_node_id`, `source_entity_id`, `source_created_at`, `received_at`, dan `business_date` bila relevan.

| Tabel replica | Isi |
|---|---|
| `replica.sales` | Header penjualan; unique (source_store_id, source_sale_id), receipt number unique per store |
| `replica.sale_lines` | Detail item dan snapshot SKU/nama/barcode/harga/diskon/pajak |
| `replica.sale_discounts` | Diskon otomatis/manual |
| `replica.sale_promotion_cancellations` | Pembatalan promosi dan alasan |
| `replica.payments` | Split tender, metode, nilai, referensi, status final |
| `replica.refunds` | Header refund; referensi sale asal |
| `replica.refund_lines` | Detail kuantitas/nilai dan status barang diterima/layak jual |
| `replica.refund_payments` | Breakdown payout refund |
| `replica.cash_sessions` | Buka/tutup sesi dan nilai hitung/expected/variance |
| `replica.cash_ledger_entries` | Cash in/out dan sumbernya |
| `replica.cash_handover_events` | Serah terima kasir |
| `replica.cash_deposits` | Setoran harian |
| `replica.audit_events` | Audit asal toko, actor dan before/after data sesuai kebijakan |

Tidak direplikasi: cart aktif, Hold Order, print job, cache stok, dan detail UI terminal. Status online terminal dikirim sebagai telemetry, bukan transaksi bisnis. Bukti pembayaran non-tunai yang dilampirkan disalin ke object storage cloud. Database hanya menyimpan URI/key terproteksi, checksum SHA-256, ukuran, MIME type, nama file asli yang telah disanitasi, waktu unggah, dan metadata relasi pembayaran/transaksi; file biner tidak disimpan di PostgreSQL. Store server mempertahankan salinan lokal sementara sampai cloud mengonfirmasi object tersimpan dan checksum tervalidasi.

Cloud tidak menjadikan data stok POS sebagai sumber stok. Stok tetap berasal dari sistem inventory otoritatif di luar POS.

### 3.7 Reporting dan agregasi

Schema `reporting` berisi proyeksi rebuildable:
- `daily_store_sales`: omzet, transaksi, diskon, pajak, refund, net sales.
- `daily_product_sales`: qty, gross/net sales per SKU/store/date.
- `daily_cashier_sales`: transaksi dan nilai per cashier/store/date.
- `daily_payment_totals`: nilai per metode pembayaran/store/date.
- `daily_promotion_totals`: penggunaan dan diskon promosi/store/date.
- `sync_health_daily`: backlog, latency, availability, failure counts.

Sumber kebenaran tetap tabel `replica` dan event yang telah diproses. Agregasi dapat dihitung ulang. Partisi bulanan disarankan untuk tabel fakta besar berdasarkan `business_date` (atau `received_at` untuk inbox/telemetry). Indeks utama dimulai dari store/date, product/date, cashier/date, dan payment/date. Retensi/arsip final ditetapkan bersama kebutuhan laporan dan legal hold.

### 3.6 Bukti pembayaran non-tunai



File bukti pembayaran yang dilampirkan disalin ke object storage cloud. PostgreSQL hanya menyimpan metadata dan referensi object terproteksi, bukan binary. Metadata minimum: payment_id/sale_id, object_key atau URI internal, checksum SHA-256, ukuran byte, MIME type, nama file asli yang disanitasi, uploaded_at, source_node_id, dan status verifikasi.



Object storage wajib private-by-default; akses melalui authorization service atau signed URL berumur pendek dengan scope/permission yang sesuai. URI/key internal tidak boleh menjadi tautan publik. Enkripsi in-transit dan at-rest wajib. Akses baca/unduh dicatat di audit; bukti pembayaran tidak boleh masuk log aplikasi.



Store server menyimpan salinan lokal sementara secara durable selama upload belum berhasil diverifikasi cloud. Salinan lokal baru boleh dihapus setelah cloud mengonfirmasi object tersimpan, checksum cocok, dan metadata payment terikat ke transaksi. Kegagalan upload tidak boleh menghilangkan bukti lokal atau membatalkan transaksi PAID; upload di-retry secara idempotent. Bukti bersifat opsional sesuai aturan pembayaran yang berlaku.



Object key harus tidak mudah ditebak dan tidak menggunakan nama file asli sebagai identitas. Penggantian/penghapusan bukti dilakukan melalui aksi terotorisasi dan diaudit; jangan menimpa object yang sudah direferensikan transaksi tanpa jejak versi.

## 4. Aturan penerimaan dan proyeksi event

1. Validasi identitas node, store scope, schema_version, payload size, dan hash.
2. Upsert envelope ke `ingest.received_events` dengan unique source/event/idempotency.
3. Jika event sama dan hash sama: kembalikan status yang sudah tercatat (idempotent). Jika ID/key sama tetapi hash berbeda: conflict dan alert keamanan/data.
4. Klaim event dengan lease/fencing token.
5. Validasi aggregate_version harus sama dengan cursor + 1.
6. Proyeksikan seluruh fakta aggregate ke `replica` dalam satu transaksi.
7. Dalam transaksi yang sama, majukan aggregate cursor dan tandai event processed.
8. Baru setelah commit, receiver mengirim final ACK.
9. Event gagal sementara dapat dicoba ulang; kegagalan permanen ditahan untuk perbaikan. Jangan menghapus payload gagal.
10. Replay mempertahankan event_id dan payload asli; skip hanya boleh dilakukan oleh role berwenang dengan alasan dan audit.

Untuk sale PAID, satu event membawa header + seluruh sale lines + discount/promotion snapshot + confirmed payments yang diperlukan untuk merekonstruksi transaksi. Refund PAID membawa header + refund lines + payout. Ini menghindari ketergantungan pada urutan insert row yang tidak relevan di cloud.

## 5. Partitioning, indeks, dan retensi

- Partisi bulanan untuk tabel transaksi/telemetry besar setelah volume terukur; jangan mempartisi tabel master.
- Unique idempotency harus tetap enforceable lintas partisi. Jika unique global tidak dapat ditegakkan langsung pada tabel partisi, gunakan tabel registry idempotency non-partitioned.
- Indeks transaksi berdasarkan `(source_store_id,business_date)`, `(source_store_id,source_entity_id)`, serta kombinasi laporan yang benar-benar dipakai.
- Inbox payload dan audit perlu kebijakan retensi terpisah dari fakta transaksi.
- Retensi transaksi POS mengikuti keputusan 5 tahun dan mekanisme arsip; audit mengikuti 3 tahun sesuai baseline, kecuali legal hold.
- Backup cloud terpisah dari backup node toko. Restore test berkala dan RPO/RTO cloud ditetapkan pada desain infrastruktur.
- PII pelanggan dan bukti pembayaran harus dibatasi dengan role, enkripsi at-rest/in-transit, akses audit, dan kebijakan ekspor.

## 6. Keputusan yang belum final


2. Detail implementasi grant kuota promosi: struktur DDL, tanda tangan/integritas grant, prosedur penutupan/re-alokasi, dan rekonsiliasi penggunaan.
3. Detail implementasi cache otorisasi: format timestamp sinkronisasi NTP, ambang deteksi perubahan jam mencurigakan, dan mekanisme menjaga masa berlaku tetap aman saat reboot/server clock rollback.
4. Retensi payload event mentah dibanding retensi fakta transaksi 5 tahun.
5. Target volume, ukuran payload, dan batas partisi sebelum memilih indeks/partitioning final.
6. RPO/RTO serta lokasi backup/arsip cloud.
7. Model hak akses owner/management untuk PII dan detail bukti pembayaran.

## 7. Batas tahap ini

Dokumen ini adalah desain logis cloud v0.1. Belum berisi DDL, migration, API runtime, worker runtime, atau jaminan production readiness. DDL baru boleh dibuat setelah tabel, constraint, ownership, retensi, dan keputusan terbuka disetujui.
