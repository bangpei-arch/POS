# Batas Database Server Toko dan Cloud POS

**Versi:** 0.1  
**Tanggal:** 31 Oktober 2026  
**Status:** Keputusan arsitektur dan rancangan batas data; belum merupakan migration cloud.

## 1. Keputusan arsitektur

1. Database pada `database/migrations/001_initial_schema.sql` diperlakukan sebagai **database operasional server toko**.
2. Setiap toko memiliki satu local server dan satu database operasional sendiri.
3. Database cloud dirancang terpisah, dengan migration, ERD, backup, hak akses, dan siklus rilis sendiri.
4. Cloud adalah sumber otoritatif untuk master bersama dan penerima salinan konsolidasi transaksi toko.
5. Local server adalah sumber transaksi operasional toko: penjualan, pembayaran, refund, kas, dan audit asal.
6. Tidak ada replikasi PostgreSQL dua arah atau penulisan langsung ke database toko dari cloud.
7. Perubahan master dikirim cloud ke toko sebagai event/versioned snapshot. Transaksi toko dikirim ke cloud melalui outbox/inbox.
8. Terminal tetap menyimpan transaksi secara durable di IndexedDB ketika local server/LAN tidak tersedia. Saat pulih, terminal mengirim transaksi ke local server; setelah tersimpan di local server, event diteruskan ke cloud.

## 2. Kepemilikan data per domain

| Domain | Pemilik otoritatif | Salinan di server toko | Salinan di cloud |
|---|---|---|---|
| Toko dan terminal | Cloud | Scope toko + cache registry | Master seluruh toko |
| Pengguna, role, permission | Cloud | Cache subset pengguna/role toko untuk autentikasi offline | Master IAM |
| Produk, kategori, barcode, UoM | Cloud | Cache read-only | Master produk |
| Harga dan pajak | Cloud | Cache versi efektif | Master harga/pajak |
| Ketersediaan produk toko | Cloud | Cache per toko | Master ketersediaan |
| Promosi dan batas diskon | Cloud | Cache aturan terbit | Master promosi |
| Pelanggan | Cloud untuk data kanonik; toko boleh membuat data pending saat offline | Cache + registrasi pending | Master + proses merge |
| Cart dan Hold Order | Server toko/terminal pembuat | Data operasional toko | Tidak perlu menjadi data operasional cloud |
| Penjualan dan detail | Server toko asal | Data utama transaksi toko | Salinan konsolidasi immutable |
| Pembayaran dan bukti | Server toko asal | Data utama dan audit pembayaran | Salinan konsolidasi sesuai kebijakan bukti |
| Refund dan detailnya | Server toko asal | Data utama refund | Salinan konsolidasi immutable |
| Kas dan sesi kasir | Server toko asal | Data operasional toko | Salinan konsolidasi |
| Stok | Sistem inventory otoritatif di luar POS | Cache terakhir dari API inventory | Integrasi/snapshot bila diperlukan |
| Audit | Node yang melakukan aksi | Audit lokal | Konsolidasi audit |
| Printer dan print job | Konfigurasi printer terminal lokal; kebijakan dapat dari cloud | Konfigurasi dan job lokal | Kebijakan/telemetri bila dibutuhkan |
| Alert dan backup | Node masing-masing | Status lokal dan riwayat | Monitoring konsolidasi |

## 3. Klasifikasi tabel migration 001

### 3.1 Master cloud, direplikasi sebagai cache ke toko

- `org_stores`
- `org_terminals`
- `org_store_servers`
- `iam_users`
- `iam_roles`
- `iam_permissions`
- `iam_role_permissions`
- `iam_user_store_assignments`
- `iam_user_role_assignments`
- `iam_terminal_authorizations`
- `md_categories`
- `md_products`
- `md_product_barcodes`
- `md_product_prices`
- `md_product_tax_rules`
- `md_product_store_availability`
- `md_product_display_order`
- `md_uoms`
- `md_promotions`
- `md_promotion_conditions`
- `md_promotion_benefits`
- `md_promotion_products`
- `md_promotion_quotas`
- `md_manual_discount_limits`
- `md_payment_methods`
- `ops_store_hours`
- `ops_store_exceptions`

**Catatan:** salinan lokal hanya memuat data yang diperlukan toko. Data master lokal bersifat cache; perubahan dilakukan melalui cloud dan disebarkan dengan versioning. Data IAM yang dibutuhkan untuk login offline harus memiliki kebijakan cache, expiry, dan pencabutan akses yang eksplisit.

### 3.2 Data kanonik cloud dengan operasi lokal terbatas

- `md_customers`: cloud menyimpan profil kanonik; toko boleh membuat pelanggan pending saat offline.
- `md_customer_phone_aliases`: cloud mengelola alias kanonik; local dapat menampung alias pending bila diperlukan.
- `md_customer_merge_events`: merge final dilakukan cloud; local menerima hasil merge.
- `md_promotion_usage`: penggunaan dicatat di toko sebagai sumber kejadian transaksi, lalu dikonsolidasikan cloud. Kuota global ketat tidak boleh diasumsikan konsisten ketika toko offline.

### 3.3 Transaksi yang sumber kebenarannya server toko

- `pos_carts`
- `pos_cart_lines`
- `pos_hold_orders`
- `pos_cart_events`
- `pos_sales`
- `pos_sale_lines`
- `pos_sale_status_events`
- `pos_sale_number_sequences`
- `pos_sale_discounts`
- `pos_promotion_cancellations`
- `pos_payments`
- `pos_payment_evidence`
- `pos_payment_events`
- `pos_refunds`
- `pos_refund_lines`
- `pos_refund_payments`
- `pos_refund_events`
- `cash_drawers`
- `cash_drawer_float_history`
- `cash_sessions`
- `cash_ledger_entries`
- `cash_handover_events`
- `cash_deposits`
- `cash_session_events`

Cloud menerima salinan transaksi setelah event tervalidasi dan tersimpan. Cloud tidak mengubah transaksi asal. Koreksi transaksi dilakukan di toko melalui alur refund/reversal yang diaudit.

### 3.4 Operasional node dan sinkronisasi

- `sync_nodes`: registry node dikelola cloud; local memiliki cache node yang relevan.
- `sync_outbox`: antrean event keluar milik node yang menerbitkan event.
- `sync_inbox`: antrean event masuk milik node penerima.
- `sync_delivery_attempts`: riwayat pengiriman pada node pengirim.
- `sync_checkpoints`: checkpoint per node dan stream.
- `sync_master_versions`: versi master yang diterbitkan cloud dan versi terakhir yang diterapkan toko.
- `sync_inventory_events`: antrean integrasi event POS ke sistem inventory.
- `md_stock_cache`: cache stok pada server toko, bukan sumber stok otoritatif.
- `org_terminal_status`: telemetri terminal; direkam lokal lalu dikirim sebagai telemetri ke cloud bila diperlukan.
- `ops_terminal_printers`, `ops_print_jobs`, `ops_reprint_events`: konfigurasi/job lokal dan riwayat cetak.
- `ops_alerts`: alert lokal dan salinan ringkas untuk monitoring pusat.
- `ops_backup_runs`: metadata backup node lokal/cloud; artefak backup tetap berada pada storage backup node terkait.

### 3.5 Audit

- `audit_events`: ditulis pada node tempat aksi terjadi; cloud menerima salinan.
- `audit_deletion_events`: pencatatan penghapusan audit harus dilakukan pada node yang memiliki kewenangan penghapusan; cloud menyimpan jejak konsolidasi.
- `iam_pin_reset_events`: reset oleh supervisor lokal dapat dicatat lokal; kebijakan dan identitas tetap berasal dari cloud. Event harus disinkronkan.

## 4. Aturan sinkronisasi dan konflik

### 4.1 Cloud ke toko (master)

- Setiap perubahan master mempunyai `entity_type`, `entity_id`, `version`, `effective_at`, dan `published_at`.
- Local menerapkan versi lebih baru secara idempotent.
- Snapshot harga/pajak pada cart atau transaksi yang telah dibuka tidak boleh diubah oleh master baru.
- Local menyimpan versi terakhir dan waktu sinkronisasi; UI menunjukkan master stale jika melewati ambang yang ditentukan.
- Pencabutan user/produk/promosi mengikuti kebijakan offline dan masa berlaku cache; jangan menganggap pencabutan langsung berlaku pada toko yang sedang terputus.

### 4.2 Toko ke cloud (transaksi)

- Local menulis transaksi dan outbox event dalam satu transaksi PostgreSQL.
- Pengiriman menggunakan `event_id`, `idempotency_key`, `schema_version`, dan `aggregate_version`.
- Cloud memasukkan event ke inbox secara idempotent.
- Perubahan data cloud dan status inbox `processed` harus commit atomik.
- ACK hanya dikirim setelah commit berhasil.
- Pengiriman ulang event yang sama tidak boleh menggandakan transaksi, pembayaran, refund, atau ledger.
- Cloud menyimpan transaksi per `source_store_id` dan `source_node_id`; UUID transaksi asal tetap dipertahankan.
- Konflik transaksi tidak diselesaikan dengan last-write-wins. Transaksi toko adalah append-only setelah PAID; masalah data ditangani melalui event koreksi/reversal.

### 4.3 Recovery

- Event `sending` harus memakai lease/claim timeout agar dapat diambil ulang setelah worker mati.
- Worker mengklaim batch dengan `FOR UPDATE SKIP LOCKED`.
- Retry memakai exponential backoff dan jitter; error permanen masuk status `failed` dan membutuhkan intervensi.
- Checkpoint bergerak hanya setelah ACK dari penerima.
- Event dalam satu aggregate diproses sesuai `aggregate_version`; versi lompat ditahan sampai event sebelumnya tersedia atau direkonsiliasi.
- Dead-letter/failed event tidak dihapus otomatis; retry manual harus tercatat.

## 5. Perbedaan migration

- `database/migrations/001_initial_schema.sql` sampai migration lokal berikutnya adalah baseline dan migration **server toko**.
- Migration cloud dibuat pada direktori terpisah, misalnya `database/cloud/migrations/`.
- Migration cloud tidak boleh menyalin semua tabel lokal secara otomatis.
- Nama dan tipe kolom yang sama boleh dipakai jika ada alasan domain, tetapi kepemilikan, constraint, indeks, retensi, dan volume cloud harus dirancang khusus.
- Jangan jalankan migration lokal 001–003 pada database cloud.
- Database cloud harus memiliki test sendiri untuk penerimaan event dari beberapa toko, idempotency lintas node, konsolidasi laporan, dan penerbitan master.

## 6. Tabel cloud yang perlu dirancang pada tahap berikutnya

Rancangan cloud akan mencakup kelompok berikut, bukan menyalin schema toko:
1. Registry toko, server toko, terminal, dan node.
2. IAM pusat, role, permission, dan distribusi cache autentikasi.
3. Master produk, harga, pajak, promosi, metode pembayaran, dan kalender toko.
4. Pelanggan kanonik, alias nomor, serta proses merge.
5. Penerimaan transaksi toko: sale, line, payment, refund, cash, audit sebagai replika immutable.
6. Inbox/outbox pusat untuk event toko dan distribusi master.
7. Status sinkronisasi per toko, checkpoint, dead-letter, dan monitoring.
8. Model laporan konsolidasi dan agregasi harian/per toko.
9. Retensi, arsip, legal hold, dan backup cloud.

## 7. Hal yang belum boleh dianggap selesai

- Dokumen ini menetapkan batas kepemilikan data; belum mendefinisikan seluruh DDL cloud.
- Strategi kuota promosi global ketika offline masih membutuhkan kebijakan alokasi kuota.
- Cache autentikasi offline memerlukan expiry dan prosedur pencabutan akses.
- Bukti pembayaran dan data pelanggan memerlukan kebijakan retensi/akses terpisah.
- Kontrak event dan payload API harus difinalisasi sebelum implementasi sinkronisasi.
- Test pemulihan terminal-local-server-cloud belum menggantikan test concurrency database.
