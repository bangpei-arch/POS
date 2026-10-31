# Inventaris Tabel Database Cloud POS

**Versi:** 0.1 (inventaris logis)  
**Tanggal:** 31 Oktober 2026  
**Status:** Draft untuk review; belum DDL  
**Target DB:** PostgreSQL 16 minimum; versi mayor lebih baru hanya setelah uji kompatibilitas.

Dokumen ini memecah kelompok entitas pada `CLOUD-DATABASE-DESIGN.md` menjadi inventaris tabel awal. Nama dan batas tabel masih dapat berubah pada tahap desain kolom/constraint. Dokumen ini tidak mengubah database operasional toko.

## 1. Prinsip desain

- Database cloud terpisah dari database lokal setiap toko.
- Schema cloud dibagi menjadi `cloud`, `ingest`, `replica`, dan `reporting`.
- UUID sumber dipertahankan; data transaksi replika menyimpan asal toko, node, dan ID record.
- Master data dimiliki cloud; transaksi final dimiliki toko dan direplikasi sebagai fakta.
- Hanya `sale.paid` yang dikirim sebagai event bisnis penjualan. Status pembayaran pending tetap lokal.
- Inbox, proyeksi replika, dan cursor diproses atomik.
- Tabel reporting dapat dibangun ulang dari fakta `replica`.
- Tabel transaksi besar dapat dipartisi setelah volume dan query workload terukur. Registry idempotensi harus tetap unik lintas partisi.

## 2. Schema `cloud` — organisasi, IAM, master, konfigurasi

### 2.1 Organisasi dan node

| Tabel | Fungsi utama |
|---|---|
| `cloud.stores` | Identitas dan konfigurasi dasar toko |
| `cloud.store_servers` | Registry server lokal per toko dan riwayat penggantian |
| `cloud.terminals` | Registry terminal POS |
| `cloud.sync_nodes` | Identitas node yang berkomunikasi dengan cloud |
| `cloud.node_credentials` | OAuth client, hash secret, scope, masa berlaku, rotasi dan revocation |
| `cloud.node_heartbeats` | Telemetri heartbeat node |

### 2.2 IAM dan otorisasi

| Tabel | Fungsi utama |
|---|---|
| `cloud.users` | Identitas pegawai |
| `cloud.roles` | Definisi role |
| `cloud.permissions` | Definisi permission |
| `cloud.role_permissions` | Relasi role-permission |
| `cloud.user_store_assignments` | Penempatan user pada toko |
| `cloud.user_role_assignments` | Role user beserta scope |
| `cloud.terminal_authorizations` | Izin penggunaan terminal non-primary |
| `cloud.user_security_events` | Audit perubahan keamanan dan otorisasi |

Cache PIN/role offline dikirim hanya ke toko yang relevan dan berlaku maksimal 24 jam sejak sinkronisasi otorisasi sukses.

### 2.3 Master data dan kebijakan

| Tabel | Fungsi utama |
|---|---|
| `cloud.categories` | Kategori produk |
| `cloud.products` | Master SKU/produk |
| `cloud.product_barcodes` | Satu atau lebih barcode per SKU |
| `cloud.product_prices` | Riwayat harga dan masa efektif |
| `cloud.product_tax_rules` | Aturan pajak produk |
| `cloud.product_store_availability` | Ketersediaan produk per toko |
| `cloud.product_display_order` | Urutan tampilan/favorit produk |
| `cloud.uoms` | Satuan yang diperlukan POS |
| `cloud.promotions` | Header promosi |
| `cloud.promotion_conditions` | Syarat promosi |
| `cloud.promotion_benefits` | Benefit/diskon promosi |
| `cloud.promotion_products` | Relasi promosi-produk |
| `cloud.promotion_quotas` | Kuota global promosi |
| `cloud.promotion_quota_allocations` | Grant kuota per toko |
| `cloud.payment_methods` | Metode pembayaran aktif |
| `cloud.store_hours` | Jam operasional reguler |
| `cloud.store_exceptions` | Hari libur/jam khusus |
| `cloud.cash_drawer_policies` | Kebijakan modal awal laci/terminal |
| `cloud.receipt_policies` | Kebijakan struk dan cetak ulang |
| `cloud.customers` | Identitas pelanggan canonical |
| `cloud.customer_phone_aliases` | Nomor telepon aktif dan alias identitas pelanggan |
| `cloud.customer_merge_events` | Riwayat auto-merge pelanggan dan konflik field |

Auto-merge pelanggan memakai nomor telepon aktif yang dinormalisasi ke E.164. ID canonical tertua dipertahankan; ID lain menjadi alias. Konflik field non-kosong dicatat, tidak ditimpa otomatis.

### 2.4 Distribusi master

| Tabel | Fungsi utama |
|---|---|
| `cloud.master_change_log` | Log perubahan master untuk global/toko tertentu |
| `cloud.master_stream_counter` | Counter commit-ordered untuk stream master |
| `cloud.store_master_cursors` | Cursor master yang telah diterapkan per node/store |
| `cloud.master_snapshots` | Metadata snapshot bootstrap |

## 3. Schema `ingest` — penerimaan dan pemulihan event

| Tabel | Fungsi utama |
|---|---|
| `ingest.received_events` | Envelope, payload, hash, status proses, dan waktu retensi raw event |
| `ingest.aggregate_cursors` | Versi terakhir yang diproses per source node dan aggregate |
| `ingest.delivery_attempts` | Riwayat penerimaan, retry, dan hasil per event |
| `ingest.replay_actions` | Audit replay, skip, atau penutupan dead-letter |
| `ingest.node_sync_status` | Ringkasan backlog, keberhasilan terakhir, dan error per node/stream |

Catatan desain:
- Raw payload sukses diproses dipertahankan 90 hari.
- Dead-letter dipertahankan sampai diselesaikan; setelah selesai minimal 1 tahun sejak pertama masuk dead-letter.
- Metadata deduplikasi/cursor yang dibutuhkan untuk mencegah event lama diproses ulang dapat memiliki retensi berbeda dari raw payload.
- Penghapusan payload tidak boleh menghapus fakta hasil proyeksi.
- Replay, skip, dan penghapusan wajib tercatat di audit.

## 4. Schema `replica` — fakta transaksi toko

| Tabel | Fungsi utama |
|---|---|
| `replica.sales` | Header sale final/PAID |
| `replica.sale_lines` | Snapshot detail produk, qty, harga, diskon dan pajak |
| `replica.sale_discounts` | Diskon otomatis/manual |
| `replica.sale_promotion_cancellations` | Pembatalan promosi beserta alasan |
| `replica.payments` | Pembayaran terkonfirmasi dan split tender |
| `replica.payment_evidence` | Metadata bukti pembayaran dan protected object reference |
| `replica.refunds` | Header refund final |
| `replica.refund_lines` | Detail refund dan status kondisi barang |
| `replica.refund_payments` | Breakdown payout refund |
| `replica.cash_sessions` | Sesi kasir, expected/actual/variance |
| `replica.cash_ledger_entries` | Cash in/out |
| `replica.cash_handover_events` | Serah terima kasir |
| `replica.cash_deposits` | Setoran kas |
| `replica.audit_events` | Audit event yang dikirim dari toko |

`replica.payment_evidence`* adalah usulan eksplisit untuk memisahkan metadata bukti pembayaran dari row pembayaran. Diputuskan menggunakan tabel terpisah agar siklus hidup bukti, verifikasi checksum, akses object storage, dan audit dapat dikelola independen dari pembayaran. File binary disimpan di private object storage, bukan PostgreSQL.

Semua fakta transaksi menyimpan identitas asal, minimal source store/node/entity, waktu asal, waktu diterima, dan business date bila relevan. Transaksi pending tidak direplikasi; hanya `sale.paid` yang menjadi fakta sale cloud.

## 5. Schema `reporting` — proyeksi rebuildable

| Tabel | Fungsi utama |
|---|---|
| `reporting.daily_store_sales` | Ringkasan omzet, transaksi, diskon, pajak, refund dan net sales |
| `reporting.daily_product_sales` | Qty dan nilai penjualan per SKU/toko/tanggal |
| `reporting.daily_cashier_sales` | Penjualan per kasir/toko/tanggal |
| `reporting.daily_payment_totals` | Total pembayaran per metode/toko/tanggal |
| `reporting.daily_promotion_totals` | Penggunaan dan diskon promosi |
| `reporting.sync_health_daily` | Ringkasan kesehatan sinkronisasi |

Reporting bukan sumber kebenaran dan harus dapat dibangun ulang dari schema `replica` serta status ingest yang relevan.

## 6. Hal yang harus diselesaikan sebelum DDL

1. Tetapkan kolom, tipe data, nullability, PK/FK, unique constraint, dan check constraint per tabel.
2. Tentukan pemisahan data master global vs scoped per toko dan aturan tenant isolation.
3. Tetapkan strategi partisi dan registry idempotensi global lintas partisi.
4. Tentukan relasi detail antara sale, payment, refund, audit, dan bukti pembayaran.
5. Putuskan apakah `replica.payment_evidence` menjadi tabel tersendiri.
6. Tetapkan indeks berdasarkan query API, rekonsiliasi, dan laporan yang nyata.
7. Tentukan backup cloud, RPO/RTO, PITR, dan uji restore.
8. Uji migration dan extension pada PostgreSQL 16 serta versi mayor lebih baru yang akan dipilih.

## 7. Batas dokumen

Inventaris ini adalah daftar entitas logis awal, bukan DDL atau migration. Tidak boleh digunakan untuk provisioning produksi sebelum kolom, constraint, akses, retensi, partisi, backup, dan uji kompatibilitas disetujui.
