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
| `cloud.node_credentials` | Identitas kredensial mesin | node_id FK; credential hash/key reference; valid_from/revoked_at; secret tidak disimpan plaintext |
| `cloud.node_heartbeats` | Telemetri node | node_id + observed_at; append-only/partitioned |

Node store-server adalah principal sinkronisasi utama ke cloud. Terminal mengirim transaksi ke store-server; terminal tidak mendapat kredensial cloud langsung pada rancangan awal.

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

Hash PIN dan data yang diperlukan untuk autentikasi offline didistribusikan hanya ke toko terkait melalui master package terenkripsi/terproteksi. Cloud tidak mengirim seluruh data IAM ke semua toko. Kebijakan masa berlaku cache dan revocation tetap perlu disepakati.

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
- `cloud.promotions`, `cloud.promotion_conditions`, `cloud.promotion_benefits`, `cloud.promotion_products`, `cloud.promotion_quotas`
- `cloud.payment_methods`
- `cloud.store_hours`, `cloud.store_exceptions`
- `cloud.cash_drawer_policies` (nominal modal tetap per terminal/laci)
- `cloud.receipt_policies` (batas cetak ulang dan konfigurasi struk)
- `cloud.customers`, `cloud.customer_phone_aliases`, `cloud.customer_merge_events`

Versi master melekat pada entitas atau record efektif. Harga dan pajak menggunakan rentang efektif yang tidak overlap untuk key bisnis yang sama. Master yang sudah dipakai transaksi tidak diubah secara historis; buat versi baru.

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

Tidak direplikasi: cart aktif, Hold Order, print job, cache stok, dan detail UI terminal. Status online terminal dikirim sebagai telemetry, bukan transaksi bisnis. Bukti pembayaran disimpan di object storage dengan checksum dan metadata; jangan menaruh file biner di PostgreSQL. Kebijakan apakah bukti fisik disalin ke cloud atau hanya URI terproteksi harus diputuskan sebelum DDL.

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

1. Apakah cloud menyimpan bukti pembayaran sebagai salinan object storage atau hanya metadata/URI terproteksi.
2. Alokasi kuota promosi global per toko untuk periode offline. Kuota global strict tidak dapat dijamin bila toko offline tanpa alokasi kuota sebelumnya.
3. Masa berlaku cache PIN/role dan perilaku pencabutan user saat toko offline.
4. Retensi payload event mentah dibanding retensi fakta transaksi 5 tahun.
5. Target volume, ukuran payload, dan batas partisi sebelum memilih indeks/partitioning final.
6. RPO/RTO serta lokasi backup/arsip cloud.
7. Model hak akses owner/management untuk PII dan detail bukti pembayaran.

## 7. Batas tahap ini

Dokumen ini adalah desain logis cloud v0.1. Belum berisi DDL, migration, API runtime, worker runtime, atau jaminan production readiness. DDL baru boleh dibuat setelah tabel, constraint, ownership, retensi, dan keputusan terbuka disetujui.
