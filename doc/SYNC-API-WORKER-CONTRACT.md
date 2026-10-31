# Kontrak Sync API POS: Terminal, Store Server, dan Cloud

**Versi:** 0.1 (draft kontrak)  
**Tanggal:** 31 Oktober 2026  
**Status:** Draft untuk review; belum implementasi runtime  
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
- Auth memakai credential mesin per node dengan scope store; credential disimpan sebagai hash/reference aman di cloud dan secret di secret store lokal. Rotasi dan revocation wajib tersedia. Detail mekanisme (OAuth client credentials vs HMAC signing/mTLS) belum diputuskan.
- Batas payload/batch awal yang diusulkan: maksimal 25 event atau 1 MiB per request, mana yang tercapai lebih dahulu; konfigurabel setelah load test.
- Tidak ada jaminan exactly-once pada jaringan. Protokol memberi at-least-once delivery + idempotent processing sehingga efek bisnis tidak terduplikasi.

## 3. Terminal ke Store API

### 3.1 Submit transaksi terminal

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

### 3.2 Terminal status/heartbeat

`POST /api/v1/terminals/{terminal_id}/heartbeat`

Mencatat app_version, observed_at, connectivity state, local queue count, dan status printer opsional. Heartbeat bukan event penjualan dan tidak boleh memblokir transaksi.

## 4. Store Sender ke Cloud Receiver

### 4.1 Kirim batch event

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

Payload event bisnis adalah snapshot lengkap aggregate final, bukan patch yang bergantung pada keadaan database sebelumnya. Contoh:
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

### 4.2 Semantik ACK

- Final ACK hanya berarti fakta bisnis telah berhasil diproyeksikan di cloud dan inbox cursor + status processed commit atomik.
- Untuk request batch yang valid, HTTP 200 mengembalikan hasil per event. `processed` atau `already_processed` adalah final ACK untuk event tersebut; sender memanggil `ack_sync_outbox(outbox_id,claim_token,...)`.
- Event yang sudah tersimpan durable tetapi belum selesai diproyeksikan mendapat status per-event `deferred` beserta `retry_after_seconds`; sender tidak boleh menandai outbox sent.
- HTTP 202 hanya dipakai bila seluruh batch diterima durable tetapi belum ada event yang selesai diproses. Untuk batch campuran, HTTP 200 dan status masing-masing event menjadi otoritatif.
- Sender menjadwalkan retry event deferred dengan Retry-After/backoff. Retry dengan event_id/idempotency yang sama akan memperoleh status akhir saat sudah diproses.
- Jika response hilang setelah cloud commit, retry event yang sama harus mengembalikan `already_processed` dengan hasil ACK yang sama.
- Tidak ada ACK final hanya karena payload diterima ke buffer/proxy atau masuk inbox.

### 4.3 Idempotency dan urutan

Unique constraints cloud:
- `(source_node_id,event_id)`
- `(source_node_id,idempotency_key)`
- `(source_node_id,aggregate_type,aggregate_id,aggregate_version)`

Jika event_id/key sama dan payload hash sama, return status existing. Jika hash berbeda, return 409 conflict dan alert. Aggregate version harus cursor + 1; versi berikutnya ditahan sampai gap diselesaikan. Satu aggregate tidak boleh diproses paralel keluar urutan. Aggregate berbeda boleh paralel. Dependency lintas aggregate tetap divalidasi, misalnya refund harus menunggu sale asal tersedia di cloud.

## 5. Master data Cloud ke Store

### 5.1 Pull perubahan

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

### 5.2 Konfirmasi cursor

`POST /api/v1/sync/master/ack`

Request: `{ "node_id": "uuid", "applied_cursor": 1250 }`.

Cloud memvalidasi cursor tidak bergerak mundur dan tidak melampaui high-water mark perubahan yang sudah discan untuk scope node. Karena change log dapat berisi perubahan untuk toko lain, `next_cursor` menunjukkan posisi scan global, bukan nomor change terakhir yang kebetulan dikembalikan. Perubahan yang tidak relevan tetap dilewati secara aman. ACK cursor adalah telemetry/progress; sumber kebenaran penerapan tetap database lokal toko.

### 5.3 Bootstrap

`GET /api/v1/sync/master/bootstrap`

Mengembalikan `snapshot_id`, `snapshot_cursor`, dan URL/halaman data master scoped toko. Store menerapkan snapshot secara staging, memvalidasi kelengkapan, swap/commit, lalu mulai pull setelah snapshot_cursor. Detail format snapshot dan pemulihan bootstrap harus ditentukan sebelum implementasi.

## 6. Monitoring node

`POST /api/v1/sync/heartbeat`

Payload: node_id, store_id, app_version, observed_at, outbox_pending_count, oldest_pending_at, inbox_failed_count, last_success_at, clock_offset_seconds, health flags. Cloud menghitung:
- Node offline setelah heartbeat tidak diterima 5 menit.
- Warning pending 15 menit.
- Critical pending 60 menit.
- Warning tambahan backlog >=100 event.

Heartbeat tidak boleh membawa payload pelanggan/transaksi. Local alert tetap aktif ketika internet putus; cloud alert aktif setelah node terhubung kembali.

## 7. HTTP status dan kebijakan retry

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

## 8. Worker behavior

### 8.1 Store Sender Worker

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

### 8.2 Cloud Inbox Worker

1. Claim dengan `claim_sync_inbox` (lease + fencing token).
2. Validasi schema_version, node/store ownership, aggregate sequence, business invariants, dan referensi master.
3. Proyeksikan aggregate snapshot ke `replica` secara idempotent.
4. Dalam transaksi yang sama panggil `complete_sync_inbox` dan majukan cursor.
5. ACK hanya setelah commit.
6. Error transient: `fail_sync_inbox` dengan retry_at; error permanen: failed/rejected.
7. Event dengan predecessor gap berstatus deferred dan tidak boleh melewati cursor.
8. Replay/skip harus melalui action audit dan role khusus.

### 8.3 Store Master Pull Worker

1. Baca cursor lokal terakhir.
2. Pull satu batch change log.
3. Validasi target scope, entity_version, schema, dan effective_at.
4. Terapkan perubahan idempotent dalam transaksi lokal.
5. Update cursor lokal atomik dengan penerapan batch.
6. Kirim master ACK ke cloud setelah commit lokal.
7. Retry tanpa menghapus cursor bila batch gagal.

### 8.4 Reporting Worker

Update agregasi dari fakta `replica` setelah transaksi projection commit. Gunakan watermark/queue internal dan operasi idempotent. Laporan dapat tertunda tanpa memengaruhi final ACK transaksi; laporan bukan bagian dari transaksi ACK.

## 9. Event catalog awal

| Aggregate | Event type | Final payload minimum |
|---|---|---|
| sale | `sale.paid` | header + lines + discounts + confirmed payments |
| refund | `refund.paid` | header + lines + payout + original sale ID |
| cash_session | `cash.session.closed` | session totals + drawer/store/terminal/cashier |
| cash_ledger | `cash.ledger.recorded` | entry + approval + source reference |
| cash_deposit | `cash.deposit.recorded` | amount + expected + variance + actor/reason |
| cash_handover | `cash.handover.confirmed` | from/to session/cashier + amount + variance |
| customer | `customer.created`, `customer.updated` | canonical candidate data + local source ID |
| audit_event | `audit.recorded` | action/entity/actor/reason/before/after/correlation |
| terminal | `terminal.status` | telemetry; preferably separate stream |

Event names and exact payload JSON Schema must be versioned and finalized separately. A sale event should represent the final PAID aggregate; drafts and Hold Orders are not sent to cloud.

## 10. Observability, security, and operations

- TLS wajib; credential scope hanya satu store-server dan store_id yang terdaftar.
- Rate limit per node/store; max body size; request timeout; clock skew monitored.
- Log request_id, node_id, event_id, aggregate, outcome, duration; jangan log secret, PIN, bukti pembayaran, atau PII penuh.
- Credential rotation/revocation tanpa menghapus event pending.
- Metrics: outbox depth/age, inbox depth/age, event processing latency, retry count, failed count, lease expiry, cursor lag, master cursor lag, node heartbeat age.
- Alert threshold mengikuti spesifikasi: offline 5 menit; warning 15 menit; critical 60 menit; backlog 100.
- Backup dan restore test cloud terpisah dari local.
- Manual replay/skip memerlukan alasan, actor, approval/permission, dan immutable audit trail.

## 11. Keputusan yang perlu disahkan sebelum API/worker coding

1. Mekanisme autentikasi mesin: OAuth client credentials, HMAC signing, atau mTLS.
2. Batas batch/payload dan timeout final berdasarkan load test.
3. Event payload JSON Schema final dan daftar event mana yang wajib dikirim.
4. Kebijakan customer merge saat nomor telepon konflik lintas toko.
5. Alokasi kuota promosi offline per toko.
6. Detail bootstrap master snapshot dan pemulihan cursor kedaluwarsa.
7. Apakah event audit lengkap atau subset audit yang dikirim ke cloud.
8. Cara menyimpan receipt pembayaran: object storage copy atau URI terproteksi.
9. Apakah terminal submit PAID sale hanya setelah finalisasi lokal penuh, atau juga perlu mengirim PAYMENT_PENDING sebagai event operasional.
10. Kebijakan retention payload raw event, retry failed, dan dead-letter.

## 12. Batas tahap ini

Ini adalah kontrak logis v0.1. Belum ada FastAPI route, Pydantic schema, worker Python, DDL cloud, atau integration test runtime. Implementasi baru dimulai setelah kontrak dan keputusan terbuka disetujui.
