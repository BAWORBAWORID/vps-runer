# Membuat atau memperbarui repository VpsFree

Kredit: KallAncrit. Template asli: `xykal/XyRDP`. Ikuti [README aktif](README.md).

1. Fork repository ini (atau salin isinya) dengan nama repository pilihanmu.
2. Aktifkan Actions, lalu isi secret `VPS_PASSWORD` (password root/user sudo).
3. Jalankan workflow VpsFree. Akses SSH publik lewat Bore tunnel: `ssh -p <port> root@bore.pub` (port muncul di log Actions / branch `status`).
4. Jangan mencetak atau menyimpan password di file/log/status.
5. Sesi berakhir otomatis pada batas waktu. Renewal berjalan sebelum waktu habis dan tidak menghapus state.

Repository lama (versi RDP/Windows) perlu menyinkronkan `.github/workflows/vps-6h.yml` + seluruh `scripts/` (bash), lalu menghapus berkas Windows/RDP lama.
