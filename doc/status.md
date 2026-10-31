# Status Proyek POS

> Dokumen status kerja. Isi diperbarui berdasarkan repository dan hasil pengujian sampai 31 Oktober 2026. Status yang belum diuji tidak dianggap selesai.

## 1. Ringkasan proyek

Proyek ini membangun aplikasi POS (Point of Sale) untuk menggantikan Odoo 19 POS pada operasional toko bakery. Sasaran arsitektur adalah POS lokal per toko yang tetap dapat melayani transaksi ketika koneksi internet ke pusat terputus, kemudian menyinkronkan transaksi ke Cloud ketika koneksi tersedia.

Repository: `bangpei-arch/POS`

Prinsip arsitektur yang sudah ditetapkan:

- Satu local store-server untuk setiap toko.
- Terminal kasir terhubung ke server toko melalui LAN.
- Store API dan database lokal menangani transaksi operasional toko.
- Cloud menjadi pusat pengelolaan master data dan kebijakan.
- Transaksi toko disimpan secara lokal terlebih dahulu, lalu dikirim ke Cloud melalui transactional outbox.
- Sinkronisasi menggunakan REST API, OAuth client credentials, idempotency, dan final ACK.
- Koneksi internet tidak boleh menjadi syarat untuk menyelesaikan transaksi kasir di LAN.

## 2. Teknologi dan komponen

| Komponen | Teknologi / fungsi |
|---|---|
| Frontend POS | React + TypeScript — belum dibangun |
| Store API | Python + FastAPI |
| Cloud API | Python + FastAPI |
| Database lokal toko | PostgreSQL |
| Database pusat | PostgreSQL |
| Komunikasi | REST API / HTTP |
| Sinkronisasi transaksi | Transactional outbox dan Cloud receiver |
| Infrastruktur pengembangan | Docker, Docker Compose |
| Reverse proxy | Nginx direncanakan dalam arsitektur |

## 3. Ruang lingkup fungsi POS

Kebutuhan produk yang telah ditetapkan untuk aplikasi POS secara keseluruhan:

- Login kasir dengan identitas individual dan PIN.
- Katalog produk, harga, kategori, dan barcode.
- Pembukaan serta penutupan sesi kasir.
- Penjualan dan pembayaran.
- Operasional LAN dan offline terhadap Cloud.
- Sinkronisasi transaksi otomatis.
- Pengelolaan pengguna dan hak akses.
- Pengelolaan kas masuk/keluar.
- Audit aktivitas.
- Laporan penjualan dan kas.
- Pengelolaan master produk dan harga dari pusat.

Kebutuhan lanjutan yang sudah dibahas tetapi belum menjadi fungsi MVP yang selesai: refund, split tender, promosi, diskon, pelanggan, bukti transfer, inventory/stock deduction, dan failover multi-terminal.

## 4. Status milestone

### M2 — Store API / transaksi lokal

**Status implementasi: sudah dibuat dan diuji pada lingkungan lokal. PR #4 masih draft dan belum boleh dianggap merged.**

Fungsi yang tersedia:

- Login dan autentikasi kasir.
- Katalog produk.
- Buka sesi kasir.
- Membuat transaksi penjualan.
- Pembayaran satu metode: CASH, TRANSFER, atau QRIS.
- Idempotency untuk mencegah transaksi ganda saat request diulang.
- Snapshot data produk pada transaksi.
- Nomor struk.
- Transaksi PAID dan pencatatan pembayaran.
- Transactional outbox.
- Penutupan sesi kasir dan perhitungan selisih kas.
- Audit event lokal.

Batasan M2 yang masih berlaku:

- Belum ada frontend POS.
- Belum ada split tender.
- Belum ada refund.
- Belum ada promo atau diskon manual.
- Belum ada customer.
- Belum ada upload bukti transfer.
- Belum ada stock deduction.
- Belum ada multi-terminal failover.

Pengujian manual Store API yang telah berhasil:

- Login kasir berhasil.
- Katalog produk dapat dibaca.
- Sesi kasir dapat dibuka.
- Penjualan tunai Rp12.500 dengan uang diterima Rp20.000 menghasilkan kembalian Rp7.500.
- Pengulangan request dengan idempotency key yang sama mengembalikan transaksi yang sama.
- Request dengan idempotency key sama tetapi isi berbeda ditolak dengan HTTP 409.
- Penutupan sesi pada pengujian sebelumnya menghasilkan saldo yang sesuai dan variance nol.

### M3 — Store-to-Cloud transaction sync

**Status implementasi: jalur utama sudah diuji end-to-end pada satu lingkungan Store dan satu Cloud lokal. PR #5 masih draft dan bergantung pada PR #4. Belum merged.**

Komponen yang sudah tersedia:

- Cloud API untuk OAuth client credentials.
- Provisioning identitas node/store dan credential client.
- Endpoint penerimaan batch event.
- Validasi autentikasi dan scope sinkronisasi.
- Receiver event `sale.paid`.
- Penyimpanan transaksi replica di Cloud.
- Registry event yang sudah diproses untuk idempotency.
- Final ACK untuk status `processed` dan `already_processed`.
- Store sender yang mengambil event `sale.paid` dari outbox.
- Claim outbox dengan lease dan fencing token.
- Retry untuk kegagalan jaringan/server dengan exponential backoff dan jitter.
- Kegagalan HTTP 4xx permanen (kecuali 408/429) dikategorikan untuk pemeriksaan operator.
- Filter sender saat ini hanya mengambil event `sale.paid`; event `audit.recorded` tetap pending.

Pengujian end-to-end terakhir pada 31 Oktober 2026:

1. Transaksi uji Store berhasil dibuat:
   - Sale ID: `7af30f99-d8b2-4c60-bfbf-d51c89f401cb`
   - Receipt: `T8623854D-20261031-POS01-000003`
   - Total: Rp12.500
2. Event `sale.paid` masuk outbox dengan status `pending`, attempts 0.
3. Sender diarahkan sementara ke port yang tidak aktif.
4. Koneksi ditolak; sender mengembalikan ACK 0, event tetap `pending`, attempts menjadi 1, dan error class `transport_or_server`.
5. Setelah URL Cloud normal dipakai kembali dan waktu retry telah jatuh tempo, sender berhasil mengirim ulang dan mengembalikan ACK 1.
6. Outbox berubah menjadi `sent`, attempts 2, `acked_at` terisi, dan error kosong.
7. Pemeriksaan database Cloud menemukan tepat satu header transaksi, satu line, dan satu payment untuk Sale ID tersebut.

Kesimpulan pengujian: alur utama `sale.paid`, retry setelah gangguan koneksi, final ACK, dan tidak terjadinya duplikasi transaksi telah terbukti pada pengujian lokal satu Store ke satu Cloud.

Hal yang belum dibuktikan oleh pengujian tersebut: multi-store, banyak terminal, restart worker ketika sedang memproses, lease expiry dan pengambilalihan oleh worker lain, beban tinggi, serta kesiapan produksi.

## 5. Status hardening M3 dan pekerjaan berikutnya

**Hardening M3 dasar telah lulus pengujian lokal dan CI pada commit `f29a67a`.**

Hasil test Store API lokal pada 31 Oktober 2026 pukul 20:45 WIB:

- `3 passed, 1 warning` dalam 1,43 detik.
- Test mencakup alur penjualan, pemulihan event setelah lease worker lama berakhir, dan persistensi transaksi/outbox setelah siklus hidup API dimulai ulang.
- Test restart API menggunakan dua siklus hidup TestClient; ini bukan penghentian dan pengaktifan ulang proses OS/container secara nyata.
- Test sender menggunakan Cloud response yang di-mock; keberhasilan pengiriman nyata ke Cloud telah dibuktikan terpisah melalui uji end-to-end manual pada satu Store dan satu Cloud.
- Uji SQL manual sebelumnya membuktikan lease takeover dan fencing: ACK dengan token worker lama ditolak, token worker baru diterima.
- CI Store API, Cloud API, dan PostgreSQL migration pada commit tersebut berstatus sukses.

Satu warning berasal dari deprecation penggunaan `httpx` melalui `starlette.testclient`. Tidak menggagalkan test dan perlu ditangani sebagai housekeeping dependency setelah kompatibilitas penggantinya diperiksa.

Prioritas berikutnya:

1. Periksa dan rapikan dokumentasi M3 agar semua status sesuai bukti test terbaru.
2. Review PR #4 (M2) dan pastikan CI serta dependency-nya benar sebelum merge.
3. Setelah M2 merged, perbarui target/base PR #5 (M3), jalankan CI ulang, lalu review sebelum merge.
4. Lanjutkan M4 sesuai `doc/MVP-END-TO-END-PLAN.md`: laporan penjualan pusat dan pengujian end-to-end berdasarkan Definition of Done.

## 6. Pekerjaan yang belum dikerjakan atau belum diverifikasi

### Sinkronisasi dan backend

- Sinkronisasi master produk, kategori, harga, barcode, dan kebijakan dari Cloud ke Store.
- Penanganan perubahan master data dan konflik.
- Sinkronisasi event selain `sale.paid`, termasuk audit, sesuai kebijakan desain.
- Multi-store dan multi-node.
- Pengujian multi-terminal.
- Pemulihan sender setelah worker berhenti: lease expiry/takeover dan fencing sudah diuji pada level database serta test sender terotomasi; penghentian/restart proses OS/container nyata dan crash di setiap titik I/O belum diuji.
- Monitoring, alert, dan operasional sender sebagai service terkelola.
- Pengujian beban, soak test, dan pengujian jaringan tidak stabil.
- Backup, restore, dan disaster recovery untuk implementasi POS.
- Hardening keamanan dan deployment produksi.

### Fungsi kasir

- Frontend POS React + TypeScript.
- Refund dan pengembalian stok.
- Split tender.
- Promo dan diskon.
- Data pelanggan.
- Upload/penyimpanan bukti transfer.
- Inventory dan stock deduction.
- Barcode scanner dalam UI terminal.
- Hold/resume transaksi.
- Cash in/cash out.
- Pengelolaan hak akses lengkap melalui UI.
- Laporan dan ekspor operasional.
- Failover terminal atau local server.

### Pengujian dan rilis

- UAT menyeluruh dengan alur operasional toko.
- Pengujian beberapa toko dan terminal.
- Uji perangkat kasir dan printer struk.
- Uji pemulihan database dan server lokal.
- Dokumentasi instalasi, upgrade, rollback, dan SOP operasional.
- Penetapan kriteria penerimaan dan kesiapan produksi.

Daftar ini merupakan backlog berdasarkan ruang lingkup yang sudah dibahas; urutan dan prioritas dapat berubah setelah hardening M3.

## 7. Repository, branch, dan Pull Request

Informasi terakhir yang diketahui:

| Item | Status |
|---|---|
| Repository | `bangpei-arch/POS` |
| Branch kerja M3 | `mvp/store-cloud-sync` |
| Commit branch terakhir (pembaruan dokumen) | `d76e8ad2335d4bf36aac008a5f6a22bccd833e00` |
| Commit kode M3 yang diuji lokal | `f29a67ae57e6fb552b56e44839569c1d4f37f90a` |
| PR #4 | `mvp/store-api-sale` — M2, draft |
| PR #5 | `mvp/store-cloud-sync` — M3, draft |
| Ketergantungan | M3/PR #5 bertumpu pada M2/PR #4 |
| CI PR #5 pada pemeriksaan terakhir | Empat job lulus: postgres-validation, cloud-api-validation, store-api-validation, dan job validasi terkait yang tercatat saat itu |

**Aturan merge:** jangan merge PR #5 sebelum PR #4 selesai dan dependency/target branch sudah benar. Status PR dan CI dapat berubah; periksa GitHub sebelum melakukan merge.

## 8. Lingkungan pengujian lokal yang sudah digunakan

Detail berikut adalah lingkungan uji lokal, bukan konfigurasi produksi.

| Komponen | Detail |
|---|---|
| Store PostgreSQL container | `bakery-pos-store-mvp-test-db` |
| Store DB | `pos_mvp_test` |
| Store DB port host | `127.0.0.1:55433` |
| Cloud PostgreSQL container | `bakery-pos-cloud-mvp-test-db` |
| Cloud DB | `pos_cloud_mvp_test` |
| Cloud DB port host | `127.0.0.1:55434` |
| Cloud API | `http://127.0.0.1:8001` |
| Store API | `http://127.0.0.1:8002` |

Catatan keselamatan operasional:

- Jangan commit credential, private key, PIN, token, atau secret ke repository.
- Secret client uji disimpan lokal di file dengan permission terbatas; jangan menyalin nilainya ke dokumentasi.
- Jangan menghapus Docker volume database dengan `docker compose down -v` kecuali memang diminta dan data uji sudah dipastikan boleh dihapus.
- Store dan Cloud menggunakan compose file terpisah; jangan memakai `--remove-orphans` secara sembarangan karena dapat memengaruhi container dari stack lain.
- Sesi kasir uji terakhir yang diketahui masih berstatus open. Periksa statusnya sebelum melakukan pengujian yang memengaruhi saldo kas.

## 9. Arah pengerjaan berikutnya

Urutan kerja yang disarankan:

1. Hardening M3 dasar sudah lulus: 3 test Store API lokal, uji lease/fencing SQL manual, dan CI pada commit kode `f29a67a`.
2. Review PR #4 (M2), pastikan branch target dan CI, lalu merge M2 lebih dahulu.
3. Setelah PR #4 merged, rebase/retarget PR #5 (M3), jalankan CI ulang, lalu review dan merge.
4. Lanjutkan M4 sesuai `doc/MVP-END-TO-END-PLAN.md`: laporan penjualan pusat dan pengujian end-to-end.
5. Mulai M4 sesuai dokumen baseline: endpoint/laporan penjualan pusat dan validasi Definition of Done end-to-end.
6. Setelah jalur MVP pusat terbukti, bangun frontend React + TypeScript (login, katalog, sesi kasir, cart, pembayaran, dan struk) sebagai pekerjaan UI yang terpisah/lanjutan.
7. Lanjutkan sinkronisasi master data dan fungsi POS berikutnya berdasarkan prioritas operasional.

---

## 10. Definisi status

- **Selesai dan teruji**: implementasi tersedia dan bukti pengujian yang disebutkan telah dijalankan.
- **Sudah dibuat, belum teruji penuh**: kode atau struktur tersedia, tetapi skenario operasional belum dibuktikan.
- **Sedang dikerjakan**: menjadi fokus pekerjaan aktif.
- **Belum dikerjakan**: belum tersedia sebagai fungsi implementasi.
- **Belum diverifikasi**: mungkin ada bagian kode, tetapi belum ada bukti yang cukup untuk menyatakan fungsi tersebut lulus.

Dokumen ini adalah snapshot status proyek, bukan jaminan bahwa seluruh informasi branch, PR, dan CI masih sama setelah tanggal pembaruan.
