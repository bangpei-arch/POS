# Audit Pemulihan Sinkronisasi POS

**Versi:** 0.1  
**Tanggal:** 31 Oktober 2026  
**Status:** Audit struktur database; belum merupakan desain final worker/API atau migration.

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

## 4. Keputusan desain yang perlu difinalisasi sebelum migration sinkronisasi

| Area | Rancangan yang disarankan | Hal yang perlu divalidasi |
|---|---|---|
| Aggregate ordering | Tambahkan `aggregate_version bigint` yang monotonik per aggregate; alokasikan atomik pada transaksi penulis | Definisi aggregate dan perilaku untuk event non-aggregate |
| Outbox lease | Tambahkan `claimed_by`, `claimed_at`, `lease_until`; claim kedaluwarsa dapat diambil ulang | Durasi lease, heartbeat atau tanpa heartbeat |
| Claim query | Ambil `pending` yang jatuh tempo dan `sending` dengan lease kedaluwarsa; gunakan `FOR UPDATE SKIP LOCKED` | Batas batch dan fairness antar aggregate |
| Retry | Simpan attempt, next retry, error class, dan failed state; attempt history append-only | Maksimum retry otomatis dan prosedur replay |
| Inbox ordering | Simpan aggregate identity/version; versi lompat ditahan tanpa ACK sukses | Apakah event out-of-order disimpan sebagai received/deferred |
| Inbox idempotency | Pertahankan unique event per source; tentukan apakah idempotency key global atau scoped per source | Kontrak pembentukan idempotency key |
| ACK | ACK memuat event_id, status hasil, dan response/correlation ID; sender hanya set sent setelah validasi | Bentuk kontrak HTTP/API |
| Checkpoint | Simpan posisi stream yang dapat dibandingkan, dan update hanya setelah ACK | Apakah checkpoint per stream, per aggregate, atau keduanya |
| Inventory queue | Terapkan pola lease/retry/attempt yang konsisten tetapi tetap antrean terpisah | Kontrak API inventory dan batas retry |

## 5. Rencana test sebelum worker dibuat

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

## 6. Urutan pekerjaan

1. Finalisasi kontrak aggregate/version dan idempotency key.
2. Finalisasi model lease dan retry.
3. Finalisasi semantik inbox, ACK, dan checkpoint.
4. Buat migration sinkronisasi lokal terpisah (tidak mengubah migration 001–003 yang sudah diuji).
5. Tambahkan regression tests untuk seluruh skenario bagian 5.
6. Buat desain cloud inbox/outbox dan migration cloud terpisah.
7. Baru implementasikan worker/API setelah kontrak dan test disetujui.

## 7. Batas kesimpulan

Lima test database lokal yang lulus pada 31 Oktober 2026 membuktikan schema smoke, katalog/integritas, integrity guards, refund concurrency, dan transaction finality. Test tersebut belum membuktikan pemulihan worker, ordering, atomic ACK end-to-end, atau integrasi inventory. Audit ini mencatat gap desain untuk pekerjaan berikutnya; tidak mengubah status lima test yang sudah lulus.
