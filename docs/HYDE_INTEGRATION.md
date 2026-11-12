# Tích Hợp Giao Diện Hyprland + Dotfiles AniDE/HyDE (`HYDE_INTEGRATION.md`)

Tài liệu này ghi lại việc **loại bỏ hoàn toàn GNOME (GDM + GNOME Shell + dconf)** khỏi AniTails và thay bằng **Hyprland** sử dụng **dotfiles của [AniDE](https://github.com/hyprdes/AniDE)** — bản fork của dự án [HyDE](https://github.com/HyDE-Project/HyDE) (`v26.8.1`, giấy phép `GPL-3.0-only`).

- Dotfiles được **vendor** (đóng gói tĩnh) vào ISO tại `/usr/share/anitails/hyde/`, ghim theo **commit `6d441fcb076954a7c64d19296454a4c14a4c61e1`** và **SHA-256 từng tệp** (`MANIFEST.sha256`, 485 tệp, ~7.7 MiB).
- Không có bước tải mạng nào khi khởi động: dotfiles được **seed** vào `$HOME` bởi `anitails-hyde-seed` sau khi xác minh manifest.
- Không còn display manager: `getty@tty1` tự đăng nhập `amnesia`, sau đó `uwsm` khởi động Hyprland trong một phiên systemd-user hợp lệ.

---

## 1. Vì Sao Phải Bỏ GNOME?

GNOME trong AniTails cũ (kế thừa từ Tails) kéo theo **GDM (chạy dưới quyền root)**, GNOME Shell, dconf, `xdg-desktop-portal-gnome`, Nautilus, GNOME Console, Loupe, Papers, GNOME Control Center… Điều đó tạo ra:

1. **Bề mặt tấn công lớn**: một greeter + shell chạy trước phiên người dùng, dùng dbus/dconf, với nhiều thành phần C/JS.
2. **Phụ thuộc dconf**: cấu hình quyền riêng tư (automount, location) phải biên dịch bằng `dconf update` ở build-time; mọi thay đổi phiên đều ghi vào `~/.config/dconf/user`.
3. **Không cần thiết cho mô hình Live**: AniTails luôn tự đăng nhập `amnesia`, không có màn hình greeter để chọn ngôn ngữ/bàn phím.

Hyprland (wlroots) + HyDE cho một desktop Wayland gọn hơn, cấu hình bằng tệp văn bản (Lua/TOML/CSS), không có daemon đồ họa chạy root, và phù hợp với chính sách "không có thành phần mạng/đồ họa thừa" của AniTails.

---

## 2. Đã Xóa Những Gì

| Thành phần cũ | Xử lý | Ghi chú |
|---|---|---|
| `gdm` + `/etc/gdm/custom.conf` | **Xóa** | Thay bằng `getty@tty1` autologin + `uwsm` |
| Người dùng/nhóm `gdm` (`UID/GID 120`) | **Xóa** khỏi `passwd`, `group`, `shadow`, `gshadow` | `anitails-alpm-finalize` cũng không còn symlink `display-manager.service → gdm.service` |
| `GDM_UID` trong `nftables.conf` | **Xóa** | UID 120 không còn được phép chạm Tor ControlPort `4101`; chỉ `amnesia` (1000) |
| `gnome-shell`, `gnome-session`, `gnome-control-center`, `gnome-console`, `gnome-keyring`, `gnome-text-editor`, `gnome-calculator`, `gnome-disk-utility` | **Xóa** | Thay bằng kitty / kate / qalculate-qt / udiskie / HyDE menu |
| `nautilus` | **Xóa** | Thay bằng `dolphin` (mặc định của HyDE) |
| `loupe`, `papers` | **Xóa** | Thay bằng `imv`, `zathura` + `zathura-pdf-mupdf` |
| `xdg-desktop-portal-gnome` | **Xóa** | Thay bằng `xdg-desktop-portal-hyprland` + `xdg-desktop-portal-gtk` |
| `dconf` + `/etc/dconf/*` + `Configs/.config/dconf` | **Xóa** | Không còn cơ sở dữ liệu dconf; GTK dùng `gtk-3.0/settings.ini`, `xsettingsd`, `nwg-look` |
| `xdg-user-dirs-gtk`, `cantarell-fonts`… | Thay đổi | `xdg-user-dirs`; `cantarell-fonts` **giữ** (font, không phải desktop) |
| `firefox` | **Không đưa vào** | AniTails chặn toàn bộ clearnet; trình duyệt duy nhất là Tor Browser (`SUPER + B`) |

> **Giữ lại có chủ đích:** `celluloid` (trình phát Tails 7.10+, đã có hồ sơ AppArmor `deny network`), `gnome-keyring` **không** được giữ, `zenity` (script/desktop entry), font Cantarell.

---

## 3. Thành Phần Mới

### 3.1. Gói hệ thống (`archiso/packages.x86_64`)

| Nhóm | Gói |
|---|---|
| Compositor & phiên | `hyprland`, `uwsm`, `hyprlock`, `hypridle`, `hyprsunset`, `hyprpaper`, `hyprpicker`, `hyprpolkitagent`, `polkit`, `lua`, `luarocks`, `libgirepository` |
| Shell desktop | `waybar`, `rofi-wayland`, `dunst`, `libnotify`, `cliphist`, `wl-clip-persist`, `grim`, `slurp`, `satty`, `xwaylandvideobridge` |
| Portal | `xdg-desktop-portal`, `xdg-desktop-portal-hyprland`, `xdg-desktop-portal-gtk` |
| Ứng dụng | `kitty`, `dolphin`, `ark`, `kate`, `mpv`, `celluloid`, `imv`, `zathura`, `qalculate-qt`, `nwg-look`, `nwg-displays` |
| Âm thanh/thiết bị | `pipewire*`, `wireplumber`, `pavucontrol`, `pamixer`, `playerctl`, `bluez`/`blueman`, `brightnessctl`, `udiskie`, `network-manager-applet` |
| Gõ tiếng Việt | `ibus`, `ibus-unikey` |

`archiso/snapshot.lock.json` có mục mới **`desktop_stack_packages`** (ghim **phiên bản tối thiểu** thay vì phiên bản chính xác, vì đây không phải ràng buộc ABI bảo mật) và **`desktop_dotfiles`** (commit + license + manifest của AniDE). SBOM CycloneDX sinh ra từ hai mục này.

### 3.2. Dotfiles vendor

```text
archiso/airootfs/usr/share/anitails/hyde/
├── Configs/            # 474 tệp nguyên bản từ AniDE (Configs/.config, Configs/.local)
├── overrides/          # 7 tệp do AniTails viết (chính sách, xem §4)
├── LICENSE             # GPL-3.0-only của AniDE/HyDE
├── UPSTREAM.json       # repo, commit, ngày, danh sách loại trừ
└── MANIFEST.sha256     # SHA-256 từng tệp (483 mục)
```

Sinh lại bằng:

```bash
git clone --depth 1 https://github.com/hyprdes/AniDE /tmp/AniDE
python3 scripts/sync-hyde-dotfiles.py --source /tmp/AniDE   # vendor + verify
python3 scripts/sync-hyde-dotfiles.py --check                # chỉ xác minh
```

Công cụ vendor **bỏ qua** hai loại tệp:

- `.gitignore` / `.gitattributes` của upstream — đây là metadata repo, không phải cấu hình desktop.
  Lý do cụ thể: `Configs/.config/hypr/shaders/.gitignore` chứa đúng một dòng `*`, nên `git add`
  bỏ qua **toàn bộ** 12 shader Hyprland (`.frag`, `wallbash.inc`). Tệp vẫn có trong work tree
  (manifest cục bộ vẫn PASS) nhưng **biến mất khi clone sạch** — đúng lỗi mà CI
  *"Validate all 4 isolated Archiso & NVIDIA profiles"* báo (`missing: Configs/.config/hypr/shaders/*`).
- `*.cache.glsl` — cache biên dịch shader sinh ra lúc chạy, không phải cấu hình.

Ngoài ra, cả `--source` lẫn `--check` đều gọi `git check-ignore` trên từng tệp đã vendor và
**thoát với mã 1** nếu git sẽ bỏ qua bất kỳ tệp nào, để cây vendor không bao giờ lệch khỏi
một checkout sạch. Khi kiểm chứng thủ công, luôn dùng bản clone mới thay vì work tree:

```bash
git clone --depth 1 --branch <branch> <repo> /tmp/verify \
  && cd /tmp/verify && python3 scripts/sync-hyde-dotfiles.py --check
```

**Loại trừ có chủ đích** (`UPSTREAM.json → excluded_paths`):

| Đường dẫn | Lý do |
|---|---|
| `Configs/.config/dconf` | Backend cấu hình của GNOME — AniTails không còn GNOME/dconf |
| `Configs/.config/Code`, `Code - OSS`, `VSCodium` | Không có VS Code trong ISO |
| `Configs/.local/state` | Trạng thái runtime của tác giả upstream |
| `Configs/.local/bin/hydectl` (13 MB ELF) | **Binary Go dựng sẵn, không có mã nguồn trong repo** — trái chính sách "không chứa blob mờ" |
| `Configs/.local/bin/hyde-ipc` (2.8 MB ELF) | Như trên |

HyDE shell (`hyde-shell`) là bash + Python và **không cần** hai binary này; chỉ `hyde-shell version` in "hydectl not found". Kiểm thử `tests/test_hyde_dotfiles.py` chặn mọi tệp ELF trong cây vendor.

### 3.3. Bộ seed offline (`/usr/local/lib/anitails-hyde-seed`)

- Xác minh `MANIFEST.sha256` **trước khi ghi bất kỳ byte nào**; sai lệch ⇒ `exit 1`, không seed (fail-closed).
- `Configs/**` → `$HOME/**` (giữ nguyên tệp đã có ⇒ bảo toàn chỉnh sửa của người dùng, kể cả trên Persistent Storage).
- `overrides/**` → `$HOME/**` và **luôn ghi đè** (đây là chính sách AniTails), ngoại lệ duy nhất là `~/.config/hypr/hyprland.lua` (tệp người dùng): chỉ ghi khi còn là bản upstream nguyên gốc.
- Tạo `~/.local/state/hyde/version` (cho `hyde-shell version`), `~/Downloads`, `~/Pictures/Wallpapers`, `~/Persistent`, chạy `xdg-user-dirs-update`.
- Tùy chọn: `--check`, `--force` (reset về mặc định AniTails), `--quiet`, `--home`.

### 3.4. Ghi đè chính sách của AniTails (`archiso/hyde-overrides/`)

| Tệp | Nội dung |
|---|---|
| `.config/hyde/config.toml` | `browser = anitails-tor-browser`, `editor = kitty -e vim`, `explorer = dolphin`, `lockscreen = lockscreen-disabled.sh`, `start.bar = bar.sh`, `start.wallpaper = wallpaper.sh`, `wallpaper.backend = hyprpaper`, cursor/icon/font dùng gói có sẵn (Bibata, Adwaita, Cantarell, JetBrainsMono) |
| `.config/hypr/hyprland.lua` | Nguyên bản HyDE + `pcall(require, "anitails")` ở cuối |
| `.config/hypr/anitails.lua` | `SUPER + B` → Tor Browser, `SUPER + L` → thông báo khóa màn hình bị tắt, `SUPER + CTRL + B` → bật/tắt bar, `SUPER + SHIFT + I` → `anitails-hyde-doctor` |
| `.config/hypr/hypridle.conf` | **Không** có `lock_cmd`/`loginctl lock-session`, **không** suspend (AniTails cấm sleep); chỉ dim 60s + DPMS off 300s |
| `.config/waybar/{config.jsonc,style.css}` | Bar dự phòng (workspaces, clock, audio, network, battery, tray) |
| `.config/uwsm/env.d/90-anitails.sh` | `BROWSER=/usr/local/bin/anitails-tor-browser`, `ANITAILS_*` |

---

## 4. Luồng Phiên (không có display manager)

```text
systemd multi-user.target
   └── getty@tty1.service  (+ drop-in 20-anitails-autologin.conf: --autologin amnesia)
        └── login shell bash -l
             └── /etc/profile.d/99-anitails-session.sh   (chỉ VT1, chỉ login shell)
                  └── /usr/local/bin/anitails-hyprland-session
                       ├── anitails-hyde-seed  (xác minh SHA-256 → seed $HOME)
                       ├── log /run/anitails/gpu.env (do anitails-gpu-select sinh ra)
                       └── uwsm start hyprland-uwsm.desktop
                            └── Hyprland (~/.config/hypr/hyprland.lua → HyDE)
                                 ├── HyDE autostart: wallpaper (hyprpaper), bar (waybar),
                                 │   dunst, cliphist, hypridle, hyprsunset, polkit agent,
                                 │   nm-applet, udiskie, blueman-applet, ibus
                                 └── AniTails override: anitails.lua (Tor Browser, no lock)
```

Chính sách khi lỗi:

| Tình huống | Hành vi |
|---|---|
| Không xác minh được dotfiles | Không khởi động desktop; vào shell TTY với thông báo lỗi |
| Hyprland thoát bình thường | `systemctl poweroff` (giống Tails: kết thúc phiên = tắt máy, xóa RAM) |
| Hyprland crash 3 lần liên tiếp | Vào `bash -l` để debug (`journalctl --user -b`) |
| Rút USB khởi động | `anitails-udev-watchdog-wrapper`: kill `amnesia`, kill `hyprland-uwsm.service`, khóa LUKS2, poweroff + wipe RAM |

**Vì sao không dùng SDDM (dù HyDE mặc định dùng SDDM)?** SDDM là một daemon Qt chạy dưới quyền root chỉ để hiển thị greeter — trong khi AniTails luôn tự đăng nhập và không có bước chọn phiên. Bỏ DM giảm một tiến trình root và một socket đồ họa; `uwsm` vẫn đảm bảo Hyprland nằm trong phiên systemd-user đúng chuẩn (nhờ đó `/run/environment.d/50-anitails-gpu.conf` của `anitails-gpu-select` được import).

---

## 5. Những Phần Của HyDE Không Được Đóng Gói

HyDE 26.8.1 phụ thuộc một số gói **chỉ có trên AUR** (không nằm trong snapshot Arch chính thức mà AniTails ghim). AniTails **không** dùng AUR/Chaotic-AUR (chính sách chuỗi cung ứng: mọi gói phải đến từ mirror Arch Archive đã ký, có SBOM).

| Thành phần HyDE | Trạng thái trong AniTails | Ảnh hưởng / thay thế |
|---|---|---|
| `quickshell` (bar mặc định) | **Không có** | `bar.sh` phát hiện thiếu ⇒ chạy **Waybar** với cấu hình AniTails |
| `hyprquery` (CLI đọc cấu hình cho theme engine) | **Không có** | Wallbash không sinh lại bảng màu động; theme tĩnh từ `~/.config/hypr/themes/colors.conf` vẫn chạy |
| `wlogout` (menu đăng xuất) | **Không có** | Dùng `hyprctl dispatch exit` hoặc `hyde-shell` (bind `CTRL + ALT + DELETE` của HyDE) |
| `sddm` + theme SDDM | **Không có** | Autologin qua getty (xem §4) |
| `swayosd-git`, `wayle-bin`, `matugen-bin`… | **Không có** | OSD/âm lượng dùng `pamixer`/`pavucontrol` |
| `awww` (wallpaper backend mặc định mới của HyDE) | **Thay bằng `hyprpaper`** | `hyprpaper` chắc chắn có trong `[extra]` và HyDE có sẵn `wallpaper.hyprpaper.sh`; `[wallpaper] backend = "hyprpaper"` |
| `hydectl`, `hyde-ipc` | **Không có** | Blob dựng sẵn (xem §3.2) |
| Theme/wallpaper/font tải từ mạng (deez-dots `archives.toml`) | **Không chạy** | Ảnh nền duy nhất: `/usr/share/anitails/wallpapers/anitails-default.png`; font hệ thống: Noto, DejaVu, Cantarell, JetBrainsMono Nerd Font; icon: Adwaita; cursor: Bibata |
| `firefox`, `code`, `steam`, `spotify`, `cava`(có gói)… | **Không có** | Tor Browser là trình duyệt duy nhất |

Người dùng có thể tự cài thêm gói AUR nếu muốn (phiên Live là amnesic, không tồn tại sau reboot), nhưng ISO **không** mang theo.

---

## 6. Quyết Định Bảo Mật

1. **Không khóa màn hình.** `amnesia` có mật khẩu bị khóa (`!*`) và AniTails cấm sudo không mật khẩu ⇒ `hyprlock` sẽ tạo màn hình không thể mở. Tails cũng tắt khóa màn hình vì lý do này. `SUPER + L` chỉ hiện thông báo; `hypridle.conf` không có listener lock.
2. **Không suspend/hibernate.** Đã bị vô hiệu toàn hệ thống (`90-disable-sleep.conf`, `swap.target` masked); RAM chỉ bị xóa khi tắt máy/rút USB, nên suspend sẽ giữ bí mật trong RAM. `hypridle.conf` chỉ dim + tắt DPMS.
3. **Trình duyệt duy nhất là Tor Browser.** Bind `SUPER + B` và `[desktop.app] browser` đều trỏ `anitails-tor-browser`; `firefox` không có trong ISO và bị kiểm thử chặn.
4. **Không có blob mờ.** `hydectl`/`hyde-ipc` bị loại; `tests/test_hyde_dotfiles.py` quét magic `\x7fELF` trong cây vendor.
5. **Fail-closed khi seed.** Manifest sai ⇒ không seed, không desktop.
6. **Không còn UID 120 trên Tor ControlPort.** Luật nftables chỉ cho `amnesia` (1000) và `tor` (43).
7. **Kiểm tra ở build-time.** `anitails-alpm-finalize` chạy `sha256sum -c MANIFEST.sha256` trong chroot; build thất bại nếu dotfiles bị sửa.
8. **Display-manager bị mask.** `display-manager.service → /dev/null` để không thành phần nào chiếm VT1.

---

## 7. Kiểm Tra & Gỡ Lỗi

```bash
# Trạng thái thành phần desktop (có trong menu: SUPER + SHIFT + I)
anitails-hyde-doctor

# Xác minh / seed lại dotfiles
/usr/local/lib/anitails-hyde-seed --check
sudo /usr/local/lib/anitails-hyde-seed --force     # reset mặc định AniTails

# Log phiên
journalctl --user -b            # dịch vụ người dùng (uwsm, waybar, hypridle…)
journalctl -b -t anitails-watchdog
hyprctl version && hyprctl clients

# Kiểm thử trong repo
python3 -m unittest tests.test_hyde_dotfiles -v
python3 tests/run_all_tests.py
```

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
|---|---|---|
| Màn hình đen, không có bar | Thiếu `quickshell` là bình thường; nếu cả Waybar không lên | `Ctrl+Alt+F2` → `journalctl --user -b -u hyprland-uwsm` |
| `SUPER + L` không khóa | **Đúng thiết kế** | Không có mật khẩu để mở khóa |
| Ảnh nền đen | `hyprpaper` không chạy | `systemctl --user status hyprpaper`; chạy lại `wallpaper.sh` |
| Màu theme không đổi theo ảnh nền | Thiếu `hyprquery` (AUR) | Chỉnh tay `~/.config/hypr/themes/colors.conf` |
| "dotfile verification failed" | SquashFS/homed bị sửa | Khởi động lại; nếu lặp lại, kiểm tra ISO |

---

## 8. Kiểm Thử Tự Động

`tests/test_hyde_dotfiles.py` (16 test) bao phủ:

- manifest khớp 100% (`sync-hyde-dotfiles.py --check`), provenance + license GPL-3.0, commit khớp `snapshot.lock.json`;
- không có ELF/dconf/hydectl trong cây vendor; tập override đúng như tài liệu;
- seeder: tạo đủ tệp, idempotent, giữ chỉnh sửa người dùng, `--check` không ghi, **từ chối cây bị sửa hash**, `--force` reset chính sách;
- launcher: seed → `uwsm start hyprland-uwsm.desktop`, fail-closed, poweroff khi thoát, shell dự phòng;
- autologin chỉ `amnesia`, không còn gdm/display-manager;
- overrides phản ánh chính sách (Tor Browser, không lock, không suspend, bar fallback);
- danh sách gói có Hyprland, không có GNOME/`firefox`/`quickshell`; `snapshot.lock.json` không còn `gnome-shell`/`gdm`;
- wallpaper PNG + doctor tồn tại; mọi đường dẫn `file_permissions` tồn tại trước `pacstrap`.
