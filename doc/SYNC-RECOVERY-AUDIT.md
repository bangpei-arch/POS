# Audit Pemulihan Sinkronisasi POS

**Versi:** 0.2  
**Tanggal:** 31 Oktober 2026  
**Status:** Desain recovery dan ordering difinalisasi untuk baseline database lokal; migration 004 dan regression tests sedang divalidasi CI. Belum ada worker/API runtime.

## 1. Ruang lingkup

Audit ini membandingkan struktur sinkronisasi pada migration lokal 001 dan dokumen `DATABASE-BOUNDARIES-LOCAL-CLOUD.md`. Fokusnya adalah pemulihan worker, lease/claim, urutan event, idempotency, ACK, retry, dan antrean integrasi inventory.

Belum ada implementasi worker/API yang diaudit. Karena itu, temuan tentang perilaku runtime di bawah adalah **belum terbukti**, bukan klaim bahwa implementasi tersebut salah.

## 2. Temuan struktur saat ini

### 2.1 `sync_outbox`

Kolom saat ini mencakup `node_id`, `event_id`, `aggregate_type`, `aggregate_id`, `event_type`, `payload`, `schema_version`, `status`, `attempts`, `next_retry_at`, `last_error`, `occurred_at`, dan `sent_at`.

Kesenjangan terhadap dokumen arsitektur:

- Belum ada `aggregate_version` atau nomor urut per aggregate.
- Belum ada `claimed_at`, `lease_until`, atau identitas worker pemilik claim.
- Tidak ada kolom yang menyimpan respons ACK penerima atau waktu ACK terpisah; `sent_at` belum didefinisikan secara eksplisit sebagai waktu ACK sukses.
- Indeks due queue ada pada `(status, next_retry_at, occurred_at)`, tetapi belum ada indeks untuk pemulihan lease yang kedaluwarsa atau pengambilan event berikutnya per aggregate.

Konsekuensi desain: status `sending` tidak dapat dipulihkan secara aman berdasarkan batas waktu hanya dari kolom yang tersedia. Urutan event per aggregate juga belum dapat ditegakkan dari metadata tabel.

### 2.2 `sync_inbox`

Kolom saat ini mencakup `source_node_id`, `event_id`, `idempotency_key`, `received_at`, `processing_status`, dan `response_payload`.

Kesenjangan/hal yang perlu diputuskan:

- Tidak ada metadata claim/lease untuk pemrosesan inbox bila proses penerimaan dibuat asynchronous.
- `UNIQUE(source_node_id, event_id)` sudah memberi deduplikasi identitas event per node.
- `UNIQUE(idempotency_key)` saat ini bersifat global dalam database penerima. Perlu dipastikan apakah key memang dijamin global lintas node; bila tidak, scope yang lebih tepat adalah per source node.
- Belum ada kolom untuk versi aggregate yang diterima atau alasan penahanan karena versi sebelumnya belum tersedia.

### 2.3 Checkpoint dan delivery attempts

- `sync_checkpoints` menyimpan `last_acked_at` dan `last_event_id`, tetapi belum menyimpan sequence/aggregate version yang dapat dibandingkan secara numerik.
- `sync_delivery_attempts` menyimpan riwayat percobaan pengiriman. Tidak ada relasi eksplisit antara attempt dan lease/worker claim.
- Tidak ada test yang saat ini membuktikan bahwa checkpoint hanya bergerak setelah ACK sukses.

### 2.4 `sync_inventory_events`

Tabel inventory memiliki status, attempts, next_retry_at, dan last_error, tetapi belum memiliki lease/claim metadata dan tabel riwayat attempt tersendiri. Ini antrean integrasi terpisah dan tidak boleh dianggap otomatis tercakup oleh perbaikan outbox transaksi toko.

## 3. Prinsip desain yang harus dipertahankan

1. Penulisan transaksi bisnis dan outbox dilakukan dalam satu transaksi PostgreSQL.
2. Worker mengklaim batch menggunakan transaksi singkat dengan `FOR UPDATE SKIP LOCKED`; transaksi tidak dibiarkan terbuka selama HTTP request.
3. Claim mempunyai lease dengan expiry. Worker yang mati tidak boleh membuat event terkunci selamanya.
4. Pengiriman bersifat at-least-once; penerima harus idempotent.
5. Penerima menyimpan event, menerapkan perubahan bisnis, dan mengubah inbox menjadi `processed` dalam satu transaksi. ACK baru dikirim setelah commit.
6. Pengirim mengubah outbox menjadi `sent` hanya setelah menerima ACK yang valid untuk `event_id` yang sama.
7. Retry memakai exponential backoff + jitter; error permanen masuk `failed` dan tidak dihapus otomatis.
8. Urutan dijaga per aggregate, bukan urutan global seluruh toko. Event versi N+1 ditahan bila N belum diproses.
9. Retry manual harus tercatat dan tidak boleh mengubah payload atau identitas event.
10. Status `sent` berarti ACK penerima sudah dikonfirmasi, bukan sekadar HTTP request selesai dikirim.

## 4. Keputusan desain final untuk database lokal

### 4.1 Event identity dan aggregate ordering

- `event_id` adalah UUID stabil yang tidak berubah saat retry.
- `aggregate` didefinisikan sebagai satu entitas bisnis yang menjadi urutan konsistensi. Contoh: satu `sale_id`, satu `refund_id`, atau satu `customer_id`.
- Versi dialokasikan per kombinasi `node_id + aggregate_type + aggregate_id`, dimulai dari 1.
- Counter dialokasikan atomik oleh trigger melalui upsert row counter di transaksi yang sama dengan insert outbox. Unique constraint mencegah dua event memakai versi sama.
- Payload event dan identitas aggregate tidak boleh diubah setelah dibuat. Koreksi bisnis diterbitkan sebagai event baru.
- Ordering tidak global antartoko atau antarseluruh aggregate. Aggregate berbeda dapat diproses paralel.

### 4.2 Outbox sender: claim, lease, dan fencing

- Status: `pending → sending → sent`; error permanen atau batas percobaan menghasilkan `failed`.
- Claim memakai `FOR UPDATE SKIP LOCKED` dalam transaksi singkat. Transaksi claim harus commit sebelum HTTP request dimulai.
- Default lease 120 detik; rentang yang diterima fungsi database 15–900 detik. Worker wajib menyelesaikan request sebelum lease berakhir atau merancang lease lebih panjang untuk request yang memang lama.
- Setiap claim menghasilkan `claim_token` UUID baru. Token ini adalah fencing token: ACK/failure hanya diterima bila token masih sama dan lease belum kedaluwarsa.
- Worker mati ketika `sending`: setelah `lease_until`, event dapat di-claim ulang dengan token baru.
- Claim menaikkan `attempts`; maksimum default 12. Event yang habis percobaan saat lease kedaluwarsa berubah menjadi `failed`.
- Claim hanya memilih event paling awal yang belum `sent` pada aggregate tersebut. Status `failed` memblokir versi sesudahnya; tidak ada skip otomatis.

### 4.3 Retry dan delivery attempt

- Error sementara: worker menghitung exponential backoff dengan full jitter dan memanggil fungsi failure dengan waktu retry yang akan datang.
- Rumus dasar: `delay = random(0, min(cap, base × 2^(attempt-1)))`; parameter awal yang disarankan `base=2s`, `cap=15m`. Nilai ini konfigurasi worker, bukan hard-coded database.
- Error permanen (misalnya payload/schema tidak valid atau 4xx non-retryable) langsung menjadi `failed`.
- Setiap hasil attempt sukses/retry/permanent dicatat append-only pada `sync_delivery_attempts`; inventory punya tabel attempt tersendiri.
- Retry manual harus tercatat sebagai operasi administratif dan memakai event_id/payload yang sama. Tidak boleh menghapus histori attempt atau membuat transaksi bisnis baru.

### 4.4 Receiver inbox, deduplikasi, dan urutan

- Deduplikasi event: unique `(source_node_id, event_id)`.
- Idempotency key: unique `(source_node_id, idempotency_key)`, karena key tidak diasumsikan unik global lintas node.
- Event baru harus membawa `aggregate_type`, `aggregate_id`, dan `aggregate_version`. Event tanpa versi hanya dapat ditangani melalui jalur kompatibilitas/rekonsiliasi; tidak boleh masuk worker ordered-processing.
- Inbox cursor disimpan per `source_node_id + aggregate_type + aggregate_id`, mulai dari versi 0. Hanya versi `last_processed_version + 1` yang dapat di-claim.
- Event versi N+1 yang tiba lebih dahulu tetap tersimpan tetapi belum diproses. Setelah N commit, N+1 menjadi eligible.
- Inbox worker memakai lease, attempt count, dan fencing token dengan aturan yang sama seperti outbox.
- Perubahan bisnis penerima, update cursor, dan perubahan inbox ke `processed` wajib dilakukan dalam satu transaksi database. API baru mengirim ACK setelah transaksi tersebut commit.
- Event `rejected/failed` tidak memajukan cursor; versi sesudahnya tertahan sampai ada keputusan operasional yang diaudit.

### 4.5 ACK dan checkpoint

- ACK valid harus mengidentifikasi event yang sama dan dikembalikan hanya setelah commit penerima. Sender hanya menandai `sent` setelah validasi ACK.
- ACK dari worker dengan token lama atau lease kedaluwarsa ditolak, meskipun request jaringan berhasil.
- `sent_at/acked_at` berarti ACK penerima sudah dikonfirmasi, bukan waktu request mulai atau selesai dikirim.
- `sync_checkpoints.last_event_id/last_acked_at` untuk saat ini hanya metadata observabilitas. Belum ada global stream sequence yang dapat membuktikan posisi kontigu; checkpoint tersebut **tidak boleh dipakai untuk melewati event** atau melanjutkan stream dengan asumsi tidak ada gap.
- Checkpoint resume yang otoritatif baru dirancang ketika kontrak stream sequence global/per-node ditetapkan.

### 4.6 Inventory queue

- `sync_inventory_events` tetap antrean terpisah dari outbox transaksi.
- Queue inventory memakai lease, fencing token, max attempts, ACK, retry, dan tabel attempt history sendiri.
- Idempotency key inventory tetap stabil; sistem inventory penerima wajib menerapkannya sebelum memutasi stok.
- Integrasi inventory harus menguji timeout setelah dampak stok commit tetapi sebelum ACK; retry harus menghasilkan satu dampak stok.

## 5. Rencana test database sebelum worker dibuat

Test database/integrasi berikut harus tersedia:

1. **Worker crash after claim:** event berstatus sending dengan lease kedaluwarsa dapat diklaim worker lain.
2. **Worker crash before send:** event dikirim ulang setelah lease kedaluwarsa tanpa kehilangan event.
3. **ACK lost:** penerima sudah commit tetapi ACK hilang; pengiriman ulang tidak menggandakan transaksi dan penerima mengembalikan hasil idempotent.
4. **Duplicate delivery:** event yang sama diterima berulang kali; hanya satu efek bisnis terjadi.
5. **Out-of-order aggregate:** versi N+1 datang sebelum N; N+1 tidak diterapkan lebih dahulu.
6. **Concurrent workers:** dua worker tidak mengklaim event yang sama selama lease masih berlaku.
7. **Expired lease race:** worker lama terlambat mengirim setelah lease diambil alih; ACK lama tidak boleh merusak status claim baru.
8. **Retry policy:** error sementara dijadwalkan ulang; error permanen masuk failed; retry manual tercatat.
9. **Checkpoint:** checkpoint tidak maju pada timeout, HTTP error, atau ACK yang tidak valid.
10. **Cross-node idempotency:** dua node dapat mengirim key yang sama bila kontrak memang mengizinkannya, tanpa benturan yang tidak disengaja.
11. **Inventory queue:** event inventory pulih dari worker crash dan tidak mengirim dampak stok ganda.

## 6. Status implementasi database

Migration lokal `004_sync_recovery_ordering.sql` dan regression tests telah lulus GitHub Actions pada PostgreSQL 16, run [41150146313](https://github.com/bangpei-arch/POS/actions/runs/41150146313), commit `32d53fa90010ffe3f681a4dfcf1a7ff54d62dce6`. Perubahan mencakup:
- Aggregate version counter dan unique ordering pada outbox.
- Claim outbox/inbox/inventory dengan `SKIP LOCKED`, lease, dan fencing token.
- ACK/failure hanya diterima untuk claim token aktif dan lease yang belum habis.
- Inbox cursor untuk urutan per source node dan aggregate.
- Retry attempt history dan pemisahan idempotency key per source node.
- Inventory queue lease recovery dan delivery attempt history.
- Checkpoint dinyatakan sebagai watermark observabilitas, bukan cursor resume.

Test baru:
- `database/tests/006_sync_recovery_ordering.sql`: ordering, lease expiry/reclaim, stale ACK, failed-event blocking, inbox idempotency/order, inventory recovery.
- `database/tests/007_sync_claim_concurrency.py`: dua worker tidak dapat claim event yang sama bersamaan.

Workflow CI diperluas untuk menjalankan migration 004 dan kedua test tersebut setelah migration/test lama.

**Batas penting:** CI membuktikan migration dan test database pada PostgreSQL 16. Migration 004 belum diterapkan pada database development lokal pengguna. Test ini juga belum membuktikan HTTP API end-to-end, commit efek bisnis pada receiver, atau pemulihan worker runtime; itu membutuhkan service/API implementation dan integration test terpisah.

## 7. Batas kesimpulan

Lima test database lokal yang dilaporkan lulus pada 31 Oktober 2026 membuktikan schema smoke, katalog/integritas, integrity guards, refund concurrency, dan transaction finality. Migration 004 dan test 006–007 telah lulus CI pada run 41150146313. Penerapan dan test pada database development lokal masih menunggu. Tidak ada klaim bahwa worker/API end-to-end telah dibuat atau diuji.
