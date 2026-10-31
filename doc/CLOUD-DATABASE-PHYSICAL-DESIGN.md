# Desain Fisik Database Cloud POS

**Versi:** 0.1 (physical logical design)  
**Tanggal:** 31 Oktober 2026  
**Status:** Draft review; bukan migration dan belum production-ready  
**Target:** PostgreSQL 16 minimum; versi mayor lebih baru setelah uji kompatibilitas.

Dokumen ini mendefinisikan kolom, tipe, nullability, PK, FK, unique/check constraint, dan index untuk tabel cloud. Semua nama tabel fully-qualified. Ini database cloud terpisah; migration lokal toko 001–004 tidak dijalankan di sini.

## 1. Konvensi umum

- UUID PK memakai `uuid`; default `gen_random_uuid()`. ID sumber dari toko disimpan terpisah sebagai `source_*_id`.
- Waktu absolut memakai `timestamptz`; tanggal bisnis memakai `date`; jam operasional lokal memakai `time`; timezone toko IANA disimpan pada `cloud.stores.timezone`.
- Uang memakai `numeric(18,2)`; kuantitas POS `integer`; persentase/rate `numeric(7,4)`; counter/sequence `bigint`.
- Kode bisnis memakai `varchar` dengan batas eksplisit; teks bebas `text`; snapshot/payload fleksibel `jsonb`.
- Semua tabel mutable memiliki `created_at timestamptz NOT NULL DEFAULT now()`; tabel yang bisa diubah juga `updated_at`. Tabel append-only tidak memiliki updated_at.
- FK menggunakan `ON DELETE RESTRICT` secara default. Hapus master dilakukan deactivate/soft delete. CASCADE hanya untuk tabel anak konfigurasi yang tidak memiliki nilai historis.
- Semua tabel scoped toko memiliki `store_id` FK. API harus menerapkan tenant authorization; RLS dapat ditambahkan sebagai defense-in-depth, bukan pengganti authorization.
- Constraint lintas tabel/penjumlahan/urutan transaksi dijalankan melalui transaksi service dan deferred constraint trigger bila diperlukan; CHECK tidak boleh dipakai untuk membaca tabel lain.
- Semua unique idempotency global harus berada pada tabel registry non-partitioned, tidak hanya pada tabel partisi.

Notasi spesifikasi per tabel:
- **PK** primary key; **FK** foreign key; **UQ** unique; **CK** check; **IX** index.
- Kolom yang ditandai `?` nullable. Kolom lain NOT NULL kecuali dinyatakan default.

## 2. Schema cloud

### 2.1 Registry organisasi dan node

#### `cloud.stores`
- Kolom: `id uuid`; `code varchar(20)`; `name varchar(160)`; `timezone varchar(64) DEFAULT 'Asia/Jakarta'`; `currency_code char(3) DEFAULT 'IDR'`; `status varchar(16) DEFAULT 'active'`; `created_at timestamptz`; `updated_at timestamptz`.
- PK: `id`. UQ: `code`. CK: status IN ('active','inactive','suspended'); currency_code ~ '^[A-Z]{3}$'.
- IX: `(status,code)`.

#### `cloud.store_servers`
- Kolom: `id uuid`; `store_id uuid`; `server_code varchar(40)`; `display_name varchar(120)?`; `status varchar(20) DEFAULT 'provisioning'`; `app_version varchar(40)?`; `registered_at timestamptz`; `disabled_at timestamptz?`; `created_at timestamptz`; `updated_at timestamptz`.
- PK: `id`. FK: store_id → stores. UQ: `(store_id,server_code)`. CK: status IN ('provisioning','active','disabled','retired'); disabled_at IS NULL OR disabled_at >= registered_at.
- IX: `(store_id,status)`; partial unique active server per store only if the deployment policy guarantees exactly one active server: `UNIQUE(store_id) WHERE status='active'`. Default design permits controlled replacement overlap during migration.

#### `cloud.terminals`
- Kolom: `id uuid`; `store_id uuid`; `terminal_code varchar(30)`; `name varchar(100)?`; `primary_user_id uuid?`; `app_version varchar(40)?`; `status varchar(20) DEFAULT 'active'`; `disabled_at timestamptz?`; `created_at timestamptz`; `updated_at timestamptz`.
- PK id. FK store_id → stores; primary_user_id → users. UQ `(store_id,terminal_code)`. CK status IN ('active','disabled','retired').
- IX `(store_id,status)`.

#### `cloud.sync_nodes`
- Kolom: `id uuid`; `node_code varchar(60)`; `node_type varchar(20)`; `store_id uuid?`; `store_server_id uuid?`; `terminal_id uuid?`; `status varchar(20) DEFAULT 'unknown'`; `created_at timestamptz`; `updated_at timestamptz`.
- PK id. FK store_id → stores; store_server_id → store_servers; terminal_id → terminals. UQ node_code; UQ store_server_id (nullable).
- CK node_type IN ('store_server','terminal','cloud_service') and ownership shape: store_server requires store_id + store_server_id and no terminal_id; terminal requires store_id + terminal_id and no store_server_id; cloud_service requires all ownership refs NULL.
- IX `(store_id,node_type,status)`.

#### `cloud.node_credentials`
- Kolom: `id uuid`; `node_id uuid`; `client_id varchar(100)`; `client_secret_hash text`; `credential_version integer DEFAULT 1`; `allowed_scopes text[]`; `valid_from timestamptz`; `expires_at timestamptz?`; `revoked_at timestamptz?`; `created_at timestamptz`; `rotated_from_id uuid?`; `created_by uuid?`.
- PK id. FK node_id → sync_nodes; rotated_from_id → node_credentials; created_by → users. UQ client_id.
- CK credential_version > 0; expires_at IS NULL OR expires_at > valid_from; revoked_at IS NULL OR revoked_at >= valid_from; cardinality(allowed_scopes)>0.
- IX `(node_id,valid_from DESC)`; partial IX `(client_id) WHERE revoked_at IS NULL`.
- Secret plaintext tidak disimpan. Dua credential boleh overlap sementara saat rotasi.

#### `cloud.node_heartbeats`
- Kolom: `id uuid`; `node_id uuid`; `observed_at timestamptz`; `received_at timestamptz DEFAULT now()`; `app_version varchar(40)?`; `outbox_pending_count integer DEFAULT 0`; `oldest_pending_at timestamptz?`; `inbox_failed_count integer DEFAULT 0`; `last_success_at timestamptz?`; `clock_offset_seconds integer?`; `health_flags jsonb DEFAULT '{}'`.
- PK id. FK node_id → sync_nodes. CK counts >= 0.
- IX `(node_id,observed_at DESC)`, BRIN `(received_at)`. Candidate monthly partition by received_at after volume measurement.

### 2.2 IAM

#### `cloud.users`
- Kolom: `id uuid`; `employee_code varchar(40)`; `full_name varchar(160)`; `status varchar(20) DEFAULT 'active'`; `failed_pin_attempts smallint DEFAULT 0`; `locked_until timestamptz?`; `created_at timestamptz`; `updated_at timestamptz`.
- PK id. UQ employee_code. CK status IN ('active','locked','inactive'); failed_pin_attempts BETWEEN 0 AND 5.
- IX `(status,employee_code)`. PIN hash disimpan pada credential/auth service atau field terpisah yang terenkripsi/terproteksi; jangan kirim PIN plaintext ke toko.

#### `cloud.roles`
- Kolom: `id uuid`; `code varchar(30)`; `name varchar(80)`; `description text?`; `is_system boolean DEFAULT false`; `created_at timestamptz`.
- PK id. UQ code. IX `(is_system,code)`.

#### `cloud.permissions`
- Kolom: `id uuid`; `code varchar(100)`; `description text?`.
- PK id. UQ code.

#### `cloud.role_permissions`
- Kolom: `role_id uuid`; `permission_id uuid`; `created_at timestamptz`.
- PK `(role_id,permission_id)`. FK role_id → roles ON DELETE CASCADE; permission_id → permissions ON DELETE CASCADE. IX `(permission_id,role_id)`.

#### `cloud.user_store_assignments`
- Kolom: `id uuid`; `user_id uuid`; `store_id uuid`; `valid_from timestamptz`; `valid_until timestamptz?`; `created_at timestamptz`.
- PK id. FK user_id → users; store_id → stores. CK valid_until IS NULL OR valid_until > valid_from.
- IX `(user_id,store_id,valid_from DESC)`; partial unique `(user_id,store_id) WHERE valid_until IS NULL` (satu assignment aktif).

#### `cloud.user_role_assignments`
- Kolom: `id uuid`; `user_id uuid`; `role_id uuid`; `store_id uuid?`; `valid_from timestamptz`; `valid_until timestamptz?`; `created_at timestamptz`.
- PK id. FK user_id → users; role_id → roles; store_id → stores. CK valid_until IS NULL OR valid_until > valid_from.
- IX `(user_id,store_id,valid_from DESC)`; partial unique `(user_id,role_id,store_id) WHERE valid_until IS NULL`. Catatan: global scope store_id NULL; unique NULL semantics perlu ditangani dengan dua partial unique index (global dan scoped).

#### `cloud.terminal_authorizations`
- Kolom: `id uuid`; `user_id uuid`; `terminal_id uuid`; `authorized_by uuid`; `expires_at timestamptz?`; `revoked_at timestamptz?`; `created_at timestamptz`.
- PK id. FK user_id → users; terminal_id → terminals; authorized_by → users. CK expires_at IS NULL OR expires_at > created_at.
- IX `(terminal_id,user_id,expires_at)`; partial unique `(terminal_id,user_id) WHERE revoked_at IS NULL`.

#### `cloud.user_security_events`
- Kolom: `id uuid`; `user_id uuid`; `actor_user_id uuid?`; `store_id uuid?`; `event_type varchar(40)`; `reason text?`; `metadata jsonb DEFAULT '{}'`; `occurred_at timestamptz`.
- PK id. FK user_id → users; actor_user_id → users; store_id → stores. CK event_type IN ('pin_reset','locked','unlocked','deactivated','reactivated','store_transfer','role_changed','credential_revoked').
- IX `(user_id,occurred_at DESC)`; `(store_id,occurred_at DESC)`.

### 2.3 Produk dan master

#### `cloud.categories`
- Kolom: `id uuid`; `code varchar(40)`; `name varchar(120)`; `parent_id uuid?`; `sort_order integer DEFAULT 0`; `is_active boolean DEFAULT true`; `version bigint DEFAULT 1`; `created_at timestamptz`; `updated_at timestamptz`.
- PK id. FK parent_id → categories. UQ code. CK parent_id IS NULL OR parent_id <> id; version > 0.
- IX `(parent_id,sort_order)`; `(is_active,sort_order)`.

#### `cloud.products`
- Kolom: `id uuid`; `sku varchar(50)`; `name varchar(200)`; `description text?`; `category_id uuid?`; `base_uom_code varchar(20)`; `image_uri text?`; `status varchar(20) DEFAULT 'active'`; `version bigint DEFAULT 1`; `created_at timestamptz`; `updated_at timestamptz`.
- PK id. FK category_id → categories; base_uom_code → uoms(code). UQ sku. CK status IN ('active','inactive','retired'); version > 0.
- IX `(category_id,status)`; trigram/search index on normalized name only if enabled extension is approved.

#### `cloud.product_barcodes`
- Kolom: `id uuid`; `product_id uuid`; `barcode varchar(100)`; `barcode_type varchar(20) DEFAULT 'CODE128'`; `is_active boolean DEFAULT true`; `created_at timestamptz`.
- PK id. FK product_id → products. Partial UQ barcode WHERE is_active. IX `(product_id)`.

#### `cloud.product_prices`
- Kolom: `id uuid`; `product_id uuid`; `price numeric(18,2)`; `valid_from timestamptz`; `valid_until timestamptz?`; `version bigint`; `created_by uuid?`; `created_at timestamptz`.
- PK id. FK product_id → products; created_by → users. UQ `(product_id,version)`. CK price >= 0; valid_until IS NULL OR valid_until > valid_from; version > 0.
- IX `(product_id,valid_from DESC)`. Overlap prevention for effective ranges requires exclusion constraint on `(product_id WITH =, tstzrange(valid_from,valid_until,'[)') WITH &&)` using btree_gist; extension approval required. If extension is not approved, serialize price publication per product and validate overlap in transaction.

#### `cloud.product_tax_rules`
- Kolom: `id uuid`; `product_id uuid`; `tax_code varchar(30)`; `tax_rate numeric(7,4)`; `valid_from timestamptz`; `valid_until timestamptz?`; `version bigint`; `created_at timestamptz`.
- PK id. FK product_id → products. UQ `(product_id,tax_code,version)`. CK tax_rate BETWEEN 0 AND 100; valid_until IS NULL OR valid_until > valid_from; version > 0.
- IX `(product_id,tax_code,valid_from DESC)`; overlap prevention same method as product_prices.

#### `cloud.product_store_availability`
- Kolom: `id uuid`; `product_id uuid`; `store_id uuid`; `is_available boolean DEFAULT true`; `reason text?`; `updated_at timestamptz`.
- PK id. FK product_id → products; store_id → stores. UQ `(product_id,store_id)`. IX `(store_id,is_available)`.

#### `cloud.product_display_order`
- Kolom: `id uuid`; `terminal_id uuid`; `product_id uuid`; `sort_order integer DEFAULT 0`; `is_favorite boolean DEFAULT false`; `updated_at timestamptz`.
- PK id. FK terminal_id → terminals; product_id → products. UQ `(terminal_id,product_id)`. CK sort_order >= 0. IX `(terminal_id,is_favorite,sort_order)`.

#### `cloud.uoms`
- Kolom: `code varchar(20)`; `name varchar(80)`; `description text?`; `is_active boolean DEFAULT true`.
- PK code. IX `(is_active,name)`.

### 2.4 Promosi dan kebijakan POS

#### `cloud.promotions`
- Kolom: `id uuid`; `code varchar(40)`; `name varchar(160)`; `promotion_type varchar(30)`; `starts_at timestamptz`; `ends_at timestamptz`; `priority integer DEFAULT 0`; `is_active boolean DEFAULT true`; `version bigint DEFAULT 1`; `created_at timestamptz`; `updated_at timestamptz`.
- PK id. UQ code. CK ends_at > starts_at; version > 0.
- IX `(is_active,starts_at,ends_at)`.

#### `cloud.promotion_conditions`
- Kolom: `id uuid`; `promotion_id uuid`; `condition_type varchar(30)`; `condition_data jsonb DEFAULT '{}'`; `created_at timestamptz`.
- PK id. FK promotion_id → promotions ON DELETE CASCADE. IX `(promotion_id)`; CK condition_type <> ''.

#### `cloud.promotion_benefits`
- Kolom: `id uuid`; `promotion_id uuid`; `benefit_type varchar(30)`; `benefit_data jsonb DEFAULT '{}'`; `created_at timestamptz`.
- PK id. FK promotion_id → promotions ON DELETE CASCADE. IX `(promotion_id)`; CK benefit_type <> ''.

#### `cloud.promotion_products`
- Kolom: `promotion_id uuid`; `product_id uuid`; `scope_type varchar(20) DEFAULT 'include'`.
- PK `(promotion_id,product_id,scope_type)`. FK promotion_id → promotions ON DELETE CASCADE; product_id → products. CK scope_type IN ('include','exclude'). IX `(product_id,promotion_id)`.

#### `cloud.promotion_quotas`
- Kolom: `id uuid`; `promotion_id uuid`; `total_limit bigint?`; `per_customer_limit bigint?`; `created_at timestamptz`; `updated_at timestamptz`.
- PK id. FK promotion_id → promotions. UQ promotion_id. CK total_limit IS NULL OR >= 0; per_customer_limit IS NULL OR >= 0.
- IX `(promotion_id)`.

#### `cloud.promotion_quota_allocations`
- Kolom: `id uuid`; `promotion_id uuid`; `store_id uuid`; `allocated_quantity bigint`; `consumed_quantity bigint DEFAULT 0`; `valid_from timestamptz`; `valid_until timestamptz`; `allocation_version bigint DEFAULT 1`; `grant_digest bytea`; `status varchar(20) DEFAULT 'active'`; `closed_at timestamptz?`; `created_at timestamptz`; `updated_at timestamptz`.
- PK id. FK promotion_id → promotions; store_id → stores. CK allocated_quantity >= 0; consumed_quantity BETWEEN 0 AND allocated_quantity; valid_until > valid_from; allocation_version > 0; status IN ('active','closed','expired','revoked'); closed_at IS NULL OR status <> 'active'.
- IX `(promotion_id,store_id,status)`; `(store_id,valid_until)`. Allocation totals/remaining must be updated under row lock in the same transaction; global cap is cross-row invariant enforced by service transaction/locking, not CHECK.

#### `cloud.payment_methods`
- Kolom: `id uuid`; `code varchar(30)`; `name varchar(80)`; `method_type varchar(30)`; `requires_reference boolean DEFAULT false`; `is_cash boolean DEFAULT false`; `is_active boolean DEFAULT true`; `version bigint DEFAULT 1`; `created_at timestamptz`; `updated_at timestamptz`.
- PK id. UQ code. CK version > 0; is_cash implies method_type='cash'.
- IX `(is_active,method_type)`.

#### `cloud.store_hours`
- Kolom: `id uuid`; `store_id uuid`; `weekday smallint`; `opens_at time`; `closes_at time`; `effective_from date?`; `effective_until date?`; `is_closed boolean DEFAULT false`; `created_at timestamptz`.
- PK id. FK store_id → stores. CK weekday BETWEEN 1 AND 7; effective_until IS NULL OR effective_from IS NULL OR effective_until >= effective_from; is_closed OR opens_at <> closes_at.
- IX `(store_id,weekday,effective_from)`.

#### `cloud.store_exceptions`
- Kolom: `id uuid`; `store_id uuid`; `starts_at timestamptz`; `ends_at timestamptz`; `reason text`; `created_by uuid`; `created_at timestamptz`.
- PK id. FK store_id → stores; created_by → users. CK ends_at > starts_at. IX `(store_id,starts_at)`.

#### `cloud.cash_drawer_policies`
- Kolom: `id uuid`; `terminal_id uuid`; `fixed_float_amount numeric(18,2)`; `currency_code char(3) DEFAULT 'IDR'`; `valid_from timestamptz`; `valid_until timestamptz?`; `is_active boolean DEFAULT true`; `created_at timestamptz`.
- PK id. FK terminal_id → terminals. CK fixed_float_amount >= 0; valid_until IS NULL OR valid_until > valid_from; currency_code ~ '^[A-Z]{3}$'.
- IX `(terminal_id,valid_from DESC)`; partial unique active policy per terminal `(terminal_id) WHERE is_active`.

#### `cloud.receipt_policies`
- Kolom: `id uuid`; `store_id uuid`; `max_reprints integer DEFAULT 2`; `auto_print boolean DEFAULT true`; `paper_width_mm smallint DEFAULT 80`; `valid_from timestamptz`; `valid_until timestamptz?`; `created_at timestamptz`.
- PK id. FK store_id → stores. CK max_reprints >= 0; paper_width_mm IN (58,80); valid_until IS NULL OR valid_until > valid_from.
- IX `(store_id,valid_from DESC)`; partial unique current policy per store may be enforced by service/exclusion range.

### 2.5 Pelanggan canonical

#### `cloud.customers`
- Kolom: `id uuid`; `canonical_customer_id uuid?`; `name varchar(160)`; `address text?`; `date_of_birth date?`; `status varchar(20) DEFAULT 'active'`; `created_at timestamptz`; `updated_at timestamptz`.
- PK id. FK canonical_customer_id → customers. UQ not applicable. CK status IN ('active','inactive','merged'); canonical_customer_id IS NULL OR canonical_customer_id <> id; status='merged' requires canonical_customer_id NOT NULL.
- IX `(canonical_customer_id)`; `(status,name)`.
- Canonical ID adalah record paling awal; transaksi historis mempertahankan customer ID asal. Merge tidak menghapus customer sumber.

#### `cloud.customer_phone_aliases`
- Kolom: `id uuid`; `customer_id uuid`; `normalized_phone varchar(30)`; `is_primary boolean DEFAULT false`; `is_active boolean DEFAULT true`; `created_at timestamptz`; `retired_at timestamptz?`.
- PK id. FK customer_id → customers. Partial UQ normalized_phone WHERE is_active. CK normalized_phone ~ '^\+[1-9][0-9]{7,14}$'; retired_at IS NULL OR NOT is_active.
- IX `(customer_id,is_active)`. E.164 normalization is application responsibility plus validation.

#### `cloud.customer_merge_events`
- Kolom: `id uuid`; `source_customer_id uuid`; `target_customer_id uuid`; `trigger_phone varchar(30)?`; `conflict_fields jsonb DEFAULT '{}'`; `merge_reason varchar(40)`; `created_at timestamptz`.
- PK id. FK source_customer_id/target_customer_id → customers. UQ source_customer_id (satu merge final per sumber). CK source_customer_id <> target_customer_id.
- IX `(target_customer_id,created_at DESC)`.

### 2.6 Distribusi master

#### `cloud.master_change_log`
- Kolom: `change_seq bigint`; `entity_type varchar(60)`; `entity_id uuid`; `entity_version bigint`; `operation varchar(20)`; `target_store_id uuid?`; `effective_at timestamptz`; `payload jsonb`; `published_at timestamptz DEFAULT now()`.
- PK change_seq. FK target_store_id → stores. UQ `(entity_type,entity_id,entity_version,target_store_id)` perlu NULL-safe handling (gunakan dua partial unique index atau NULLS NOT DISTINCT PostgreSQL 15+).
- CK entity_version > 0; operation IN ('upsert','deactivate'); payload IS JSON object.
- IX `(target_store_id,change_seq)`; `(change_seq)`. Global stream counter row lock + log insert + master mutation must commit in one transaction.

#### `cloud.master_stream_counter`
- Kolom: `stream_key varchar(60)`; `last_change_seq bigint DEFAULT 0`; `updated_at timestamptz`.
- PK stream_key. CK last_change_seq >= 0.

#### `cloud.store_master_cursors`
- Kolom: `id uuid`; `node_id uuid`; `store_id uuid`; `stream_key varchar(60)`; `applied_change_seq bigint DEFAULT 0`; `last_ack_at timestamptz?`; `updated_at timestamptz`.
- PK id. FK node_id → sync_nodes; store_id → stores. UQ `(node_id,stream_key)`. CK applied_change_seq >= 0.
- IX `(store_id,stream_key,applied_change_seq)`.

#### `cloud.master_snapshots`
- Kolom: `id uuid`; `store_id uuid`; `snapshot_cursor bigint`; `object_uri text`; `checksum_sha256 bytea`; `size_bytes bigint`; `schema_version integer`; `status varchar(20) DEFAULT 'ready'`; `created_at timestamptz`; `expires_at timestamptz?`.
- PK id. FK store_id → stores. UQ `(store_id,snapshot_cursor)`. CK size_bytes >= 0; schema_version > 0; status IN ('building','ready','expired','failed').
- IX `(store_id,created_at DESC)`.

## 3. Schema ingest

#### `ingest.event_idempotency_registry`
- Kolom: `id uuid`; `source_node_id uuid`; `event_id uuid`; `idempotency_key varchar(140)`; `aggregate_type varchar(60)`; `aggregate_id uuid`; `aggregate_version bigint`; `payload_sha256 bytea`; `received_event_id uuid?`; `first_seen_at timestamptz`; `final_status varchar(20)?`.
- PK id. FK source_node_id → cloud.sync_nodes; received_event_id → received_events (deferred FK or add after table creation). UQ `(source_node_id,event_id)`; UQ `(source_node_id,idempotency_key)`; UQ `(source_node_id,aggregate_type,aggregate_id,aggregate_version)`.
- CK aggregate_version > 0; octet_length(payload_sha256)=32; final_status IN ('processed','rejected','dead_letter') OR NULL.
- IX `(source_node_id,first_seen_at)`. Non-partitioned; retained as long as duplicate prevention is required, even after raw payload expiry.

#### `replica.source_entity_registry`
- Kolom: `id uuid`; `source_store_id uuid`; `entity_type varchar(40)`; `source_entity_id uuid`; `replica_table varchar(80)`; `replica_id uuid`; `business_date date?`; `registered_at timestamptz`.
- PK id. FK source_store_id → cloud.stores. UQ `(source_store_id,entity_type,source_entity_id)`.
- IX `(replica_table,replica_id)`; `(source_store_id,business_date)`.
- Non-partitioned global identity registry. Menjaga identitas sumber tetap unik saat tabel fakta dipartisi; insert registry dan row fakta wajib dalam transaksi yang sama.

#### `ingest.received_events`
- Kolom: `id uuid`; `source_node_id uuid`; `source_store_id uuid`; `event_id uuid`; `idempotency_key varchar(140)`; `aggregate_type varchar(60)`; `aggregate_id uuid`; `aggregate_version bigint`; `event_type varchar(80)`; `schema_version integer`; `occurred_at timestamptz`; `correlation_id uuid?`; `payload_sha256 bytea`; `payload jsonb?`; `status varchar(20) DEFAULT 'received'`; `received_at timestamptz`; `processed_at timestamptz?`; `next_retry_at timestamptz?`; `dead_lettered_at timestamptz?`; `last_error_code varchar(60)?`; `last_error text?`.
- PK id. FK source_node_id → sync_nodes; source_store_id → stores. Registry relation by registry.received_event_id → id (circular relation finalized after both tables exist).
- CK aggregate_version > 0; schema_version > 0; octet_length(payload_sha256)=32; status IN ('received','processing','deferred','processed','rejected','dead_letter'); payload IS NULL OR jsonb_typeof(payload)='object'.
- IX `(status,next_retry_at,received_at)`; `(source_node_id,aggregate_type,aggregate_id,aggregate_version)`; BRIN `(received_at)`.
- Partition candidate by received_at month. Keep registry non-partitioned. For processed event after 90 days, payload can be nulled/deleted but compact envelope/hash/status remains as long as operational dedupe requires. Dead-letter payload retention rule remains until resolution + 1 year.

#### `ingest.aggregate_cursors`
- Kolom: `source_node_id uuid`; `aggregate_type varchar(60)`; `aggregate_id uuid`; `last_processed_version bigint DEFAULT 0`; `last_event_id uuid?`; `updated_at timestamptz`.
- PK `(source_node_id,aggregate_type,aggregate_id)`. FK source_node_id → sync_nodes. CK last_processed_version >= 0.
- IX `(updated_at)`.

#### `ingest.delivery_attempts`
- Kolom: `id uuid`; `received_event_id uuid`; `attempted_at timestamptz`; `outcome varchar(20)`; `http_status smallint?`; `error_code varchar(60)?`; `error_detail text?`; `duration_ms integer?`; `worker_id varchar(100)?`.
- PK id. FK received_event_id → received_events. CK outcome IN ('accepted','processed','deferred','rejected','conflict','error'); http_status BETWEEN 100 AND 599 OR NULL; duration_ms >= 0 OR NULL.
- IX `(received_event_id,attempted_at DESC)`; BRIN `(attempted_at)`. Partition candidate by attempted_at month.

#### `ingest.replay_actions`
- Kolom: `id uuid`; `received_event_id uuid`; `action varchar(20)`; `actor_user_id uuid`; `reason text`; `approval_user_id uuid?`; `created_at timestamptz`; `result varchar(20)`; `metadata jsonb DEFAULT '{}'`.
- PK id. FK received_event_id → received_events; actor_user_id/approval_user_id → cloud.users.
- CK action IN ('replay','skip','close_dead_letter'); result IN ('requested','succeeded','failed'); length(trim(reason)) > 0; approval_user_id IS NULL OR approval_user_id <> actor_user_id.
- IX `(received_event_id,created_at DESC)`; `(actor_user_id,created_at DESC)`.

#### `ingest.retention_actions`
- Kolom: `id uuid`; `target_type varchar(40)`; `target_id uuid`; `action varchar(30)`; `actor_type varchar(30)`; `actor_user_id uuid?`; `reason text`; `metadata jsonb DEFAULT '{}'`; `executed_at timestamptz`; `result varchar(20)`.
- PK id. FK actor_user_id → cloud.users.
- CK action IN ('payload_purge','dead_letter_purge','metadata_purge'); actor_type IN ('user','retention_job','system'); result IN ('succeeded','failed','skipped'); length(trim(reason)) > 0.
- IX `(target_type,target_id,executed_at DESC)`; `(executed_at DESC)`.
- Retention job wajib mencatat setiap purge termasuk target, aturan retensi, jumlah byte/row, dan legal-hold check. Record audit tidak ikut dihapus oleh job yang dicatatnya.

#### `ingest.node_sync_status`
- Kolom: `node_id uuid`; `stream_name varchar(60)`; `pending_count bigint DEFAULT 0`; `failed_count bigint DEFAULT 0`; `oldest_pending_at timestamptz?`; `last_received_at timestamptz?`; `last_processed_at timestamptz?`; `last_error_code varchar(60)?`; `updated_at timestamptz`.
- PK `(node_id,stream_name)`. FK node_id → sync_nodes. CK pending_count >= 0; failed_count >= 0.
- IX `(updated_at)`; `(stream_name,pending_count DESC)`.

## 4. Schema replica

### 4.1 Konvensi fakta transaksi
Semua tabel fakta transaksi memiliki `source_store_id uuid NOT NULL`, `source_node_id uuid NOT NULL`, `source_entity_id uuid NOT NULL`, `source_created_at timestamptz NOT NULL`, `received_at timestamptz NOT NULL DEFAULT now()`. FK ke stores dan sync_nodes. Unique identitas asal menggunakan `(source_store_id,source_entity_id)` pada tabel header. Detail memakai `source_entity_id` unik per store bila ID asal tersedia. Snapshot transaksi tidak FK ke master produk/user agar histori tetap utuh walau master berubah; gunakan source IDs dan snapshot code/name.

#### `replica.sales`
- Kolom: `id uuid`; kolom asal di atas; `source_cashier_id uuid`; `source_terminal_id uuid`; `source_customer_id uuid?`; `receipt_number varchar(80)`; `business_date date`; `currency_code char(3)`; `subtotal numeric(18,2)`; `discount_total numeric(18,2)`; `tax_total numeric(18,2)`; `rounding_amount numeric(18,2)`; `grand_total numeric(18,2)`; `paid_at timestamptz`; `payload_schema_version integer`.
- PK id. FK source_store_id → stores; source_node_id → sync_nodes. UQ `(source_store_id,source_entity_id)`; UQ `(source_store_id,receipt_number)`.
- CK all totals except rounding >= 0; grand_total >= 0; currency uppercase; payload_schema_version > 0.
- IX `(source_store_id,business_date,paid_at)`; `(source_store_id,source_cashier_id,paid_at DESC)`; `(source_store_id,source_customer_id,business_date)`; BRIN received_at.
- PAID-only: no status column required; row existence means paid. Immutable after insert. Partition by business_date only after volume; unique source IDs then enforced via non-partitioned registry.

#### `replica.sale_lines`
- Kolom: `id uuid`; `sale_id uuid`; `source_store_id uuid`; `source_entity_id uuid`; `source_product_id uuid?`; `sku_snapshot varchar(50)`; `name_snapshot varchar(200)`; `barcode_snapshot varchar(100)?`; `quantity integer`; `unit_price numeric(18,2)`; `gross_amount numeric(18,2)`; `discount_amount numeric(18,2)`; `taxable_base numeric(18,2)`; `tax_code_snapshot varchar(30)?`; `tax_rate_snapshot numeric(7,4)`; `tax_amount numeric(18,2)`; `line_total numeric(18,2)`; `price_version bigint?`; `tax_version bigint?`; `promotion_snapshot jsonb?`.
- PK id. FK sale_id → sales. UQ `(source_store_id,source_entity_id)`.
- CK quantity > 0; all money >= 0; tax_rate BETWEEN 0 AND 100; price_version/tax_version > 0 OR NULL.
- IX `(sale_id)`; `(source_store_id,source_product_id)`; `(source_store_id,sku_snapshot)`.

#### `replica.sale_discounts`
- Kolom: `id uuid`; `sale_id uuid`; `source_store_id uuid`; `source_entity_id uuid`; `source_sale_line_id uuid?`; `discount_type varchar(30)`; `amount numeric(18,2)`; `source varchar(20)`; `promotion_id uuid?`; `applied_by_source_user_id uuid?`; `reason text?`.
- PK id. FK sale_id → sales; sale_line_id → sale_lines. UQ `(source_store_id,source_entity_id)`.
- CK amount >= 0; source IN ('promotion','manual').
- IX `(sale_id)`; `(promotion_id)`.

#### `replica.sale_promotion_cancellations`
- Kolom: `id uuid`; `sale_id uuid`; `source_store_id uuid`; `source_entity_id uuid`; `promotion_id uuid`; `reason text`; `cancelled_by_source_user_id uuid`; `cancelled_at timestamptz`.
- PK id. FK sale_id → sales. UQ `(source_store_id,source_entity_id)`. CK length(trim(reason)) > 0.
- IX `(sale_id)`; `(promotion_id,cancelled_at)`.

#### `replica.payments`
- Kolom: `id uuid`; `sale_id uuid`; `source_store_id uuid`; `source_entity_id uuid`; `source_payment_method_id uuid`; `payment_method_code_snapshot varchar(30)`; `payment_method_name_snapshot varchar(80)`; `amount numeric(18,2)`; `status varchar(20)`; `reference_number varchar(120)?`; `confirmed_by_source_user_id uuid?`; `confirmed_at timestamptz`; `created_at_source timestamptz`.
- PK id. FK sale_id → sales. UQ `(source_store_id,source_entity_id)`.
- CK amount > 0; status = 'confirmed'; confirmed_at IS NOT NULL.
- IX `(sale_id)`; `(source_store_id,payment_method_code_snapshot,confirmed_at)`.

#### `replica.payment_evidence`
- Kolom: `id uuid`; `payment_id uuid`; `source_store_id uuid`; `source_entity_id uuid`; `object_key text`; `protected_uri text`; `checksum_sha256 bytea`; `size_bytes bigint`; `mime_type varchar(100)`; `sanitized_filename varchar(255)?`; `uploaded_at timestamptz`; `verified_at timestamptz?`; `status varchar(20) DEFAULT 'verified'`.
- PK id. FK payment_id → payments. UQ `(source_store_id,source_entity_id)`; UQ object_key.
- CK octet_length(checksum_sha256)=32; size_bytes > 0; status IN ('pending_upload','verified','quarantined','deleted'); verified_at IS NULL OR verified_at >= uploaded_at.
- IX `(payment_id)`; `(status,uploaded_at)`. Binary object is outside PostgreSQL; no public URL.

#### `replica.refunds`
- Kolom: `id uuid`; kolom asal di atas; `source_original_sale_id uuid`; `source_processed_by_user_id uuid`; `reason text`; `total_amount numeric(18,2)`; `completed_at timestamptz`; `refund_method_code_snapshot varchar(30)`.
- PK id. FK source_store_id → stores; source_node_id → sync_nodes. UQ `(source_store_id,source_entity_id)`.
- CK total_amount > 0; length(trim(reason)) > 0.
- IX `(source_store_id,source_original_sale_id)`; `(source_store_id,completed_at DESC)`.
- Original sale is a cross-event dependency: resolve by source store + source sale ID; do not FK to local UUID alone.

#### `replica.refund_lines`
- Kolom: `id uuid`; `refund_id uuid`; `source_store_id uuid`; `source_entity_id uuid`; `source_original_sale_line_id uuid`; `sku_snapshot varchar(50)`; `name_snapshot varchar(200)`; `quantity integer`; `refund_amount numeric(18,2)`; `item_received boolean`; `item_resalable boolean`; `stock_return_eligible boolean`.
- PK id. FK refund_id → refunds. UQ `(source_store_id,source_entity_id)`.
- CK quantity > 0; refund_amount > 0; stock_return_eligible = (item_received AND item_resalable).
- IX `(refund_id)`; `(source_store_id,source_original_sale_line_id)`.

#### `replica.refund_payments`
- Kolom: `id uuid`; `refund_id uuid`; `source_store_id uuid`; `source_entity_id uuid`; `payment_method_code_snapshot varchar(30)`; `amount numeric(18,2)`; `reference_number varchar(120)?`; `status varchar(20) DEFAULT 'confirmed'`; `paid_at timestamptz`.
- PK id. FK refund_id → refunds. UQ `(source_store_id,source_entity_id)`.
- CK amount > 0; status='confirmed'.
- IX `(refund_id)`.

#### `replica.cash_sessions`
- Kolom: `id uuid`; kolom asal di atas; `source_drawer_id uuid`; `source_terminal_id uuid`; `source_cashier_id uuid`; `opening_counted numeric(18,2)`; `closing_counted numeric(18,2)`; `expected_cash numeric(18,2)`; `variance_amount numeric(18,2)`; `opened_at timestamptz`; `closed_at timestamptz`; `currency_code char(3)`.
- PK id. FK source_store_id → stores; source_node_id → sync_nodes. UQ `(source_store_id,source_entity_id)`.
- CK all cash amounts >= 0 except variance may be negative; closed_at >= opened_at.
- IX `(source_store_id,closed_at DESC)`; `(source_store_id,source_cashier_id,closed_at DESC)`.

#### `replica.cash_ledger_entries`
- Kolom: `id uuid`; `source_store_id uuid`; `source_node_id uuid`; `source_entity_id uuid`; `source_drawer_id uuid`; `source_session_id uuid?`; `entry_type varchar(30)`; `direction varchar(3)`; `amount numeric(18,2)`; `source_type varchar(40)?`; `source_id uuid?`; `idempotency_key varchar(140)?`; `actor_source_user_id uuid`; `approved_by_source_user_id uuid?`; `reason text?`; `occurred_at timestamptz`; `received_at timestamptz`.
- PK id. FK source_store_id → stores; source_node_id → sync_nodes. UQ `(source_store_id,source_entity_id)`; UQ `(source_store_id,idempotency_key)` (partial when non-NULL).
- CK direction IN ('in','out'); amount > 0.
- IX `(source_store_id,source_drawer_id,occurred_at)`; `(source_store_id,source_session_id,occurred_at)`.

#### `replica.cash_handover_events`
- Kolom: `id uuid`; kolom asal di atas; `source_drawer_id uuid`; `source_from_session_id uuid`; `source_to_session_id uuid`; `from_cashier_source_id uuid`; `to_cashier_source_id uuid`; `amount numeric(18,2)`; `variance numeric(18,2)`; `supervisor_source_user_id uuid?`; `reason text?`; `confirmed_at timestamptz`.
- PK id. FK source_store_id → stores; source_node_id → sync_nodes. UQ `(source_store_id,source_entity_id)`.
- CK amount >= 0; source_from_session_id <> source_to_session_id.
- IX `(source_store_id,confirmed_at DESC)`.

#### `replica.cash_deposits`
- Kolom: `id uuid`; kolom asal di atas; `source_drawer_id uuid`; `amount numeric(18,2)`; `expected_amount numeric(18,2)`; `variance numeric(18,2)`; `recorded_by_source_user_id uuid`; `reason text`; `deposited_at timestamptz`; `status varchar(20)`.
- PK id. FK source_store_id → stores; source_node_id → sync_nodes. UQ `(source_store_id,source_entity_id)`.
- CK amount >= 0; expected_amount >= 0; status='recorded'; length(trim(reason)) > 0.
- IX `(source_store_id,deposited_at DESC)`.

#### `replica.audit_events`
- Kolom: `id uuid`; `source_store_id uuid`; `source_node_id uuid`; `source_entity_id uuid`; `source_terminal_id uuid?`; `actor_source_user_id uuid?`; `action varchar(100)`; `entity_type varchar(80)`; `entity_id uuid?`; `reason text?`; `before_data jsonb?`; `after_data jsonb?`; `correlation_id uuid?`; `occurred_at timestamptz`; `received_at timestamptz`.
- PK id. FK source_store_id → stores; source_node_id → sync_nodes. UQ `(source_store_id,source_entity_id)`.
- CK action <> ''; entity_type <> ''.
- IX `(source_store_id,occurred_at DESC)`; `(actor_source_user_id,occurred_at DESC)`; BRIN received_at. Restrict PII/secrets in before/after payload.

## 5. Schema reporting

Tabel reporting rebuildable. PK menggunakan kombinasi dimensi bisnis; seluruh uang numeric(18,2), jumlah transaksi bigint, kuantitas numeric(18,3) untuk agregasi.

#### `reporting.daily_store_sales`
- Kolom: `store_id uuid`; `business_date date`; `currency_code char(3)`; `transaction_count bigint DEFAULT 0`; `gross_sales numeric(18,2) DEFAULT 0`; `discount_total numeric(18,2) DEFAULT 0`; `tax_total numeric(18,2) DEFAULT 0`; `refund_total numeric(18,2) DEFAULT 0`; `net_sales numeric(18,2) DEFAULT 0`; `refreshed_at timestamptz`.
- PK `(store_id,business_date,currency_code)`. FK store_id → stores. CK counts and monetary totals >= 0 (net_sales may be negative only if policy explicitly allows; default CHECK net_sales >= 0 is not imposed because refund adjustments can exceed same-day sales).
- IX `(business_date,store_id)`.

#### `reporting.daily_product_sales`
- Kolom: `store_id uuid`; `business_date date`; `product_key varchar(80)`; `sku_snapshot varchar(50)`; `name_snapshot varchar(200)`; `quantity numeric(18,3)`; `gross_sales numeric(18,2)`; `discount_total numeric(18,2)`; `net_sales numeric(18,2)`; `refreshed_at timestamptz`.
- PK `(store_id,business_date,product_key)`. FK store_id → stores. CK quantity >= 0; gross/discount >= 0.
- IX `(business_date,product_key)`; `(store_id,sku_snapshot,business_date)`.

#### `reporting.daily_cashier_sales`
- Kolom: `store_id uuid`; `business_date date`; `cashier_source_id uuid`; `transaction_count bigint`; `gross_sales numeric(18,2)`; `discount_total numeric(18,2)`; `net_sales numeric(18,2)`; `refreshed_at timestamptz`.
- PK `(store_id,business_date,cashier_source_id)`. FK store_id → stores. CK transaction_count >= 0.
- IX `(business_date,store_id)`.

#### `reporting.daily_payment_totals`
- Kolom: `store_id uuid`; `business_date date`; `payment_method_code varchar(30)`; `currency_code char(3)`; `payment_count bigint`; `amount numeric(18,2)`; `refreshed_at timestamptz`.
- PK `(store_id,business_date,payment_method_code,currency_code)`. FK store_id → stores. CK payment_count >= 0; amount >= 0.
- IX `(business_date,payment_method_code)`.

#### `reporting.daily_promotion_totals`
- Kolom: `store_id uuid`; `business_date date`; `promotion_id uuid`; `promotion_code_snapshot varchar(40)`; `usage_count bigint`; `discount_total numeric(18,2)`; `quota_consumed bigint`; `refreshed_at timestamptz`.
- PK `(store_id,business_date,promotion_id)`. FK store_id → stores. CK usage_count >= 0; discount_total >= 0; quota_consumed >= 0.
- IX `(business_date,promotion_id)`.

#### `reporting.sync_health_daily`
- Kolom: `node_id uuid`; `business_date date`; `max_pending_count bigint`; `max_oldest_pending_seconds integer`; `received_count bigint`; `processed_count bigint`; `failed_count bigint`; `avg_processing_ms numeric(18,3)`; `refreshed_at timestamptz`.
- PK `(node_id,business_date)`. FK node_id → sync_nodes. CK all counts/durations >= 0.
- IX `(business_date,node_id)`.

## 6. Indeks dan partisi: keputusan awal

- Jangan partisi tabel master, registry, cursor, atau tabel kecil.
- Kandidat partisi RANGE bulanan: `cloud.node_heartbeats` by received_at; `ingest.received_events` by received_at; `ingest.delivery_attempts` by attempted_at; `replica.sales`, refunds, cash ledger, cash sessions, deposits, audit by business/occurred date setelah volume terbukti.
- PostgreSQL unique constraint pada partitioned table harus mencakup partition key. Karena identitas event/transaksi harus unik lintas partisi, gunakan registry non-partitioned:
  - `ingest.event_idempotency_registry` untuk source_node/event/idempotency/aggregate_version.
  - Registry fakta transaksi `replica.source_entity_registry` dengan kolom `source_store_id, entity_type, source_entity_id, replica_table, replica_id, business_date`, PK UUID, UQ `(source_store_id,entity_type,source_entity_id)`. Registry dibuat sejak awal dan insert-nya atomik bersama row fakta.
- Index tambahan hanya setelah query plan/load test; hindari index JSONB/GiN generik tanpa query nyata.
- Retensi payload raw: processed 90 hari; dead-letter sampai diselesaikan + minimal 1 tahun; fakta transaksi 5 tahun; audit 3 tahun kecuali legal hold.

## 7. Aturan integritas lintas tabel

Berikut bukan CHECK biasa karena melibatkan banyak row/tabel:
1. Total payment confirmed untuk sale harus sama dengan grand_total saat sale PAID.
2. Sale PAID harus memiliki minimal satu sale_line dan satu payment confirmed.
3. Refund PAID harus memiliki lines dan payout; total line/payout harus sama dengan refund header.
4. Total refund kumulatif per sale line tidak boleh melebihi qty/nilai original; lock parent/source row untuk serialisasi.
5. Promo quota allocation global per promotion tidak boleh melampaui total_limit; lock row quota lalu allocations saat grant dibuat.
6. Grant consumed_quantity tidak boleh melampaui allocated_quantity; update atomik ketika sale PAID.
7. Customer merge harus atomik/race-safe; satu nomor aktif hanya satu customer canonical.
8. Master change_seq dialokasikan dengan row lock dan commit bersama master change.
9. Inbox projection, aggregate cursor, dan processed status harus commit dalam transaksi yang sama.
10. Event refund menunggu original sale tersedia; dependency lintas aggregate tidak boleh dilewati.
11. Replica facts immutable; koreksi hanya event baru, tidak UPDATE/DELETE biasa.
12. Bukti pembayaran hanya boleh terkait payment milik sale yang sudah PAID; checksum harus cocok sebelum status verified.

## 8. Hal yang wajib diputuskan/diuji sebelum DDL

1. Apakah satu store-server aktif per store wajib mutlak atau perlu overlap saat pergantian server; partial unique saat ini sengaja bersifat opsi.
2. Penempatan PIN hash dan proses distribusi credential offline (jangan menyimpan PIN plaintext).
3. Apakah event audit yang direplikasi semua atau subset yang diizinkan.
4. Registry `replica.source_entity_registry` dibuat sejak awal untuk menjaga unique source identity, walaupun partisi fakta belum diaktifkan.
5. Apakah extension `btree_gist` disetujui untuk exclusion constraint rentang harga/pajak; jika tidak, gunakan serialized validation di service.
6. Retensi metadata idempotency setelah payload raw dihapus harus cukup lama untuk menolak duplicate lama; usulan metadata registry dipertahankan minimal sepanjang umur fakta transaksi + 1 tahun atau sesuai legal hold.
7. Final index/partition harus didasarkan pada query API dan load test; rancangan ini belum mengklaim kapasitas produksi.

## 9. Batas dokumen

Desain ini belum berupa DDL. Nama field, index, constraint, dan trigger masih perlu review silang dengan kontrak event JSON Schema dan permission model. Setelah disetujui, buat migration cloud terpisah di `database/cloud/migrations/`, CI PostgreSQL 16, fixture multi-store, uji idempotency/concurrency, dan uji restore. Jangan mengubah migration operasional toko sebagai bagian dari pekerjaan ini.
