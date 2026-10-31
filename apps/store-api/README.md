# POS Store API — MVP M2

Local Store API untuk satu terminal dan satu store-server. Semua transaksi POS disimpan ke database lokal. Internet cloud tidak diperlukan untuk menyelesaikan pembayaran selama terminal masih dapat mengakses Store API dan kasir sudah login.

## Fitur M2

- Login kasir dengan employee code + PIN Argon2id.
- JWT lokal HS256 dengan masa berlaku terbatas.
- Katalog produk/harga/pajak dari master snapshot cloud.
- Buka dan tutup cash session.
- Buat transaksi satu metode pembayaran: CASH, TRANSFER, atau QRIS.
- CASH menghitung kembalian.
- TRANSFER/QRIS dikonfirmasi manual oleh kasir setelah verifikasi.
- Transaksi menjadi PAID dan transactional outbox dibuat dalam transaksi database yang sama.
- Idempotency-Key mencegah transaksi ganda saat terminal retry.
- Audit allowlist dikirim sebagai event terpisah.
- Menerapkan hanya produk zero-tax pada MVP. Produk dengan tax_rate > 0 ditolak sementara sampai mode harga pajak (inclusive/exclusive) ditetapkan.

## Prasyarat

1. Local DB migrations 001–005 sudah diterapkan.
2. Cloud store/server sudah diprovisikan dengan Cloud API.
3. Master snapshot sudah ditarik ke database lokal.
4. Terminal, kasir, dan cash drawer sudah diprovisikan.

## Setup lokal

Dari root repository:

```bash
cp apps/store-api/.env.example apps/store-api/.env
```

Edit file apps/store-api/.env. STORE_ID dan STORE_NODE_ID harus sama dengan ID yang dibuat pada provisioning Cloud. TERMINAL_ID diisi setelah menjalankan provisioning terminal.

Buat local JWT secret:

```bash
openssl rand -hex 32
```

Simpan hasilnya pada STORE_JWT_SECRET. Jangan commit file .env.

Jalankan bootstrap master (pakai environment yang sama):

```bash
cd apps/store-api
set -a
source .env
set +a
python scripts/pull_cloud_master.py
```

Provision satu terminal dan kasir:

```bash
python scripts/provision_terminal.py \
  --terminal-code POS01 \
  --terminal-name 'POS 01' \
  --employee-code KSR001 \
  --cashier-name 'Kasir MVP' \
  --fixed-float 100000
```

Salin nilai TERMINAL_ID yang dicetak ke apps/store-api/.env. PIN diminta secara interaktif dan hanya hash Argon2id yang disimpan.

Install dan jalankan API:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8001
```

OpenAPI docs: http://localhost:8001/docs

## Flow uji manual

1. POST /api/v1/auth/login dengan employee_code dan PIN.
2. POST /api/v1/sessions/open dengan opening_counted.
3. GET /api/v1/catalog/products untuk memilih product_id.
4. POST /api/v1/sales dengan header Idempotency-Key dan satu atau lebih lines.
5. Untuk CASH kirim cash_received_amount sebagai string decimal. Untuk TRANSFER/QRIS kirim reference_number.
6. POST /api/v1/sessions/{session_id}/close dengan closing_counted.

Contoh payload sale:

```json
{
  "lines": [
    {"product_id": "UUID-PRODUK", "quantity": 2}
  ],
  "payment_method_code": "CASH",
  "cash_received_amount": "50000.00"
}
```

## Batas MVP

- Satu store-server dan satu terminal.
- Tidak ada split tender, promo, diskon manual, refund, customer, bukti transfer upload, stock deduction, atau multi-terminal failover.
- Produk bertax_rate > 0 ditolak untuk mencegah salah hitung pajak.
- Tidak ada UI frontend pada milestone M2; API diuji melalui OpenAPI/HTTP. UI terminal menjadi langkah berikutnya.
- Sender worker dan cloud receiver belum ada pada M2; transaksi PAID sudah masuk outbox lokal dan menunggu M3.
