# Spesifikasi Fungsional POS
**Proyek:** POS Independen untuk jaringan toko bakery  
**Repository:** bangpei-arch/POS  
**Dokumen:** Baseline spesifikasi fungsional  
**Versi dokumen:** 8.0  
**Tanggal:** 30 Oktober 2026  
**Status:** Baseline kebutuhan bisnis; menjadi acuan desain database dan implementasi.

---

## 1. Tujuan

Membangun aplikasi Point of Sale (POS) independen untuk menggantikan fungsi POS Odoo 19 di toko-toko. POS harus tetap beroperasi saat koneksi internet ke server pusat terputus, dan tetap dapat menerima transaksi ketika local server/LAN toko tidak tersedia melalui penyimpanan lokal pada setiap terminal.

POS berfokus pada penjualan dan operasional kasir. POS bukan pengganti sistem inventori, manufaktur, pembelian, atau akuntansi.

## 2. Prinsip dan arsitektur

### 2.1 Arsitektur yang disepakati

- Satu central server untuk master data, konfigurasi, konsolidasi transaksi, monitoring, dan laporan seluruh toko.
- Satu local server pada setiap toko untuk melayani beberapa terminal POS, menyimpan data lokal, dan menjalankan sinkronisasi.
- Setiap terminal memiliki penyimpanan lokal persisten sebagai fallback ketika local server atau LAN toko gagal.
- Frontend: React + TypeScript.
- Backend: Python + FastAPI.
- Database: PostgreSQL pada local server dan central server.
- Komunikasi antarkomponen menggunakan REST API.
- Background worker menangani sinkronisasi.
- Deployment menggunakan Docker dan Nginx.
- Tahap awal menggunakan transactional outbox pada PostgreSQL; belum memerlukan RabbitMQ atau Kafka.

### 2.2 Prinsip sinkronisasi

1. Central server menjadi sumber otoritatif untuk master produk, harga, pajak, promosi, akun, dan konfigurasi pusat.
2. Transaksi penjualan yang dibuat cabang tetap menjadi data milik cabang dan tidak boleh ditimpa oleh master data pusat.
3. Tidak menggunakan replikasi database dua arah secara langsung.
4. Setiap transaksi memiliki UUID internal yang unik.
5. Nomor struk dibuat lokal oleh terminal agar tetap tersedia saat offline.
6. Pengiriman menggunakan idempotency key, transactional outbox, retry otomatis, dan acknowledgement dari pusat.
7. Pengiriman ulang tidak boleh membuat transaksi ganda.
8. Sinkronisasi berjalan otomatis di latar belakang ketika koneksi pulih.
9. Antrean dikirim berdasarkan urutan transaksi tertua terlebih dahulu.
10. Status transaksi dan status sinkronisasi disimpan terpisah.

Contoh status:
- Status transaksi: PAID.
- Status sinkronisasi: PENDING atau SYNCED.
- Pembayaran non-tunai yang belum dapat dipastikan: PAYMENT_PENDING.

### 2.3 Mode gangguan

- Internet ke pusat terputus: POS tetap beroperasi menggunakan local server dan data terakhir yang tersinkron.
- Local server/LAN toko gagal: terminal tetap dapat menerima transaksi menggunakan penyimpanan lokal persisten.
- Dua terminal yang offline secara mandiri memiliki antrean masing-masing.
- Data lokal harus bertahan setelah aplikasi ditutup atau terminal restart.
- Transaksi yang sudah dikonfirmasi tidak boleh hilang. Target kehilangan transaksi terkonfirmasi adalah nol melalui penyimpanan terminal dan antrean sinkronisasi.
- Jika data master atau stok sudah lama, POS menampilkan status dan waktu pembaruan terakhir.

## 3. Ruang lingkup

### 3.1 Termasuk

- Keranjang dan transaksi penjualan.
- Pembayaran tunai, transfer, QRIS, debit, dan metode lain yang dapat dikonfigurasi.
- Split payment.
- Sesi kasir, laci kas, modal kas, setoran, cash in/out, dan serah terima kasir.
- Diskon manual dan promosi otomatis.
- Master pelanggan.
- Katalog produk, kategori, barcode, pencarian, dan tampilan produk.
- Pajak, pembulatan, dan struk.
- Hold Order.
- Pembatalan dan refund.
- Laporan penjualan.
- Audit log.
- Sinkronisasi cabang-pusat.
- Monitoring terminal dan status operasional.
- Integrasi inventori melalui API.

### 3.2 Tidak termasuk

- Purchasing dan Vendor Bill.
- Inventory management lengkap.
- Manufacturing dan BOM.
- Stock transfer.
- Accounting dan pembukuan.

Sistem inventori/pusat tetap bertanggung jawab atas pengelolaan stok lengkap. POS hanya membaca informasi stok dan mengirim dampak transaksi melalui API.

## 4. Pengguna, peran, dan akses

Setiap pegawai memiliki akun individual. Lima peran utama:

| Peran | Tanggung jawab utama |
|---|---|
| Cashier | Penjualan, pembayaran, pembukaan dan penutupan sesi sendiri |
| Store Supervisor | Operasional kasir, diskon manual, refund, pembatalan pascabayar, cash in/out, serah terima |
| Store Admin | Operasional dan laporan toko, pengelolaan perangkat toko |
| Central Admin | Akun, master produk, harga, konfigurasi, toko, terminal, sinkronisasi, dan monitoring pusat |
| Owner / Management | Monitoring dan laporan seluruh toko |

Aturan akses yang sudah ditetapkan:
- Pembuatan akun pegawai: Central Admin.
- Reset PIN kasir: Store Supervisor.
- Menonaktifkan akun: Central Admin.
- Memindahkan pegawai antar cabang: Central Admin.
- Setiap tindakan akun, reset PIN, dan transfer cabang dicatat di audit log.
- Supervisor tidak dapat melihat PIN lama. Reset harus menghasilkan mekanisme PIN pengganti/pemulihan yang aman.
- Kasir hanya melihat transaksi dan sesi miliknya.
- Supervisor melihat seluruh transaksi dan sesi di tokonya.
- Store Admin melihat transaksi dan laporan tokonya.
- Central Admin memiliki akses pengelolaan dan monitoring seluruh toko.
- Owner melihat seluruh toko, transaksi, dan laporan.
- Audit log hanya dapat dilihat dan diekspor oleh Central Admin dan Owner.
- Detail izin setiap aksi harus diterapkan berdasarkan prinsip least privilege dan diuji pada desain akses.

## 5. Login dan keamanan

- Login kasir menggunakan employee ID dan PIN.
- PIN disimpan dalam bentuk hash aman, bukan plaintext.
- Batas salah PIN: lima kali, kemudian akun terkunci sementara.
- Timeout sesi dapat dikonfigurasi Central Admin.
- Supervisor dapat membantu membuka kunci atau mereset PIN.
- Aktivitas pemulihan dicatat dalam audit log.
- Timeout tidak boleh menghilangkan transaksi yang belum disimpan; keranjang dipertahankan secara aman dan pengguna harus autentikasi ulang.
- Jika terminal dipakai kasir lain, kasir berikutnya wajib login dengan identitasnya sendiri.
- Identitas pembuat awal transaksi/keranjang harus tetap dipertahankan.

## 6. Toko dan terminal

- Toko dan terminal didaftarkan secara terpusat.
- Setiap terminal memiliki ID unik.
- Terminal memiliki primary cashier, tetapi kasir dapat login di terminal lain dalam toko yang sama dengan otorisasi Supervisor.
- Transaksi mencatat toko dan terminal asal.
- Pendaftaran dan penonaktifan terminal hanya oleh Central Admin.
- Terminal yang hilang atau diganti dapat dinonaktifkan dari pusat.
- Penggantian terminal yang rusak: Supervisor melakukan migrasi data dan konfigurasi ke terminal baru.
- Perintah penonaktifan berlaku segera setelah diterima terminal.
- Transaksi yang belum tersinkron harus tetap dipertahankan saat terminal dinonaktifkan.
- Monitoring mencakup online/offline, versi aplikasi, aktivitas sinkronisasi, dan jumlah transaksi pending.
- Satu local server per toko melayani beberapa terminal.
- Setiap terminal tetap memiliki penyimpanan lokal persisten untuk kondisi local server/LAN gagal.
- Zona waktu ditetapkan per toko oleh pusat; waktu transaksi mengikuti zona waktu toko, bukan jam terminal.

## 7. Katalog, produk, dan barcode

- Semua toko menggunakan katalog produk yang sama.
- Central Admin menentukan produk yang dijual, mengelola barcode, dan kategori kasir.
- Produk baru muncul setelah master data berhasil tersinkron ke toko.
- Produk yang dinonaktifkan pusat disembunyikan dan tidak dapat ditambahkan ke transaksi baru. Riwayat lama tetap dipertahankan.
- Produk yang dinonaktifkan menggunakan soft delete; aktivasi kembali menggunakan identitas produk yang sama.
- Jika toko offline, toko menggunakan master terakhir yang tersimpan dan menampilkan status data stale.
- Produk sementara tidak tersedia di toko disembunyikan di toko terkait.
- Central Admin mengelola foto produk.
- Satu produk dapat memiliki beberapa barcode.
- Barcode harus unik dan tidak boleh mengarah ke produk yang salah.
- Barcode yang tidak dikenal menampilkan pesan “barcode tidak ditemukan”; kasir tidak dapat mendaftarkan produk sendiri.
- Produk dengan variasi berbeda dibuat sebagai SKU terpisah.
- Pemindaian barcode yang sama berulang kali menghasilkan baris keranjang terpisah.
- Urutan produk favorit/terlaris ditentukan Central Admin.
- Pencarian berdasarkan nama, SKU, dan barcode.
- Hasil pencarian menampilkan foto, nama, dan harga.
- Hasil tidak dibatasi secara bisnis; antarmuka menggunakan pagination untuk performa.
- Tampilan katalog kasir: kategori selalu terlihat; layout produk di kiri dan keranjang/pembayaran di kanan; mendukung touchscreen dan barcode scanner.
- Produk dapat ditampilkan dengan foto, nama, harga; tampilan nama dan harga saja juga dapat dikonfigurasi per terminal.
- Urutan default produk adalah best-selling sesuai konfigurasi pusat.

## 8. Keranjang dan transaksi

- Kasir dapat mengubah kuantitas menggunakan tombol plus/minus atau input langsung.
- Kuantitas POS berupa bilangan bulat.
- Kuantitas nol otomatis menghapus baris.
- Kasir dapat menghapus item sebelum pembayaran tanpa persetujuan Supervisor; penghapusan tetap diaudit.
- Kasir dapat menambahkan catatan pada item.
- Penghapusan item mencatat kasir, terminal, waktu, produk, kuantitas, dan nilai.
- Setelah transaksi dibayar, data penjualan tidak dapat diedit. Koreksi dilakukan melalui refund/reversal.
- Setiap produk menggunakan satu satuan dasar penjualan yang sama dengan satuan dasar stok. POS tidak menyediakan beberapa UoM penjualan atau konversi; konversi menjadi tanggung jawab master/inventory system.
- Harga, pajak, dan promosi yang berlaku disimpan sebagai snapshot pada transaksi.
- Perubahan harga/pajak tidak mengubah transaksi yang sudah dibuka; transaksi baru menggunakan konfigurasi terbaru yang sudah diterima toko.

## 9. Pelanggan

- Identitas pelanggan opsional.
- Jika kasir tidak memilih pelanggan, sistem menggunakan pelanggan default “Umum”.
- Laporan membedakan pelanggan Umum dan pelanggan terdaftar.
- Pencarian pelanggan berdasarkan nama dan nomor telepon.
- Nama dan nomor telepon wajib saat registrasi; alamat dan tanggal lahir opsional.
- Kasir boleh mendaftarkan pelanggan baru dan mengedit data pelanggan.
- Nomor telepon dinormalisasi agar format seperti 0812... dan +62812... tidak menjadi dua pelanggan berbeda.
- Nomor telepon duplikat menampilkan data yang sudah ada dan mencegah pembuatan duplikat.
- Data pelanggan dikelola pusat dan dicache di toko untuk pencarian offline.
- Kasir dapat mendaftarkan pelanggan saat offline; data disimpan lokal dan disinkronkan kemudian.
- ID lokal unik digunakan; nomor telepon dinormalisasi dan divalidasi ulang di pusat untuk mencegah duplikasi.
- Hanya Central Admin yang boleh menonaktifkan atau menggabungkan pelanggan.

## 10. Harga, diskon, dan promosi

### 10.1 Harga

- Hanya Central Admin yang dapat mengubah harga jual.
- Harga baru berlaku otomatis pada tanggal/waktu efektif yang ditentukan pusat.
- Perubahan harga berlaku untuk transaksi baru; transaksi yang sudah dibuka tetap menggunakan harga lama.
- Setiap baris transaksi menyimpan snapshot harga dan versi harga.
- Jika offline, toko memakai harga terakhir yang berhasil disinkronkan.

### 10.2 Promosi otomatis

Promosi dikonfigurasi pusat dan diterapkan otomatis. Jenis yang didukung:
- Persentase.
- Potongan nominal.
- Bundle.
- Minimum pembelian.
- Harga khusus produk.
- Promosi khusus pelanggan terdaftar.

Ketentuan:
- Promosi tidak dapat ditumpuk.
- Jika beberapa promosi memenuhi syarat, sistem memilih satu dengan manfaat terbesar bagi pelanggan.
- Periode mulai dan berakhir mengikuti tanggal/waktu konfigurasi.
- Promosi dapat berlaku untuk produk tertentu atau seluruh transaksi.
- Batas maksimum nominal diskon dan jumlah pemakaian dapat dikonfigurasi.
- Promosi khusus member hanya berlaku bagi pelanggan terdaftar, bukan pelanggan Umum.
- Versi promosi disimpan sebagai snapshot transaksi.
- Penggunaan kuota dilacak agar tidak terjadi pemakaian ganda setelah sinkronisasi; kuota total dan per pelanggan diterapkan jika dikonfigurasi.
- Saat offline, toko menggunakan promosi terakhir yang tersinkron.

### 10.3 Diskon manual

- Kasir tidak memiliki kewenangan diskon manual.
- Supervisor dapat memberikan diskon langsung dalam batas persentase dan nominal yang ditentukan Central Admin.
- Dalam batas kewenangan tersebut tidak diperlukan persetujuan tambahan.
- Diskon dapat diterapkan pada produk tertentu atau seluruh transaksi.
- Supervisor dapat membatalkan promosi otomatis dengan alasan wajib.
- Catat nilai/persentase diskon, alasan, Supervisor, dan waktu.
- Pembatalan promosi otomatis dicatat terpisah dari diskon manual, termasuk promosi yang dibatalkan, alasan, Supervisor, dan waktu.

## 11. Pajak, pembulatan, dan harga akhir

- Tarif pajak dikonfigurasi per produk oleh Central Admin.
- Harga jual belum termasuk pajak.
- Pajak dihitung setelah diskon.
- Produk tanpa pajak memakai tarif 0%.
- Jika ada beberapa tarif pajak dalam transaksi, pajak dihitung per produk sesuai tarif masing-masing lalu dijumlahkan.
- Struk menampilkan tarif dan nominal pajak per kelompok tarif serta total pajak.
- Tarif dan versi pajak disimpan sebagai snapshot transaksi.
- Perubahan tarif pajak berlaku pada transaksi baru setelah konfigurasi efektif diterima toko.
- Pembulatan pembayaran ke kelipatan Rp100.
- Pembulatan hanya pada total akhir transaksi, bukan per produk.
- Urutan perhitungan: subtotal → diskon → pajak → pembulatan → pembayaran.
- Untuk diskon transaksi yang mencakup beberapa tarif pajak, rancangan awal mengalokasikan diskon secara proporsional berdasarkan nilai produk sebelum pajak. Metode ini perlu dipastikan dalam desain perhitungan dan pengujian.

## 12. Pembayaran

Metode pembayaran dapat dikonfigurasi, tidak di-hardcode:
- Tunai.
- Transfer.
- QRIS.
- Debit.
- Metode lain yang dikonfigurasi.

Ketentuan:
- Split payment didukung.
- Pembayaran tunai menyediakan tombol nominal cepat, misalnya uang pas, Rp20.000, Rp50.000, dan Rp100.000.
- Kembalian dihitung otomatis.
- Pembayaran tunai yang kurang dari total tidak dapat difinalisasi kecuali kekurangannya diselesaikan dengan metode lain melalui split payment.
- Pembayaran non-tunai dikonfirmasi manual oleh kasir setelah memeriksa bukti pembayaran.
- Nomor referensi pembayaran wajib untuk non-tunai.
- Foto/screenshot bukti pembayaran opsional.
- Pembayaran non-tunai belum dianggap berhasil sebelum dikonfirmasi kasir.
- Jika status pembayaran non-tunai tidak jelas akibat gangguan, status menjadi PAYMENT_PENDING.
- Selama status belum jelas, pembayaran ulang diblokir untuk mencegah pembayaran ganda.
- Supervisor memverifikasi bukti atau status pembayaran.
- Jika terbukti berhasil, status menjadi PAID. Jika terbukti gagal, transaksi dapat dilanjutkan dengan metode lain atau dibatalkan sesuai kewenangan.
- Metode refund dipilih Supervisor dan tidak wajib sama dengan metode pembayaran awal.

## 13. Sesi kasir dan pengelolaan uang

### 13.1 Sesi

- Sesi wajib dibuka sebelum penjualan.
- Setiap kasir memiliki sesi sendiri.
- Kasir memasukkan saldo awal setelah menghitung uang fisik; saldo awal nol diperbolehkan.
- Tidak boleh ada dua sesi aktif bersamaan untuk kasir yang sama.
- Saat penutupan, kasir menghitung uang fisik.
- POS menghitung saldo kas yang diharapkan dan selisih.
- Sesi boleh ditutup meskipun terdapat selisih; selisih dicatat dan Supervisor diberi notifikasi.
- Sesi boleh ditutup meskipun ada Hold Order; Hold Order tetap tersimpan dan hanya pembuatnya yang dapat melanjutkan.

Rumus:
- Kas yang diharapkan = saldo awal + penerimaan tunai + Cash In − Cash Out − refund tunai.
- Selisih = uang fisik aktual − kas yang diharapkan.
- Selisih dicatat sebagai audit, bukan koreksi otomatis.

### 13.2 Laci dan modal kas

- Setiap terminal memiliki laci kas fisik dan nominal modal tetap.
- Nominal modal terminal ditetapkan Central Admin.
- Modal terminal harus tetap tersedia untuk operasional setelah setoran harian.
- Setoran kas dilakukan setiap akhir hari.
- Supervisor berwenang mencatat setoran.
- Selisih setoran dicatat dan wajib memiliki alasan.
- Cash In dan Cash Out memerlukan persetujuan Supervisor serta alasan.

### 13.3 Serah terima kasir

- Kasir A menghitung uang fisik.
- Kasir B menghitung ulang dan mengonfirmasi jumlah yang diterima.
- Jika ada selisih, Supervisor mencatat selisih dan alasan.
- Sesi kasir A ditutup dan sesi kasir B dibuka.
- Riwayat serah terima menyimpan identitas kedua kasir, jumlah, selisih, waktu, dan konfirmasi.

### 13.4 Catatan rekonsiliasi

Modal kas ditetapkan per terminal, sedangkan sesi dan pertanggungjawaban melekat pada kasir. Desain database dan prosedur kas harus mempertahankan keterlacakan saldo laci terminal sepanjang pergantian sesi. Jangan membuat saldo awal setiap sesi menggandakan modal fisik terminal.

## 14. Hold Order

- Hold Order didukung.
- Hold Order bukan transaksi penjualan final; tidak masuk laporan penjualan dan tidak mengurangi stok sebagai penjualan.
- Hanya kasir pembuat yang dapat melanjutkan atau menghapus.
- Hold Order tidak memiliki batas jumlah per kasir.
- Hold Order tidak kedaluwarsa otomatis.
- Hold Order tetap tersimpan setelah aplikasi ditutup, terminal restart, atau sesi kasir ditutup.
- Hold Order tetap tersedia setelah toko tutup dan dapat dilanjutkan pada jam operasional berikutnya.

## 15. Pembatalan dan refund

### 15.1 Sebelum pembayaran

- Kasir pembuat transaksi dapat membatalkan.
- Alasan wajib.
- Riwayat pembatalan disimpan; tidak ada hard delete.

### 15.2 Setelah pembayaran

- Pembatalan memerlukan Supervisor dan diproses melalui refund/reversal.
- Transaksi yang sudah dibayar tidak boleh dihapus atau diubah diam-diam.
- Refund dapat sebagian atau penuh.
- Tidak ada batas waktu refund, tetapi tetap memerlukan persetujuan Supervisor.
- Alasan refund wajib.
- Refund harus merujuk transaksi penjualan asal.
- Total kuantitas/nilai yang direfund tidak boleh melebihi kuantitas/nilai transaksi asal.
- Setiap item refund mencatat kuantitas dan nominal refund.
- Catat aktor, waktu, alasan, nominal, dan metode refund.
- Metode refund dipilih Supervisor dan tidak harus sama dengan metode pembayaran awal.
- Penjualan asli tetap utuh.

### 15.3 Dampak refund pada stok

- Refund uang tidak otomatis menambah stok.
- Stok hanya dikembalikan apabila barang secara fisik diterima kembali dan dinyatakan layak dijual.
- Status penerimaan dan kelayakan barang harus dicatat agar sistem inventori tidak salah menambah stok.

## 16. Integrasi inventori

- POS hanya membaca informasi stok; bukan aplikasi inventori lengkap.
- Sumber stok adalah sistem inventori pusat melalui API.
- POS menampilkan stok pada layar kasir.
- Stok nol atau negatif memunculkan peringatan, tetapi penjualan tetap diperbolehkan.
- Penjualan tetap dapat dilakukan jika informasi stok tidak tersedia.
- Saat offline, tampilkan stok cache terakhir beserta waktu pembaruan.
- Pengurangan stok dikirim saat pembayaran POS berhasil (PAID).
- Refund mengembalikan stok hanya jika barang diterima kembali secara fisik dan layak jual.
- Payload API berupa detail transaksi: nomor transaksi, produk, SKU, barcode, kuantitas, harga, diskon, pajak, waktu, toko, dan terminal.
- Jika pengiriman gagal, lakukan retry otomatis sampai berhasil.
- Gunakan UUID/idempotency agar pengiriman ulang tidak menggandakan dampak stok.
- Selisih stok yang ditemukan setelah sinkronisasi dicatat dan diserahkan ke sistem inventori pusat untuk koreksi sesuai prosedurnya.

## 17. Struk dan printer

- Mendukung printer thermal 80 mm.
- Koneksi: USB, LAN/Ethernet, dan Bluetooth.
- Tidak mengunci ke merek tertentu.
- Konfigurasi printer per terminal.
- Setelah pembayaran berhasil, struk dicetak otomatis; kasir dapat memilih untuk tidak mencetak.
- Kasir dan Supervisor boleh melakukan cetak ulang.
- Alasan cetak ulang wajib.
- Tidak perlu menambahkan tanda DUPLICATE/COPY.
- Batas cetak ulang dapat dikonfigurasi Central Admin.
- Setiap cetak ulang mencatat pengguna, waktu, terminal, transaksi, dan alasan.
- Isi struk: identitas toko, nomor transaksi, tanggal/waktu, kasir, produk, kuantitas, harga satuan, diskon, pajak, total, metode pembayaran, jumlah uang diterima, dan kembalian jika tunai.

## 18. Jam operasional toko

- Jam operasional ditetapkan per toko oleh Central Admin.
- Hari libur dan jam khusus diatur Central Admin.
- Setelah jam operasional, POS memblokir transaksi baru.
- Transaksi yang sudah dimulai sebelum jam tutup boleh diselesaikan.
- Hold Order tetap tersimpan untuk hari operasional berikutnya.
- Supervisor dapat membuka POS di luar jam operasional dengan alasan wajib.
- Supervisor dapat membuka POS saat hari libur dengan alasan.
- Pembukaan khusus dicatat dalam audit log.
- Jam operasional mengikuti zona waktu toko.
- Perubahan jam memiliki tanggal dan waktu berlaku.

## 19. Sinkronisasi dan monitoring

### 19.1 Status dan retry

- Transaksi yang sudah dibayar tetap berstatus PAID walaupun belum diterima server pusat.
- Status sinkronisasi disimpan terpisah: PENDING, SYNCED, dan status kegagalan teknis yang diperlukan.
- Sinkronisasi otomatis di latar belakang saat koneksi pulih.
- Retry otomatis sampai berhasil, dengan idempotency.
- Urutan pengiriman: transaksi tertua lebih dahulu.
- Status dan jumlah transaksi pending terlihat pada POS/monitoring.

### 19.2 Ambang peringatan

| Kondisi | Ambang |
|---|---:|
| Peringatan awal transaksi pending | 15 menit |
| Status kritis transaksi pending | 60 menit |
| Peringatan tambahan jumlah antrean | 100 transaksi pending |
| Terminal offline | 5 menit |

Peringatan antrean sinkronisasi ditujukan kepada Supervisor dan Store Admin. Alert operasional lainnya dapat ditujukan kepada Supervisor, Store Admin, Central Admin, dan Owner sesuai jenis alert.

### 19.3 Alert

Jenis masalah yang dipantau:
- Terminal offline.
- Sinkronisasi gagal.
- Antrean transaksi menumpuk.
- Printer gagal.
- Transaksi bermasalah.

Saluran alert: dashboard saja. Dashboard lokal toko tetap tersedia saat internet putus; notifikasi pusat diteruskan setelah koneksi pulih.

## 20. Laporan

Laporan yang disediakan:
- Ringkasan penjualan harian.
- Penjualan per produk/SKU.
- Penjualan per kasir.
- Penjualan per metode pembayaran.
- Diskon dan promosi.
- Pembatalan dan refund.

Filter:
- Toko.
- Periode.
- Kasir.
- Produk.
- Metode pembayaran.

Akses:
- Cashier: transaksi dan sesi sendiri.
- Supervisor: seluruh transaksi dan sesi toko.
- Store Admin: seluruh transaksi dan laporan toko.
- Central Admin: pengelolaan dan monitoring semua toko.
- Owner: seluruh toko, transaksi, dan laporan.

Ketentuan:
- Laporan pusat real-time ketika terhubung.
- Laporan lokal tersedia ketika internet terputus.
- Pusat memperbarui laporan setelah transaksi tersinkron.
- Ekspor: XLSX, CSV, PDF, dan API.
- Ekspor manual dan terjadwal.
- Pengiriman laporan harian otomatis melalui dashboard, email, dan API.
- Jadwal pengiriman dapat dikonfigurasi Central Admin.
- Laporan harian mencakup konsolidasi seluruh toko dan rincian per toko.

## 21. Audit log

- Audit log mencatat tindakan penting, termasuk penghapusan item, pembatalan, refund, diskon, pembatalan promosi, cash in/out, setoran, cetak ulang, perubahan pelanggan, perubahan akun/PIN, terminal, dan konfigurasi.
- Setiap catatan memuat pelaku, waktu, aktivitas, objek, dan detail perubahan yang relevan.
- Retensi audit log: 3 tahun.
- Akses lihat dan ekspor hanya Central Admin dan Owner.
- Central Admin dapat menghapus audit log dengan alasan wajib.
- Penghapusan memerlukan konfirmasi tambahan dan harus menghasilkan catatan penghapusan terpisah yang tidak ikut terhapus.

## 22. Retensi dan arsip

- Transaksi penjualan: 5 tahun.
- Struk dan detail pembayaran: 5 tahun.
- Data pelanggan tidak aktif disimpan permanen sampai ada kebijakan tindakan.
- Transaksi dapat diarsipkan, tetapi harus tetap dapat dicari dan dilaporkan.
- Jadwal arsip dikonfigurasi Central Admin.
- Arsip disimpan di server toko dan pusat.
- Hak akses arsip mengikuti hak akses transaksi/laporan.
- Data dihapus otomatis setelah masa retensi 5 tahun.
- Data yang terkena legal hold atau investigasi dikecualikan dari penghapusan.
- Arsip bukan backup; arsip tetap dapat dicari dan dilaporkan.

## 23. Backup dan pemulihan

- Backup dilakukan di local server toko dan central server.
- Frekuensi backup: harian.
- Retensi backup: 90 hari.
- Backup lokal tetap berjalan saat internet putus.
- Backup pusat dilakukan ketika data tersedia/tersinkron.
- Backup mencakup database transaksi, konfigurasi, dan data penting lainnya.
- Restore harus diuji, bukan hanya memastikan file backup terbentuk.
- RTO maksimum: 4 jam.
- RPO pemulihan dari backup: 1 jam.
- Penanggung jawab pemulihan: Central Admin / central IT.
- Uji restore: setiap kuartal.
- RPO 1 jam berlaku untuk pemulihan dari backup, bukan izin kehilangan transaksi yang sudah dikonfirmasi. Transaksi terkonfirmasi harus dilindungi oleh penyimpanan terminal dan antrean sinkronisasi dengan target kehilangan nol.

## 24. Penomoran transaksi

Nomor struk yang dapat dibaca manusia menggunakan format:

STORECODE-YYYYMMDD-TERMINALCODE-SEQUENCE

Contoh: SDR-20261030-POS01-000001

- Nomor dibuat lokal oleh terminal.
- Nomor harus unik lintas toko dan terminal.
- UUID internal tetap menjadi identitas utama transaksi untuk integrasi dan sinkronisasi.
- Sequence harus persisten dan aman terhadap restart atau kondisi offline.
- Nomor struk digunakan untuk pencarian dan operasional; UUID digunakan untuk identitas teknis dan idempotency.

## 25. Aturan bisnis penting yang tidak boleh dilanggar

1. Transaksi yang sudah dibayar tidak boleh dihapus atau dimutasi diam-diam.
2. Gangguan internet tidak boleh menghalangi penjualan ketika terminal masih dapat beroperasi.
3. Transaksi terkonfirmasi tidak boleh hilang saat aplikasi ditutup atau perangkat restart.
4. Pengiriman ulang tidak boleh menggandakan transaksi atau dampak inventori.
5. Master data pusat menjadi sumber otoritatif.
6. Harga, pajak, dan promosi historis tidak berubah ketika konfigurasi pusat berubah.
7. Stok nol/negatif tidak otomatis memblokir penjualan.
8. Refund uang tidak otomatis mengembalikan stok.
9. Kasir tidak dapat memberikan diskon manual.
10. Semua tindakan sensitif dan koreksi harus dapat diaudit.
11. Hold Order bukan penjualan final.
12. POS tidak mengambil alih fungsi inventori, manufaktur, pembelian, atau akuntansi.

## 26. Hal yang perlu dipastikan pada tahap desain teknis

Bagian ini bukan pertanyaan bisnis baru. Ini adalah pekerjaan desain dan pengujian yang harus diselesaikan sebelum atau selama implementasi:

- Model data yang konsisten untuk laci kas per terminal dan sesi kasir per individu, agar saldo modal tidak dihitung ganda saat pergantian kasir.
- Mekanisme transaksi yang sedang terbuka saat perubahan harga, pajak, atau promosi; snapshot harus konsisten.
- Strategi penyimpanan lokal terminal dan sinkronisasi ketika local server/LAN mati.
- Penanganan pembayaran non-tunai yang statusnya belum pasti dan verifikasi Supervisor.
- Kontrak API inventori, termasuk acknowledgement, idempotency, koreksi, dan refund barang layak jual.
- Perhitungan pajak dan alokasi diskon proporsional dengan pembulatan rupiah yang deterministik.
- Sequence nomor struk lokal yang aman dari duplikasi.
- Matriks izin lengkap per aksi untuk kelima peran.
- Prosedur restore yang memenuhi RTO/RPO.
- Pengujian konkurensi, duplikasi pesan, retry, offline berkepanjangan, dan pemulihan terminal.

## 27. Urutan pekerjaan setelah dokumen ini

1. Desain database PostgreSQL: entitas, relasi, constraint, indeks, transaksi lokal, outbox, dan audit.
2. Struktur repository dan folder proyek.
3. Kontrak API frontend-backend, terminal-local server, local-central server, dan inventori.
4. Implementasi bertahap.
5. Pengujian fungsional, integrasi, offline, pemulihan, dan keamanan.

**Catatan status:** Dokumen ini merekam kebutuhan dan keputusan yang telah diketahui dari diskusi. Dokumen ini belum merupakan desain database, kontrak API final, atau kode implementasi. Setiap perubahan kebutuhan setelah baseline ini sebaiknya dicatat sebagai change request dengan alasan dan dampaknya.
