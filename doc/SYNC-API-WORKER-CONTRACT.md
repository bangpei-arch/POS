# Kontrak Sync API POS: Terminal, Store Server, dan Cloud

**Versi:** 0.1 (draft kontrak)  
**Tanggal:** 31 Oktober 2026  
**Status:** Kontrak target MVP ditetapkan pada Bagian 14; bagian lain memuat desain pasca-MVP  
**Acuan:** migration lokal 004, CLOUD-DATABASE-DESIGN.md, spesifikasi fungsional POS v8.0.

## 1. Komponen dan arah komunikasi

| Komponen | Peran |
|---|---|
| Terminal POS (PWA) | Membuat transaksi; IndexedDB menjadi durable queue saat local server/LAN gagal |
| Store API | Menerima transaksi terminal, menyimpan ke PostgreSQL toko, membuat outbox secara atomik |
| Store Sender Worker | Mengirim outbox store ke cloud; retry dan menunggu final ACK |
| Cloud Receiver API | Autentikasi node, validasi envelope, menerima dan memproses event |
| Cloud Inbox Worker | Recovery/processing event yang tertunda atau lease kedaluwarsa |
| Cloud Master Publisher | Menulis master + change log secara atomik |
| Store Master Pull Worker | Menarik master change, menerapkan cache, memajukan cursor |
| Cloud Reporting Worker | Memperbarui agregasi rebuildable dari fakta transaksi |

Alur utama: Terminal → Store API → local PostgreSQL + outbox → Store Sender Worker → Cloud Receiver/Inbox → cloud replica → final ACK. Cloud tidak mengakses database toko secara langsung.

## 2. Prinsip protokol

- Semua endpoint menggunakan HTTPS dan JSON UTF-8.
- Prefix API `/api/v1`; versi API berbeda dari `schema_version` payload event.
- UUID digunakan untuk event dan entity identity; waktu RFC 3339 UTC.
- Nilai uang dikirim sebagai decimal string, bukan floating-point JSON.
- Setiap request memiliki `X-Request-ID`; setiap event memiliki `event_id` dan `idempotency_key`.
- Node store-server adalah satu-satunya principal sinkronisasi cloud pada tahap awal.
- Autentikasi menggunakan OAuth 2.0 Client Credentials. Setiap store-server memiliki client_id dan client_secret unik; terminal POS tidak memiliki credential cloud.
- Token endpoint: POST /api/v1/oauth/token dengan grant_type=client_credentials dan scope yang diminta. Client authentication menggunakan HTTP Basic melalui HTTPS.
- Authorization server menerbitkan JWT access token berumur 5 menit (default awal), ditandatangani asymmetric key ES256 atau RS256. Private signing key disimpan di KMS/secret manager cloud; receiver memvalidasi signature melalui public key/JWKS, issuer, audience, expiry, not-before, dan allowed algorithm. Tidak ada refresh token; server toko meminta token baru dengan client credentials.
- Klaim minimum JWT: iss, sub (node_id), aud (POS cloud API), iat, nbf, exp, jti, scope, dan store_id. Scope awal: sync:events:write, sync:master:read, sync:master:ack, sync:heartbeat:write. Akses dibatasi ke node/store yang terdaftar.
- Cloud menyimpan client_id, hash client_secret (Argon2id atau setara), status, masa berlaku, scope, dan metadata rotasi/revocation; secret plaintext tidak disimpan. Store server menyimpan secret pada OS secret store atau konfigurasi terenkripsi dengan permission terbatas, bukan source code, database transaksi, atau log.
- Rotasi menerbitkan secret baru dengan masa overlap terbatas; secret lama dicabut setelah secret baru terverifikasi. Revocation harus menolak token baru dan membatalkan token aktif melalui pemeriksaan status/credential version atau denylist jti sampai token kedaluwarsa. Credential dicabut tanpa menghapus outbox pending.
- Receiver wajib mencocokkan source_node_id dan source_store_id pada body dengan klaim token; nilai body bukan sumber otorisasi. Token, client_secret, PIN, dan payload sensitif tidak boleh masuk log.
- Batas payload/batch awal yang diusulkan: maksimal 25 event atau 1 MiB per request, mana yang tercapai lebih dahulu; konfigurabel setelah load test.
- Tidak ada jaminan exactly-once pada jaringan. Protokol memberi at-least-once delivery + idempotent processing sehingga efek bisnis tidak terduplikasi.

## 3. Autentikasi server toko ke Cloud

### 3.1 Penerbitan access token

POST /api/v1/oauth/token

Request menggunakan application/x-www-form-urlencoded dengan grant_type=client_credentials dan scope yang diminta. Client mengirim HTTP Basic credentials melalui TLS.

Respons OAuth standar berisi access_token, token_type=Bearer, expires_in=300, dan scope. Token disimpan hanya di memori/cache berumur pendek. Tidak ada refresh token pada Client Credentials. Jika token endpoint tidak tersedia, worker menahan pengiriman dan mempertahankan outbox; transaksi lokal tetap berjalan.

### 3.2 Validasi dan otorisasi token

Cloud memvalidasi signature JWT, issuer, audience, exp, nbf, algoritma yang diizinkan, status node/credential, serta scope endpoint. Clock skew default 30 detik. Token kedaluwarsa menghasilkan HTTP 401; scope atau store/node mismatch menghasilkan HTTP 403. Setiap endpoint sinkronisasi mencocokkan node dan store pada path/body dengan klaim token.

### 3.3 Rotasi dan pencabutan credential

Setiap node dapat memiliki dua secret aktif selama periode rotasi terbatas. Central Admin melakukan rotate/revoke; aktivitas tercatat di audit. Pencabutan tidak menghapus event pending dan tidak mengubah identitas event. Setelah credential dicabut, server harus mendapat credential baru melalui prosedur provisioning terotorisasi.

## 4. Terminal ke Store API

### 4.1 Submit transaksi terminal

`POST /api/v1/terminals/{terminal_id}/sales`

Tujuan: menyimpan transaksi dari IndexedDB ke local PostgreSQL setelah LAN/server tersedia.

Request:
```json
{
  "request_id": "uuid",
  "terminal_id": "uuid",
  "store_id": "uuid",
  "sale": {
    "sale_id": "uuid",
    "receipt_number": "SDR-20261031-POS01-000001",
    "cashier_id": "uuid",
    "business_date": "2026-10-31",
    "created_at": "2026-10-31T02:15:00Z",
    "paid_at": "2026-10-31T02:16:00Z",
    "status": "paid",
    "currency_code": "IDR",
    "totals": {
      "subtotal": "100000.00",
      "discount_total": "0.00",
      "tax_total": "0.00",
      "rounding_amount": "0.00",
      "grand_total": "100000.00"
    },
    "lines": [],
    "discounts": [],
    "payments": []
  }
}
```

Ketentuan:
- Store API memverifikasi terminal/store/cashier scope dan integritas total/line/payment.
- Transaksi, detail, pembayaran, status final, audit terkait, dan outbox event disimpan dalam satu transaksi DB.
- Unique key terminal + sale_id dan receipt_number mencegah duplikasi.
- Request ulang dengan payload identik mengembalikan hasil sebelumnya; ID sama dengan payload berbeda menghasilkan 409.
- Respons 201 (baru disimpan) atau 200 (sudah tersimpan) hanya setelah commit durable.
- Terminal baru menghapus/menandai item IndexedDB selesai setelah menerima durable ACK store.
- Jika response hilang, terminal mengirim ulang dengan sale_id/idempotency yang sama.

### 4.2 Terminal status/heartbeat

`POST /api/v1/terminals/{terminal_id}/heartbeat`

Mencatat app_version, observed_at, connectivity state, local queue count, dan status printer opsional. Heartbeat bukan event penjualan dan tidak boleh memblokir transaksi.

## 5. Store Sender ke Cloud Receiver

### 5.1 Kirim batch event

`POST /api/v1/sync/events:batch`

Header:
- `Authorization: Bearer <node_access_token>`
- `X-Request-ID: <uuid>`
- `Content-Type: application/json`

Request:
```json
{
  "protocol_version": 1,
  "source_node_id": "uuid",
  "source_store_id": "uuid",
  "worker_id": "store-sync-01",
  "events": [
    {
      "event_id": "uuid",
      "idempotency_key": "store-server-uuid:event-uuid",
      "aggregate_type": "sale",
      "aggregate_id": "uuid",
      "aggregate_version": 1,
      "event_type": "sale.paid",
      "schema_version": 1,
      "occurred_at": "2026-10-31T02:16:00Z",
      "correlation_id": "uuid",
      "payload_sha256": "hex",
      "payload": {}
    }
  ]
}
```

Payload event bisnis adalah snapshot lengkap aggregate final, bukan patch yang bergantung pada keadaan database sebelumnya. Hanya sale yang sudah berstatus PAID yang dikirim sebagai event bisnis `sale.paid`. Status pembayaran yang belum dikonfirmasi (termasuk non-tunai pending) hanya disimpan di database lokal toko; tidak ada event `payment.pending` ke cloud. Setelah kasir mengonfirmasi pembayaran dan finalisasi lokal berhasil, store membuat `sale.paid` dan outbox secara atomik. Contoh:
- `sale.paid`: header, semua lines, discounts/promotion snapshots, confirmed payments.
- `refund.paid`: refund header, lines, payout breakdown, original sale reference.
- `cash.session.closed`: session snapshot dan expected/actual/variance.
- `cash.ledger.recorded`, `cash.deposit.recorded`, `cash.handover.confirmed`.
- `customer.created` / `customer.updated`: registrasi/perubahan pelanggan pending dari toko.
- `audit.recorded`: audit event yang perlu dikonsolidasikan.
- `terminal.status`: telemetry, dapat dikirim melalui endpoint telemetry terpisah.

Respons per event (batch dapat berisi hasil campuran):
```json
{
  "request_id": "uuid",
  "results": [
    {
      "event_id": "uuid",
      "status": "processed",
      "processed_at": "2026-10-31T02:16:02Z",
      "duplicate": false
    }
  ]
}
```

Status hasil: `processed`, `already_processed`, `deferred`, `rejected`, `conflict`.

### 5.2 Semantik ACK

- Final ACK hanya berarti fakta bisnis telah berhasil diproyeksikan di cloud dan inbox cursor + status processed commit atomik.
- Untuk request batch yang valid, HTTP 200 mengembalikan hasil per event. `processed` atau `already_processed` adalah final ACK untuk event tersebut; sender memanggil `ack_sync_outbox(outbox_id,claim_token,...)`.
- Event yang sudah tersimpan durable tetapi belum selesai diproyeksikan mendapat status per-event `deferred` beserta `retry_after_seconds`; sender tidak boleh menandai outbox sent.
- HTTP 202 hanya dipakai bila seluruh batch diterima durable tetapi belum ada event yang selesai diproses. Untuk batch campuran, HTTP 200 dan status masing-masing event menjadi otoritatif.
- Sender menjadwalkan retry event deferred dengan Retry-After/backoff. Retry dengan event_id/idempotency yang sama akan memperoleh status akhir saat sudah diproses.
- Jika response hilang setelah cloud commit, retry event yang sama harus mengembalikan `already_processed` dengan hasil ACK yang sama.
- Tidak ada ACK final hanya karena payload diterima ke buffer/proxy atau masuk inbox.

### 5.3 Idempotency dan urutan

Unique constraints cloud:
- `(source_node_id,event_id)`
- `(source_node_id,idempotency_key)`
- `(source_node_id,aggregate_type,aggregate_id,aggregate_version)`

Jika event_id/key sama dan payload hash sama, return status existing. Jika hash berbeda, return 409 conflict dan alert. Aggregate version harus cursor + 1; versi berikutnya ditahan sampai gap diselesaikan. Satu aggregate tidak boleh diproses paralel keluar urutan. Aggregate berbeda boleh paralel. Dependency lintas aggregate tetap divalidasi, misalnya refund harus menunggu sale asal tersedia di cloud.

## 6. Master data Cloud ke Store

### 6.1 Pull perubahan

`GET /api/v1/sync/master/changes?after={cursor}&limit=200`

Respons:
```json
{
  "from_cursor": 1200,
  "next_cursor": 1250,
  "has_more": true,
  "changes": [
    {
      "change_seq": 1201,
      "entity_type": "product",
      "entity_id": "uuid",
      "entity_version": 4,
      "operation": "upsert",
      "effective_at": "2026-11-01T00:00:00Z",
      "payload": {}
    }
  ]
}
```

Ketentuan:
- Hanya perubahan untuk toko itu dan perubahan global yang dikirim.
- Payload berisi snapshot lengkap entity untuk versi tersebut atau tombstone/deactivate.
- Store worker menerapkan perubahan idempotent dalam transaksi lokal, lalu menyimpan cursor hanya setelah batch berhasil.
- Versi entity lebih rendah dari versi lokal diabaikan sebagai duplicate; versi lompat harus ditahan/dilaporkan.
- Jika cursor terlalu lama dan log telah diarsipkan, cloud menyediakan bootstrap snapshot + cursor baru.

### 6.2 Konfirmasi cursor

`POST /api/v1/sync/master/ack`

Request: `{ "node_id": "uuid", "applied_cursor": 1250 }`.

Cloud memvalidasi cursor tidak bergerak mundur dan tidak melampaui high-water mark perubahan yang sudah discan untuk scope node. Karena change log dapat berisi perubahan untuk toko lain, `next_cursor` menunjukkan posisi scan global, bukan nomor change terakhir yang kebetulan dikembalikan. Perubahan yang tidak relevan tetap dilewati secara aman. ACK cursor adalah telemetry/progress; sumber kebenaran penerapan tetap database lokal toko.


### 6.4 Alokasi kuota promosi offline

Kuota promosi diberikan cloud sebagai grant per promosi/per toko. Cloud mengalokasikan kuota secara atomik dan menjamin jumlah seluruh grant tidak melampaui kuota global. Grant yang didistribusikan melalui master sync sekurang-kurangnya berisi allocation_id, promotion_id, store_id, allocated_quantity, valid_from, valid_until, allocation_version, dan bukti integritas/signature.

Store server menyimpan grant dan konsumsi lokal secara durable. Ketika transaksi menjadi PAID, pemakaian kuota dikurangi/dicatat dalam transaksi yang sama dengan sale dan outbox. Event sale.paid membawa promotion_id, allocation_id, dan consumed_quantity sehingga cloud dapat merekonsiliasi konsumsi secara idempotent. Pemakaian offline hanya boleh menggunakan sisa grant toko itu; tidak boleh memakai jatah toko lain atau melampaui grant.

Jika kuota habis, promosi tidak diterapkan di toko tersebut sampai grant tambahan diterima. Saat toko online, cloud dapat menerbitkan grant tambahan hanya dari kuota global yang belum dialokasikan. Grant yang belum terpakai tidak boleh otomatis dialihkan hanya karena node offline atau heartbeat hilang. Re-alokasi memerlukan konfirmasi grant ditutup/tidak dapat dipakai lagi oleh node, atau berakhirnya masa grant disertai prosedur fencing/penutupan yang menjamin tidak ada transaksi tertunda yang masih dapat memakai grant. Semua alokasi, penutupan, dan rekonsiliasi tercatat audit.

Worker master pull menerapkan grant secara idempotent berdasarkan allocation_id dan allocation_version. Grant tidak boleh ditimpa oleh versi lebih rendah. Konsumsi transaksi harus menyimpan referensi grant agar cloud dapat membandingkan allocated, consumed, dan remaining.

### 6.5 Cache otorisasi kasir saat offline

Store server menyimpan cache hash PIN dan role/permission yang diperlukan untuk login offline. Cache berlaku maksimal 24 jam sejak sinkronisasi otorisasi terakhir yang berhasil. Acuan waktu adalah jam server toko yang disinkronkan melalui NTP.

Store server wajib mendeteksi perubahan jam yang mencurigakan, termasuk clock rollback dan lompatan waktu yang tidak wajar. Implementasi harus mempertahankan bukti waktu sinkronisasi secara aman terhadap reboot dan tidak boleh memperpanjang masa berlaku cache akibat perubahan jam. Jika integritas waktu tidak dapat dipastikan, cache diperlakukan kedaluwarsa dan login offline ditolak sampai waktu tervalidasi serta sinkronisasi otorisasi terbaru berhasil.

Setelah cache melewati 24 jam, login offline baru dan pembukaan sesi kasir baru ditolak sampai koneksi cloud pulih dan sinkronisasi otorisasi terbaru berhasil. Sesi kasir yang sudah aktif sebelum cache kedaluwarsa tetap boleh menyelesaikan transaksi yang sedang berjalan atau ditutup; sesi tersebut tidak boleh memulai transaksi baru. Perubahan PIN, role, deaktivasi, dan pencabutan akses dari cloud diterapkan pada sinkronisasi berikutnya. Batas 24 jam membatasi jendela penggunaan cache otorisasi stale ketika toko offline.

### 6.6 Bootstrap

`GET /api/v1/sync/master/bootstrap`

Mengembalikan `snapshot_id`, `snapshot_cursor`, dan URL/halaman data master scoped toko. Store menerapkan snapshot secara staging, memvalidasi kelengkapan, swap/commit, lalu mulai pull setelah snapshot_cursor. Detail format snapshot dan pemulihan bootstrap harus ditentukan sebelum implementasi.

## 7. Monitoring node

`POST /api/v1/sync/heartbeat`

Payload: node_id, store_id, app_version, observed_at, outbox_pending_count, oldest_pending_at, inbox_failed_count, last_success_at, clock_offset_seconds, health flags. Cloud menghitung:
- Node offline setelah heartbeat tidak diterima 5 menit.
- Warning pending 15 menit.
- Critical pending 60 menit.
- Warning tambahan backlog >=100 event.

Heartbeat tidak boleh membawa payload pelanggan/transaksi. Local alert tetap aktif ketika internet putus; cloud alert aktif setelah node terhubung kembali.

## 8. HTTP status dan kebijakan retry

| HTTP | Makna | Tindakan sender |
|---|---|---|
| 200 | processed/already_processed | Final ACK outbox |
| 202 | seluruh batch diterima durable, belum selesai diproses | Retry event yang sama; jangan ACK final |
| 200 + per-event `deferred` | sebagian event belum selesai diproses | Retry hanya event deferred; event processed boleh di-ACK |
| 400 | envelope/request malformed | Perbaiki client; alert |
| 401/403 | credential/scope tidak sah | Stop pengiriman, alert Central Admin |
| 409 | idempotency/hash conflict | Dead-letter; intervensi operator |
| 413 | payload terlalu besar | Split event/batch sesuai kontrak; alert jika satu event terlalu besar |
| 422 | schema/event tidak didukung atau business invariant invalid | Permanent failure; jangan retry otomatis tanpa perubahan |
| 425 | aggregate version gap / predecessor belum diproses | Retry dengan backoff; tahan event berikutnya pada aggregate |
| 429 | rate limited | Hormati Retry-After |
| 5xx / timeout / network error | gangguan sementara/hasil tidak diketahui | Retry event yang sama; idempotency melindungi duplicate |

Retry exponential backoff dengan full jitter; baseline base 2 detik, cap 15 menit. Local migration 004 memiliki max_attempts default 12 dan status failed untuk intervensi; replay manual diaudit dan memakai event_id/payload yang sama. Perbedaan permanent vs transient harus dipetakan oleh sender/receiver.

## 9. Worker behavior

### 9.1 Store Sender Worker

1. Claim batch melalui `claim_sync_outbox(worker_id, limit, lease_seconds)`.
2. Urutkan event per aggregate_version; migration 004 mencegah claim versi berikut sebelum versi sebelumnya sent.
3. Kirim batch HTTPS.
4. Untuk tiap hasil:
   - processed/already_processed: panggil `ack_sync_outbox` dengan claim token.
   - deferred/202: panggil `fail_sync_outbox` sebagai transient retry dengan next_retry_at; jangan tandai sent.
   - conflict/rejected/permanent: `fail_sync_outbox(..., p_permanent=true)`.
   - timeout/5xx/429: retry dengan backoff dan jitter.
5. Jika worker mati, lease expired dan event dapat di-claim ulang.
6. Jangan menghapus outbox event atau mengubah payload setelah event dibuat.
7. Worker harus memiliki concurrency terbatas, timeout HTTP, dan shutdown graceful.

### 9.2 Cloud Inbox Worker

1. Claim dengan `claim_sync_inbox` (lease + fencing token).
2. Validasi schema_version, node/store ownership, aggregate sequence, business invariants, dan referensi master.
3. Proyeksikan aggregate snapshot ke `replica` secara idempotent.
4. Dalam transaksi yang sama panggil `complete_sync_inbox` dan majukan cursor.
5. ACK hanya setelah commit.
6. Error transient: `fail_sync_inbox` dengan retry_at; error permanen: failed/rejected.
7. Event dengan predecessor gap berstatus deferred dan tidak boleh melewati cursor.
8. Replay/skip harus melalui action audit dan role khusus.

### 9.3 Store Master Pull Worker

1. Baca cursor lokal terakhir.
2. Pull satu batch change log.
3. Validasi target scope, entity_version, schema, dan effective_at.
4. Terapkan perubahan idempotent dalam transaksi lokal.
5. Update cursor lokal atomik dengan penerapan batch.
6. Kirim master ACK ke cloud setelah commit lokal.
7. Retry tanpa menghapus cursor bila batch gagal.

### 9.4 Reporting Worker

Update agregasi dari fakta `replica` setelah transaksi projection commit. Gunakan watermark/queue internal dan operasi idempotent. Laporan dapat tertunda tanpa memengaruhi final ACK transaksi; laporan bukan bagian dari transaksi ACK.

## 10. Event catalog awal

| Aggregate | Event type | Final payload minimum |
|---|---|---|
| sale | `sale.paid` | header + lines + discounts + confirmed payments |
| refund | `refund.paid` | header + lines + payout + original sale ID |
| cash_session | `cash.session.closed` | session totals + drawer/store/terminal/cashier |
| cash_ledger | `cash.ledger.recorded` | entry + approval + source reference |
| cash_deposit | `cash.deposit.recorded` | amount + expected + variance + actor/reason |
| cash_handover | `cash.handover.confirmed` | from/to session/cashier + amount + variance |
| customer | `customer.created`, `customer.updated` | customer data + local source ID; cloud auto-merges by normalized active phone number and returns canonical customer ID + alias mapping |
| audit_event | `audit.recorded` | action/entity/actor/reason/before/after/correlation |
| terminal | `terminal.status` | telemetry; preferably separate stream |

Event names and exact payload JSON Schema must be versioned and finalized separately. A sale event should represent the final PAID aggregate; drafts and Hold Orders are not sent to cloud.


### 10.1 Resolusi identitas pelanggan

Cloud melakukan auto-merge jika nomor telepon aktif yang sudah dinormalisasi sama. Tidak ada antrean persetujuan manual untuk kasus ini. Respons/proses master sync mengembalikan canonical_customer_id dan pemetaan local_customer_id/alias agar toko dapat memperbarui referensi pelanggan secara konsisten.

Proses merge harus atomik dan race-safe. ID canonical yang paling dahulu dibuat dipertahankan; ID lokal lain dicatat sebagai alias. Field canonical yang kosong boleh diisi dari record alias, tetapi nilai non-kosong yang bertentangan tidak saling menimpa otomatis dan dicatat untuk koreksi admin. Transaksi historis tetap menyimpan customer ID asal dan tidak ditulis ulang; lookup/reporting dapat mengikuti pemetaan canonical. Nomor kosong/tidak valid tidak digunakan untuk auto-merge.

## 11. Observability, security, dan operations

- TLS wajib; credential scope hanya satu store-server dan store_id yang terdaftar.
- Rate limit per node/store; max body size; request timeout; clock skew monitored.
- Log request_id, node_id, event_id, aggregate, outcome, duration; jangan log secret, PIN, bukti pembayaran, atau PII penuh.
- Credential rotation/revocation tanpa menghapus event pending.
- Metrics: outbox depth/age, inbox depth/age, event processing latency, retry count, failed count, lease expiry, cursor lag, master cursor lag, node heartbeat age.
- Alert threshold mengikuti spesifikasi: offline 5 menit; warning 15 menit; critical 60 menit; backlog 100.
- Backup dan restore test cloud terpisah dari local.
- Manual replay/skip memerlukan alasan, actor, approval/permission, dan immutable audit trail.

### 11.1 Upload bukti pembayaran non-tunai



File bukti pembayaran bersifat opsional sesuai aturan metode pembayaran. Bukti untuk pembayaran yang belum dikonfirmasi tetap lokal dan tidak dikirim ke cloud. Setelah transaksi menjadi PAID, store server mengunggah file ke private object storage cloud melalui alur upload terotorisasi (misalnya request upload URL sementara dari API cloud, lalu upload langsung ke object storage). File binary tidak dikirim sebagai bagian dari event JSON dan tidak disimpan di PostgreSQL.



Metadata yang disimpan pada cloud minimal mencakup payment_id, sale_id, object_key/URI internal, checksum SHA-256, ukuran byte, MIME type, nama file yang disanitasi, uploaded_at, source_node_id, dan status verifikasi. Akses unduh menggunakan authorization service atau signed URL berumur pendek; object tidak boleh public. Semua akses baca/unduh diaudit.



Store server mempertahankan file lokal sementara secara durable sampai cloud mengonfirmasi object tersimpan dan checksum cocok serta metadata sudah terikat ke payment/transaksi. Setelah konfirmasi tersebut barulah file lokal boleh dihapus. Upload gagal/timeout di-retry secara idempotent; transaksi PAID tidak dibatalkan dan bukti lokal tidak boleh hilang. Gunakan object key unik/tidak mudah ditebak, bukan nama file asli. Jangan menimpa object bukti yang sudah direferensikan tanpa membuat versi/jejak audit.

### Retensi event di cloud

- Raw event yang berhasil diproses: 90 hari sejak pemrosesan/ingest final. Setelah itu payload mentah boleh dihapus oleh job retensi; metadata minimum untuk deduplikasi, cursor, dan audit dipertahankan sesuai kebutuhan teknis.
- Event gagal/permanen (dead-letter): dipertahankan sampai diselesaikan melalui replay atau keputusan skip/penutupan yang diaudit. Setelah penyelesaian, payload dan metadata dead-letter disimpan minimal 1 tahun sejak pertama masuk dead-letter.
- Fakta transaksi hasil proyeksi tetap disimpan/diarsipkan selama 5 tahun. Penghapusan raw event tidak menghapus fakta transaksi hasil proyeksi.
- Setiap replay, skip, dan penghapusan event/payload wajib dicatat dalam audit dengan actor, alasan, waktu, target, dan tindakan. Audit mengikuti retensi 3 tahun sesuai baseline, kecuali legal hold.

## 12. Keputusan yang perlu disahkan sebelum API/worker coding

1. Verifikasi parameter keamanan OAuth2 saat security review: masa hidup token 5 menit, pilihan final ES256 atau RS256, dan scope minimum per endpoint.
2. Batas batch/payload dan timeout final berdasarkan load test.
3. Event payload JSON Schema final dan daftar event mana yang wajib dikirim.
4. Detail teknis auto-merge: normalisasi nomor lintas negara, unique constraint, race handling, dan tampilan field konflik.
5. Detail implementasi grant kuota: format/tanda tangan grant, DDL, fencing dan penutupan/re-alokasi, serta rekonsiliasi konsumsi.
6. Detail bootstrap master snapshot dan pemulihan cursor kedaluwarsa.
7. Apakah event audit lengkap atau subset audit yang dikirim ke cloud.




## 13. Batas tahap ini

Ini adalah kontrak logis v0.1. Belum ada FastAPI route, Pydantic schema, worker Python, DDL cloud, atau integration test runtime. Implementasi baru dimulai setelah kontrak dan keputusan terbuka disetujui.


## 14. Kontrak implementasi MVP (mengikat untuk milestone pertama)

Bagian ini mengesampingkan fitur yang lebih luas pada bagian sebelumnya untuk rilis MVP. Gunakan juga dokumen MVP-END-TO-END-PLAN.md.

### 14.1 Komponen aktif MVP

- Terminal PWA/browser → Store API.
- Store API + PostgreSQL lokal + transactional outbox.
- Satu Store Sender Worker.
- Cloud OAuth/token endpoint + Cloud Receiver API.
- Satu PostgreSQL cloud dengan migration terpisah di database/cloud-migrations.
- Master bootstrap endpoint dan laporan penjualan pusat.
- Tidak ada Cloud Inbox Worker terpisah pada MVP. Receiver memproses sinkron secara langsung dalam transaksi DB dan hanya mengirim final ACK setelah commit. Worker/queue cloud asinkron menjadi opsi setelah beban nyata menuntutnya.

### 14.2 Endpoint minimum

| Method | Path | Fungsi |
|---|---|---|
| POST | /api/v1/oauth/token | Client Credentials; token JWT 5 menit |
| GET | /api/v1/sync/master/bootstrap | Snapshot produk, harga aktif, metode pembayaran, store ID, master_version |
| POST | /api/v1/sync/events:batch | Menerima sale.paid dan audit.recorded |
| POST | /api/v1/sync/heartbeat | Heartbeat store server |
| GET | /api/v1/reports/sales | Laporan transaksi pusat dengan filter store/date |

MVP bootstrap adalah snapshot penuh dan read-only. Incremental master stream, cursor ACK, promotion grants, customer merge, dan offline authorization refresh ditunda.

### 14.3 Event bisnis sale.paid

- Event schema: doc/schemas/sale.paid.v1.schema.json.
- Envelope wajib: event_id, idempotency_key, source_node_id, source_store_id, aggregate_type, aggregate_id, aggregate_version, event_type, schema_version, occurred_at, correlation_id, payload_sha256, payload.
- aggregate_type = sale; aggregate_id = source sale UUID; aggregate_version = 1; event_type = sale.paid; schema_version = 1.
- Payload berisi sale header snapshot, satu atau lebih sale lines, dan confirmed payments. Pending payment tidak dikirim.
- Semua nominal dikirim sebagai decimal string; server mengubah ke NUMERIC tanpa float.
- payload_sha256 = SHA-256 atas byte payload JSON yang dikirim. Retry harus mengirim byte-equivalent payload dan event_id yang sama.
- Cloud memvalidasi signature token, node/store claims, JSON Schema, hash, UUID, receipt uniqueness, aggregate version, minimal satu line/payment, SUM(line_total)=grand_total, dan SUM(confirmed payment)=grand_total.
- Cloud menyimpan event registry + sale + lines + payments dalam satu transaksi. Event registry status menjadi processed dalam transaksi yang sama. Panggil replica.assert_sale_complete(sale_id) sebelum commit.
- Duplicate event dengan event_id/idempotency key sama dan hash sama mengembalikan already_processed; event identity sama dengan hash berbeda mengembalikan 409 conflict. Duplicate source sale/receipt juga tidak boleh membuat row kedua.
- Cloud tidak memperbarui master stock atau inventory pada MVP.

### 14.4 Event audit allowlist

- Event type: audit.recorded; schema doc/schemas/audit.recorded.v1.schema.json.
- Hanya action yang terdaftar dalam CHECK constraint replica.audit_events yang diterima.
- Payload dibatasi actor ID, terminal ID, action, entity type/id, reason, correlation ID, occurred_at.
- Jangan kirim PIN/hash PIN, password, client secret, JWT, bukti pembayaran, full customer PII, atau before/after JSON.
- Audit bukan pengganti event bisnis sale.paid. Audit yang gagal tidak boleh membatalkan transaksi PAID lokal; sender menyimpan retry terpisah.

### 14.5 Semantik respons

- 200 processed: cloud sudah commit; sender ACK outbox.
- 200 already_processed: cloud sudah memiliki event/hash yang sama; sender ACK outbox.
- 409 conflict: identitas sama dengan payload/hash berbeda atau konflik receipt; tandai permanent failure dan butuh investigasi.
- 422 rejected: schema/business validation gagal; permanent failure/dead-letter lokal.
- 429/5xx/network timeout: transient; retry dengan backoff full jitter. Bila timeout terjadi setelah cloud commit, retry aman karena idempotensi.
- Jangan pernah ACK event sebagai sent hanya karena HTTP request berhasil dikirim; hanya respons final processed/already_processed setelah commit.

### 14.6 Retensi dan laporan

- processed payload event disimpan 90 hari; setelah itu payload boleh NULL, event ID/idempotency/hash/status tetap disimpan.
- permanent failed/dead-letter sampai resolved dan minimal satu tahun.
- replica sales/lines/payments lima tahun; audit tiga tahun.
- MVP laporan memakai reporting.v_sales dan query detail replica; agregasi materialized/reporting worker ditunda.

### 14.7 Mapping transaksi lokal ke cloud

- pos_sales.id → replica.sales.source_sale_id
- pos_sales.store_id → replica.sales.source_store_id
- sync_nodes.id → replica.sales.source_node_id
- pos_sales.terminal_id/cashier_id → source_terminal_id/source_cashier_id
- pos_sale_lines.id → replica.sale_lines.source_line_id
- pos_payments.id → replica.payments.source_payment_id
- Cloud PK dibuat sendiri; source UUID tetap disimpan.
- Snapshot name/SKU/price/tax/payment method dari transaksi lokal adalah sumber transaksi, bukan lookup master terkini.

### 14.8 Batas offline MVP

Penjualan tetap dapat berlangsung ketika internet cloud putus, selama terminal dapat mengakses Store API dan kasir sudah login. Transaksi PAID dan outbox tersimpan lokal lalu dikirim saat internet pulih. Kegagalan store server/LAN, offline login cache, dan terminal-side IndexedDB durable queue ditunda untuk milestone berikutnya.
