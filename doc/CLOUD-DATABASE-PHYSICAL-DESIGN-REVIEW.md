# Review Desain Fisik Database Cloud POS

**Review:** 1  
**Tanggal:** 31 Oktober 2026  
**Status:** Temuan awal; perbaikan sedang diterapkan pada desain fisik v0.2.  
**Cakupan:** Physical design, inventory, logical cloud design, local/cloud boundary, dan sync contract.  
**Tidak termasuk:** implementasi aplikasi, FastAPI, worker runtime, dan migration database toko.

## Ringkasan

Draft v0.1 sudah memiliki pemisahan schema yang tepat, tetapi belum aman dijadikan DDL. Temuan paling penting adalah integritas tenant lintas FK, ketidakcocokan partition key dengan FK, beberapa master domain yang belum terwakili, dan aturan finality/retensi yang belum dapat ditegakkan oleh struktur tabel.

## Temuan prioritas tinggi

### R1 — Foreign key belum mengunci kepemilikan store/node (HIGH)
Beberapa tabel menyimpan `store_id` dan `node_id` secara terpisah tetapi FK hanya memeriksa keberadaan masing-masing. Akibatnya secara struktural node toko A dapat mengirim record dengan store_id toko B.
**Perbaikan:** tambahkan unique key komposit pada registry node/server/terminal dan FK komposit `(source_node_id,source_store_id)` ke node yang terdaftar; terapkan juga pada ingest dan replica. API authorization tetap wajib.

### R2 — FK child replica dapat mengarah ke header toko lain (HIGH)
FK seperti `sale_lines.sale_id → sales.id` tidak memastikan `sale_lines.source_store_id` sama dengan store header.
**Perbaikan:** unique key komposit pada header dan composite FK `(sale_id,source_store_id)`; terapkan pola yang sama pada discounts, payments, evidence, refunds, cash detail. Source references ke transaksi lintas event menggunakan source entity registry dengan entity_type.

### R3 — Partitioning received_events bertentangan dengan FK saat ini (HIGH)
Jika `received_events` dipartisi berdasarkan `received_at`, PostgreSQL mengharuskan unique/PK partitioned table menyertakan partition key. FK dari `delivery_attempts` dan registry yang hanya memakai `received_event_id` tidak dapat dipertahankan seperti draft.
**Perbaikan:** jangan partisi `received_events` pada DDL awal. Retensi payload dapat dilakukan dengan mengosongkan payload; evaluasi partisi baru setelah desain composite key/FK dan load test. Metadata idempotensi tetap non-partitioned.

### R4 — Master manual discount limit hilang (HIGH)
Database lokal memiliki `md_manual_discount_limits`, dan spesifikasi POS menetapkan batas diskon manual supervisor. Inventaris dan cloud physical design belum memiliki padanan.
**Perbaikan:** tambahkan `cloud.manual_discount_limits`, dengan scope role/user/toko, max_percent, max_amount, masa efektif, versi dan audit publisher.

### R5 — Konsumsi alokasi kuota promo tidak memiliki fakta transaksi eksplisit (HIGH)
Grant kuota per toko sudah ada, tetapi event `sale.paid` membawa `allocation_id` dan jumlah konsumsi tanpa tabel fakta untuk menghubungkan sale, promotion, allocation dan quantity.
**Perbaikan:** tambahkan `replica.promotion_quota_consumptions`; konsumsi unik per sale/allocation dan direkonsiliasi atomik/idempotent terhadap `cloud.promotion_quota_allocations`.

### R6 — Offline PIN cache belum memiliki struktur kredensial (HIGH)
`cloud.users` belum menyimpan atau merujuk hash PIN yang dapat didistribusikan secara terproteksi ke cache lokal maksimal 24 jam.
**Perbaikan:** tambahkan `cloud.user_pin_credentials` yang hanya menyimpan hash Argon2id, versi credential, status, masa berlaku, dan waktu rotasi. PIN plaintext tidak disimpan/log. Distribusi ke store tetap melalui master package terenkripsi; local cache expiry 24 jam.

### R7 — Bukti pembayaran default status tidak konsisten (HIGH)
`replica.payment_evidence.status` default `verified`, padahal upload dan checksum verification dapat berlangsung setelah sale PAID.
**Perbaikan:** default `pending_upload`; `verified` wajib memiliki verified_at; hanya set verified setelah checksum/size/MIME/object metadata tervalidasi. Tambahkan composite FK agar evidence hanya terhubung ke payment dan sale yang sama.

### R8 — Child references mencampur source ID dengan cloud PK (HIGH)
`sale_discounts.source_sale_line_id` dinyatakan FK ke `replica.sale_lines`, padahal namanya menunjukkan ID lokal asal. ID lokal tidak sama dengan UUID PK cloud.
**Perbaikan:** gunakan `sale_line_id` untuk FK internal cloud; simpan `source_sale_line_id` sebagai source identifier non-FK atau resolve lewat `replica.source_entity_registry`.

## Temuan prioritas menengah

### R9 — Identitas terminal node belum unik (MEDIUM)
`sync_nodes.store_server_id` unique tetapi `terminal_id` belum. Tambahkan unique untuk terminal node dan composite ownership constraints.

### R10 — Active server policy belum tegas (MEDIUM)
Arsitektur menetapkan satu local server per toko. Desain saat ini membiarkan lebih dari satu server berstatus active.
**Perbaikan:** partial unique `store_id WHERE status='active'`; server lama saat penggantian menjadi draining/disabled setelah transfer/fencing selesai. Node overlap hanya untuk status non-active yang ditentukan.

### R11 — Temporal uniqueness/policy tidak lengkap (MEDIUM)
Price/tax ranges, store hours, receipt policy, cash drawer policy perlu aturan no-overlap dan update serialisasi. Predicate index tidak boleh memakai `now()`.
**Perbaikan:** tanpa extension `btree_gist` pada baseline. Gunakan lock pada parent entity dan trigger/service validation dalam transaksi untuk mencegah overlap. Tambahkan unique active row yang eksplisit dengan status/current flag yang dikelola transaksi.

### R12 — Master change uniqueness nullable belum final (MEDIUM)
`target_store_id NULL` membutuhkan NULL-safe uniqueness.
**Perbaikan:** PostgreSQL 16 mendukung `UNIQUE NULLS NOT DISTINCT`; gunakan constraint tersebut.

### R13 — Cross-event dependency refund belum punya relational registry contract (MEDIUM)
Refund hanya menyimpan UUID source sale/line tanpa constraint yang menghubungkannya dengan source registry.
**Perbaikan:** tambahkan source entity registry typed; validasi original sale dan line melalui `entity_type='sale'` dan `entity_type='sale_line'` sebelum projection commit.

### R14 — Retention audit harus tetap ada setelah payload dihapus (MEDIUM)
Retention actions sudah ditambahkan, tetapi target metadata/partition retention dan legal hold perlu dijelaskan.
**Perbaikan:** retensi payload dipisah dari dedupe registry; retention action append-only dan tidak ikut dipurge; semua purge memeriksa legal hold.

### R15 — Inventory dan physical design perlu sinkron (MEDIUM)
Tabel baru `replica.source_entity_registry` dan `ingest.retention_actions` sudah ada di physical design tetapi inventory belum lengkap/seragam; manual discount dan promotion consumption juga perlu dimasukkan.
**Perbaikan:** samakan inventory setelah revisi fisik.

## Keputusan implementasi desain yang direkomendasikan

1. Tidak mengaktifkan partisi untuk `ingest.received_events` pada migration awal; simpan sebagai tabel biasa sampai volume membuktikan kebutuhan.
2. Tidak mewajibkan extension `btree_gist`; pakai transaksi serialisasi untuk overlap check.
3. Tambahkan composite FKs untuk tenant/store/node isolation, bukan mengandalkan API saja.
4. Buat `replica.source_entity_registry` sejak awal.
5. Fakta replica dibuat append-only melalui privilege database dan trigger proteksi; service role hanya INSERT/SELECT, bukan UPDATE/DELETE.
6. Hash PIN Argon2id; cloud hanya distribusikan hash terproteksi, bukan PIN.
7. Evidence dimulai `pending_upload`, berubah ke `verified` setelah verifikasi object storage.
8. Promotion quota consumption menjadi fakta eksplisit dan idempotent.

## Urutan perbaikan

1. Revisi physical design dan inventory untuk R1–R15.
2. Audit ulang daftar tabel/kolom/FK dan referensi silang.
3. Finalisasi event schema yang diperlukan untuk membentuk row cloud.
4. Susun DDL cloud terpisah pada `database/cloud/migrations/`.
5. Jalankan CI PostgreSQL 16, constraint tests, multi-store isolation, duplicate/replay, concurrency quota, retention, dan restore test.

DDL belum boleh dipakai produksi sampai semua langkah tersebut lolos.
