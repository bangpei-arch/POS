# Debian 13 — Store API MVP smoke test

Tes ini memakai PostgreSQL khusus tes. Tidak memakai database pos_dev atau database operasional toko.

## 1. Ambil branch MVP

Jika belum punya working copy khusus:

```bash
git clone --branch mvp/store-api-sale https://github.com/bangpei-arch/POS.git POS-mvp-test
cd POS-mvp-test
```

Jika repository sudah ada, buat working tree terpisah:

```bash
git fetch origin mvp/store-api-sale
git worktree add ../POS-mvp-test origin/mvp/store-api-sale
cd ../POS-mvp-test
```

Periksa branch dan commit:

```bash
git status --short --branch
git log -1 --oneline
```

## 2. Jalankan PostgreSQL tes terisolasi

Prasyarat: Docker Engine dan Docker Compose plugin.

```bash
docker compose -f docker-compose.store-mvp-test.yml up -d
docker compose -f docker-compose.store-mvp-test.yml ps
until docker exec bakery-pos-store-mvp-test-db pg_isready -U pos_mvp_test -d pos_mvp_test; do sleep 2; done
```

Database hanya bind ke localhost port 55433 dan memakai volume khusus `bakery_pos_store_mvp_test_data`.

## 3. Terapkan migrasi local-store 001–005

```bash
set -e
for migration in 001_initial_schema.sql 002_integrity_guards.sql 003_transaction_finality.sql 004_sync_recovery_ordering.sql 005_mvp_pos_fields.sql; do
  docker exec -i bakery-pos-store-mvp-test-db psql -v ON_ERROR_STOP=1 -U pos_mvp_test -d pos_mvp_test < "database/migrations/$migration"
done
```

Periksa jumlah tabel:

```bash
docker exec bakery-pos-store-mvp-test-db psql -U pos_mvp_test -d pos_mvp_test -c "SELECT count(*) AS pos_tables FROM information_schema.tables WHERE table_schema='pos' AND table_type='BASE TABLE';"
```

## 4. Jalankan integration test Store API

```bash
cd apps/store-api
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements-dev.txt
STORE_DATABASE_URL='postgresql://pos_mvp_test:pos_mvp_test_only@127.0.0.1:55433/pos_mvp_test' pytest -q
```

Tes memeriksa login kasir, katalog, buka sesi kas, penjualan tunai Rp12.500 dengan uang diterima Rp20.000, kembalian Rp7.500, retry idempotent, penolakan HTTP 409 untuk key sama dengan isi berbeda, tutup sesi kas, status sale paid, dan satu event sale.paid di outbox.

Hasil yang diharapkan: `1 passed`.

## 5. Setelah tes

Kirim output berikut. Jangan kirim file .env, password produksi, atau data transaksi asli.

```bash
git log -1 --oneline
STORE_DATABASE_URL='postgresql://pos_mvp_test:pos_mvp_test_only@127.0.0.1:55433/pos_mvp_test' pytest -q
```

Hentikan database tes tanpa menghapus datanya:

```bash
docker compose -f docker-compose.store-mvp-test.yml down
```

Hapus hanya database tes beserta volumenya untuk mulai dari nol:

```bash
docker compose -f docker-compose.store-mvp-test.yml down -v
```

Jangan jalankan down -v pada compose proyek lain.

## Batas hasil tes

Tes ini memvalidasi Store API dan transaksi/outbox lokal pada satu server toko. Ini belum membuktikan sinkronisasi ke cloud. Sender worker, cloud receiver, ACK, dan uji alur toko-ke-pusat adalah milestone berikutnya.
