# MVP POS End-to-End — Batas Implementasi dan Kriteria Selesai

Versi 0.1 | 31 Oktober 2026 | Baseline scope MVP

## 1. Tujuan

Membangun satu alur POS yang benar-benar berjalan dari terminal toko sampai transaksi terlihat di pusat. MVP bukan implementasi seluruh spesifikasi POS dan bukan desain final untuk semua skenario. Struktur dibuat cukup aman untuk dikembangkan, tetapi fitur di luar satu alur penjualan ditunda.

Definition of Done: satu transaksi uji dibuat di terminal, disimpan durable di database toko, dibayar dan menjadi PAID, masuk outbox, dikirim otomatis oleh sender, divalidasi cloud, disimpan sebagai transaksi replika, memperoleh ACK, dan muncul pada laporan pusat. Pengujian mencakup retry setelah timeout dan event duplikat tanpa transaksi ganda.

## 2. Satu vertical slice

1. Store server dan terminal terdaftar di cloud.
2. Store server memperoleh OAuth2 Client Credentials token.
3. Store menarik bootstrap master minimal: produk aktif, harga aktif, metode pembayaran, dan metadata toko.
4. Kasir login dengan akun lokal yang sudah diprovisikan; membuka sesi kas.
5. Terminal mencari/memilih produk, mengubah kuantitas, dan membuat cart.
6. Store API memvalidasi harga snapshot, session aktif, dan total; menyimpan sale header, lines, payment, serta outbox dalam satu transaksi database.
7. Pembayaran MVP: cash dan transfer/QRIS. Non-cash dikonfirmasi manual setelah verifikasi di luar sistem; split tender dan unggah bukti ditunda. Hanya transaksi PAID diterbitkan sebagai sale.paid.
8. Receipt 80mm; PDF/print preview boleh menjadi fallback saat pengujian.
9. Store Sender Worker mengirim event sale.paid; retry memakai claim lease dan fencing dari migration lokal 004.
10. Cloud Receiver memvalidasi JWT, node/store ownership, payload schema, hash, aggregate version, dan total transaksi. Dalam satu transaksi cloud, simpan dedupe registry, raw event, sale header, lines, payments, dan status processed.
11. Cloud mengembalikan final ACK hanya setelah commit. Store menandai outbox sent setelah ACK.
12. Dashboard/laporan pusat menampilkan penjualan berdasarkan toko, tanggal, receipt, dan nilai total.

## 3. Scope yang masuk MVP

### Termasuk
- Satu toko uji, satu store server, satu terminal; skema tetap menyimpan store/node ID agar multi-store tidak perlu dibongkar.
- Login lokal, buka sesi kas, pilih produk, cart, pembayaran, PAID, receipt.
- Master bootstrap read-only dari cloud untuk produk, harga, dan metode pembayaran.
- Cash dan satu metode non-cash (transfer/QRIS); non-cash dikonfirmasi manual.
- Sale snapshot SKU/nama/harga/kuantitas/pajak/diskon/total dan payment snapshot.
- Local PostgreSQL + transactional outbox.
- OAuth2 client credentials, JWT short-lived, HTTPS.
- Sender worker, retry, idempotensi, aggregate ordering.
- Cloud PostgreSQL 16+, receiver, replica transaction tables, dedupe, raw event retention.
- Audit allowlist untuk tindakan yang memang ada di MVP.
- Dashboard pusat sederhana atau query/report endpoint.
- Docker Compose dev, migration cloud terpisah, integration test end-to-end.

### Ditunda setelah MVP
- Refund dan return stock.
- Promotion engine dan quota grant.
- Manual discount dan approval supervisor.
- Split tender.
- Bukti pembayaran object storage.
- Customer registration/merge.
- Offline login authorization refresh dan cache 24 jam penuh; MVP memakai akun lokal yang diprovisikan dan login memerlukan store server aktif. Offline sales saat internet-cloud putus tetap didukung setelah login lokal berhasil.
- Multi-terminal concurrency, multi-server failover, server replacement workflow.
- Master incremental change stream; MVP menggunakan bootstrap snapshot/version sederhana.
- Audit export/retention console, retention purge scheduler, replay/skip admin UI.
- Cash handover, deposit, cash in/out, reconciliation.
- Refund reporting, cashier/promotion analytics, scheduled email.
- Partisi tabel, read replicas, RLS, object storage evidence.
- PWA terminal fallback queue saat store server/LAN mati; MVP pertama mensyaratkan terminal dapat menjangkau store server. Local DB + outbox tetap menjaga transaksi saat koneksi internet ke cloud terputus.
- Full RBAC matrix, PIN reset workflow, advanced monitoring/alerts.
- Inventory deduction API integration; MVP cloud report only dan tidak mengubah stok.

## 4. Batas audit

Gunakan allowlist; jangan mengirim seluruh row audit lokal secara mentah.

Audit MVP yang dikirim:
- auth.login_failed
- cash_session.opened
- cash_session.closed
- sale.payment_confirmed
- sale.paid
- receipt.reprinted hanya bila reprint MVP diaktifkan
- sync.delivery_failed setelah retry threshold bila tersedia

Payload audit hanya berisi actor source ID, store/node/terminal, action, entity type/id, timestamp, reason bila relevan, correlation ID. Jangan pernah mengirim PIN/hash PIN, password/client secret/JWT, bukti pembayaran, full customer PII, atau raw before/after JSON. sale.paid adalah event bisnis; audit event bukan pengganti transaksi.

## 5. Retensi MVP

- Raw event payload processed: 90 hari; setelah itu hapus payload tetapi pertahankan dedupe key/hash/status untuk mencegah transaksi ganda.
- Dead-letter/permanent failure: sampai diselesaikan, minimal satu tahun.
- Replica transaksi: 5 tahun, legal hold mengecualikan purge.
- Audit: 3 tahun.
- Purge scheduler dapat ditunda sampai setelah MVP, tetapi timestamp dan status retensi harus tersedia.

## 6. Prinsip desain yang tidak boleh dikompromikan

- Satu transaksi bisnis hanya direplikasi setelah status PAID.
- Pending/unconfirmed payment tetap lokal.
- Store transaction + outbox ditulis atomik.
- Cloud projection + event final status ditulis atomik.
- ACK setelah commit saja.
- Idempotensi dan uniqueness diuji dengan retry/duplicate.
- Nominal memakai decimal/numeric, bukan float.
- Snapshot transaksi tidak bergantung pada master product yang dapat berubah.
- Tenant FK dan token claims mencegah node toko A mengirim transaksi sebagai toko B.
- Cloud database dan migration terpisah dari migration lokal pos.

## 7. Urutan delivery

| Tahap | Hasil nyata | Gate |
|---|---|---|
| M0 | Cloud DDL MVP + local/cloud mapping + payload JSON Schema | Migration fresh PostgreSQL 16 lulus |
| M1 | Cloud OAuth/token + bootstrap master endpoint | Store server dapat auth dan menerima master |
| M2 | Store API sale/payment/PAID + receipt | Satu transaksi lokal lulus test |
| M3 | Sender worker + cloud receiver + dedupe | Sale sampai cloud dan ACK |
| M4 | Central report + E2E test + retry/duplicate test | Definition of Done tercapai |
| M5 | Pilot satu toko dan hardening terukur | Baru putuskan fitur tahap berikutnya |

Jangan mulai fitur yang ditunda sebelum M4 selesai. Jangan membuat ulang seluruh 71-table cloud schema untuk MVP; gunakan migration MVP ramping dan evolutif. Physical design lengkap tetap menjadi referensi target jangka panjang, bukan daftar wajib untuk rilis pertama.

## 8. Cara kerja

- Asisten mengerjakan perubahan repository, dokumen, migration, kontrak, dan test yang dapat dikerjakan melalui GitHub.
- Pengguna menjalankan dan memvalidasi perintah lokal di Debian, karena runtime lokal pengguna tidak dapat dieksekusi langsung dari sini.
- Tidak meminta konfirmasi untuk keputusan implementasi biasa. Gunakan rekomendasi aman dan catat asumsi.
- Hanya eskalasi hal kritikal: risiko kehilangan/duplikasi uang atau transaksi, keamanan credential, perubahan data produksi, keputusan tidak dapat dibalik, atau akses/secret yang hanya pengguna dapat sediakan.
- Semua milestone diuji sebelum maju; jangan mengklaim selesai tanpa hasil test.
