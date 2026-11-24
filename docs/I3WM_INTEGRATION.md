# Tích Hợp Giao Diện i3-gaps + Xorg (`I3WM_INTEGRATION.md`)

Tài liệu này ghi lại việc **thay thế hoàn toàn** stack Hyprland + dotfiles
AniDE/HyDE (Wayland, ~123.000 dòng vendor) bằng **i3-gaps trên Xorg (X11)** do
**AniTails viết toàn bộ** (`GPL-3.0-or-later`). Không còn GNOME, không còn Wayland,
không còn display manager: `getty@tty1` tự đăng nhập `amnesia` → `startx` →
`i3` (Xorg native).

- Các tệp cấu hình gốc (10 tệp, ~520 dòng) nằm tại
  `archiso/airootfs/usr/share/anitails/i3/Configs/**`, ghim **commit + SHA-256
  từng tệp** (`MANIFEST.sha256`, do `scripts/sync-i3-dotfiles.py` sinh ra), và
  được **seed** Offline vào `$HOME` bởi `anitails-i3-seed` (fail-closed nếu
  manifest sai lệch).
- Thiết kế: Midnight Aurora — navy tối sâu, accent cyan/violet, thanh Waybar nổi,
  bo góc mịn, bo tròn 14px, nền `#0a0d16`.
- Không có bước tải mạng nào: không AUR (Quickshell), không blob ELF dựng sẵn.

---

## 1. Vì Sao Phải Chuyển Sang i3-gaps?

Hyprland + AniDE/HyDE nặng (~123K dòng vendor, 485 tệp, commit ghim, manifest
485 hash) khiến ISO cồng kềnh và khó kiểm toán. Trong khi đó:

1. **i3-gaps là công cụ nhẹ, cấu hình thuần văn bản** (không Lua/TOML),
   phù hợp với chính sách "ít phụ thuộc, fail-closed" của AniTails.
2. **Xorg đã hoạt động ổn định từ lâu** trên mọi GPU tier (KMS nouveau/NVK/
   Intel/AMD + simpledrm), kèm `feh`/`scrot`/GTK3/4 tất định — tránh rủi ro
   Wayland compositor trên phần cứng cũ.
3. **Hạt nhân bảo mật không đổi**: nftables, MAC spoof, RAM wipe, LUKS2, truststore
   blacklist, netns cách ly netns, `anitails-onion-grater` vẫn nguyên vẹn.
4. **X11 là trade-off có chủ đích** (xem §8): bất kỳ ứng dụng nào trên màn hình
   đều đọc được nội dung màn hình của ứng dụng khác thông qua X11. AniTails
   giảm rủi ro bằng cách không đóng gói thêm ứng dụng hiển thị, không boot
   thêm portal hay Wayland stack, và ghi nhận điều này trong SECURITY_LIMITATIONS.

---

## 2. Đã Xóa Những Gì

| Thành phần cũ | Xử lý |
|---|---|
| `hyprland` + `uwsm` + `hyprlock` + `hypridle` + `hyprsunset` + `hyprpaper` + `hyprpicker` + `hyprpolkitagent` + `lua` + `luarocks` + `libgirepository` | **Xóa** |
| Dotfiles AniDE/HyDE vendor (`archiso/airootfs/usr/share/anitails/hyde/`, 485 tệp, ~123K dòng, GPL-3.0-only) | **Xóa** — thay bằng stack i3-gaps tự viết |
| `archiso/hyde-overrides/` (7 tệp override) | **Xóa** — i3 không có upstream để override; mọi tệp đều là chính sách |
| `anitails-hyprland-session` + `anitails-hyde-seed` + `anitails-hyde-doctor` + `anitails-hyde-desktop/` (bar.sh, wallpaper.sh, lockscreen-disabled.sh) | **Xóa** — thay bằng `anitails-i3-session`, `anitails-i3-seed`, `anitails-i3-doctor`, `anitails-i3-desktop/lockscreen-disabled.sh` + `anitails-i3-bar.sh` |
| `grim`, `slurp`, `satty`, `wl-clipboard`, `wl-clip-persist`, `xwaylandvideobridge`, `xorg-xwayland`, `qt6-wayland`, `qt5-wayland`, `rofi-wayland`, `nwg-displays`, `hyprland-protocols`, `aquamarine`, `hyprutils`, `hyprlang`, `hyprgraphics`, `hyprcursor` | **Xóa** — thay bằng `scrot`, `feh`, `waybar`, `wofi` |
| `xdg-desktop-portal-hyprland` | **Xóa** — thay bằng `xdg-desktop-portal-gtk` (GTK trên X11) |
| `scripts/sync-hyde-dotfiles.py` + `tests/test_hyde_dotfiles.py` | **Xóa** — thay bằng `scripts/sync-i3-dotfiles.py` + `tests/test_i3_dotfiles.py` |
| `gnome-initial-setup-done` (dấu GNOME cũ) | **Xóa** |
| `docs/HYDE_INTEGRATION.md` | **Đổi tên** → `docs/I3WM_INTEGRATION.md` |

---

## 3. Thành Phần Mới

### 3.1. Gói hệ thống (`archiso/packages.x86_64`)

| Nhóm | Gói |
|---|---|
| Compositor & phiên | `xorg-server`, `xorg-xinit`, `xorg-xauth`, `xorg-xrdb`, `xorg-xsetroot`, `xorg-xrandr`, `libxcursor`, `i3-gaps`, `polkit` |
| Shell desktop | `i3bar` (đi kèm `i3`) + `anitails-i3status`, `wofi`, `dunst`, `libnotify`, `cliphist`, `scrot`, `feh` (gói `waybar` vẫn cài nhưng **không** chạy trên Xorg — xem §3.3) |
| Terminals/Files/Media | `kitty`, `dolphin`, `ark`, `kde-cli-tools`, `ffmpegthumbs`, `qt5-imageformats`, `kimageformats`, `kate`, `mpv`, `celluloid`, `imv`, `zathura`, `zathura-pdf-mupdf`, `qalculate-qt`, `vim`, `fzf` |
| Theming | `gtk3`, `gtk4`, `qt5ct`, `qt6ct`, `nwg-look`, `adwaita-icon-theme`, `capitaine-cursors`, `xsettingsd` |
| Bảo vệ quyền riêng tư | `ibus`, `ibus-unikey`, `keepassxc`, `mat2`, `electrum`, `thunderbird`, `onionshare` |

### 3.2. Cấu trúc thư mục

| Đường dẫn | Nội dung |
|---|---|
| `archiso/airootfs/usr/share/anitails/i3/` | 10 tệp design (`Configs/`) + `MANIFEST.sha256` + `UPSTREAM.json` |
| `archiso/airootfs/usr/local/lib/anitails-i3-seed` | Seeder offline, fail-closed |
| `archiso/airootfs/usr/local/bin/anitails-i3status` | `status_command` của i3bar: banner posture (Tor ●/○, fw, LUKS, RAM wipe) + đồng hồ, giao thức JSON của i3bar |
| `archiso/airootfs/usr/local/lib/anitails-i3-bar.sh` | Launcher Waybar **chỉ cho phiên Wayland**; trên Xorg thoát `0` kèm thông báo |
| `archiso/airootfs/usr/local/lib/anitails-i3-desktop/lockscreen-disabled.sh` | Thông báo tắt khóa (Tails-style) |
| `archiso/airootfs/usr/local/bin/anitails-i3-session` | Launcher (`startx` → `i3-gaps`), fail-closed |
| `archiso/airootfs/usr/local/bin/anitails-i3-doctor` | Báo cáo thành phần i3 + seed state |
| `archiso/airootfs/usr/local/bin/anitails-screenshot` | Screenshot `scrot` + hộp thoại cảnh báo |
| `archiso/airootfs/etc/X11/xinit/anitails-i3.sh` | Wrapper Xorg (client mà `startx` chạy) |
| `Configs/.xserverrc` | `$HOME/.xserverrc` đã seed — ghim Xorg vào `vt$XDG_VTNR` để chạy **rootless** trên VT1 |

### 3.3. Vì sao thanh trạng thái là i3bar, không phải Waybar

Waybar từ **0.11** vẽ **duy nhất** qua `gtk-layer-shell` (`Require gtk-layer-shell`).
Thư viện đó trả lời câu hỏi "có hỗ trợ không" bằng chính loại display:

```c
gboolean gtk_layer_is_supported () {
    if (!GDK_IS_WAYLAND_DISPLAY (gdk_display_get_default ()))
        return FALSE;
    ...
}
```

và khi bị gọi trên X11, `gtk_layer_init_for_window()` chỉ ghi
*"Falling back to XDG shell instead of Layer Shell (surface should appear but layer features
will not work)"* rồi để cửa sổ thành **toplevel GTK thường**. Với i3, hệ quả không phải "bar
thiếu vài tính năng" mà là **một cửa sổ lạc bị xếp vào tile** ở mỗi lần đăng nhập — vừa xấu vừa
chiếm chỗ, và không có strut nên cửa sổ khác bị đẩy xuống.

Cách AniTails xử lý (không thêm gói nào — `i3bar` nằm trong gói `i3`):

| Thành phần | Vai trò |
|---|---|
| `bar { mode dock; position top; status_command /usr/local/bin/anitails-i3status --interval 5 }` | i3bar vẽ thanh, workspace buttons + tray tắt (`tray_output none`) |
| `anitails-i3status` | In header `{"version": 1}` rồi mỗi 5 s một frame block JSON: `posture`, `firewall`, `persistence`, `ramwipe`, `clock` |
| `anitails-posture --json` | Nguồn dữ liệu posture (best-effort; lỗi → `unknown`, thanh không chết) |
| `anitails-i3-bar.sh` | Chỉ chạy Waybar khi có `WAYLAND_DISPLAY`; ngoài Wayland thoát `0` + thông báo |
| `SUPER+Shift+B` | `bar mode toggle` (ẩn/hiện thanh) |

`i3bar` không nằm trong `MANIFEST.sha256` (chỉ `Configs/` mới được seed vào `$HOME`);
`anitails-i3status` là script hệ thống tại `/usr/local/bin` và được kiểm thử bởi
`tests/test_i3_bar.py` (10 bài, xem `docs/TEST_REPORT.md` §8).

---

## 4. Luồng Phiên getty → startx → i3-gaps

```text
[getty@tty1 → autologin amnesia]
   └── login shell → /etc/profile.d/99-anitails-session.sh (guarded: VT=1, interactive, no DISPLAY)
        └── anitails-i3-session
             ├── anitails-i3-seed --quiet  (verify MANIFEST.sha256 trước, fail-closed)
             └── startx /etc/X11/xinit/anitails-i3.sh
                  ├── ~/.xserverrc -> /usr/bin/X -nolisten tcp vt$XDG_VTNR  (rootless, cùng VT1)
                  ├── xsetroot -solid '#0a0d16'
                  ├── feh --bg-fill ... (best-effort)
                  └── exec /usr/bin/i3
                       ├── exec_always xrdb -merge ~/.Xresources  (cursor capitaine-cursors, DPI 96)
                       ├── exec_always anitails-i3-bar.sh       (no-op on Xorg)
                       ├── bar { status_command anitails-i3status }  (i3bar + posture)
                       └── exec_always dunst
```

- Không greeter, không display manager, không root GUI.
- `anitails-i3-session` poweroff khi i3 thoát sạch; 3 lần crash → drop shell dự phòng (không loopvô hạn).
- Xorg chạy **rootless**: `~/.xserverrc` (seed từ `Configs/.xserverrc`, đã kiểm `MANIFEST.sha256`)
  truyền `vt$XDG_VTNR` để server ở lại đúng VT mà `pam_systemd` đã cấp cho phiên autologin.
  Thiếu tham số này Xorg phải `VT_ACTIVATE` một VT khác — thao tác cần root — nên hoặc tự
  re-exec bằng quyền root, hoặc dừng với `SIGTTOU` và không có phiên đồ hoạ nào xuất hiện.
  `-nolisten tcp` giữ nguyên mặc định của gói: live system không mở transport X qua TCP.
- Phím tắt không gian làm việc: `SUPER + <1..9>` chuyển workspace, `SUPER + CTRL + <1..9>`
  đưa cửa sổ đang focus sang workspace đó (`SUPER + SHIFT + 4` dành cho chụp màn hình kiểu macOS).

---

## 5. Bất biến bảo mật của lớp giao diện

1. Không có process đồ họa root; không có greeter, không có Wayland compositor.
2. Không có trình duyệt clearnet: `SUPER + B` → `anitails-tor-browser` (Tor only), ràng buộc trong i3 config.
3. Không khóa màn hình, không suspend: `amnesia` có mật khẩu bị khóa, suspend giữ bí mật trong RAM.
4. Dotfile chỉ được seed sau khi `MANIFEST.sha256` khớp; build cũng chạy `sync-i3-dotfiles.py --check` trước `mkarchiso`.
5. Không mang blob ELF dựng sẵn: quét magic `\x7fELF` trong cây vendor (test).

---

## 6. STEP 2 — UX/UI Polish

Three UX/UI additions ship with this i3-gaps stack:

| UX element | Implementation |
|---|---|
| **Security posture module** | `anitails-posture --json` feeds `anitails-i3status`, which renders a `posture` block in **i3bar** (`Tor ●`/`Tor ○`, plus `fw`/`LUKS`/`RAM` chips, cyan = healthy, amber/muted = not). The tooltip carries firewall/persistence/RAM-wipe/release verdict. The same `anitails-posture --inline` module is kept in `waybar/config.jsonc` for a future Wayland session. |
| **Settings / posture surface** | SUPER+S → `anitails-settings` (kitty `--layout stacked`, dark chrome, kitty.conf decorations). Falls back to a console print if kitty is absent. `--json` mode for scripts. |
| **Wallpaper** | `anitails-default.png` — Midnight Aurora gradient (cyan→violet over #0a0d16), 1376×768, generated for this design (NOT a stock AniTails/HyDE image). |

- Design preview (AI-generated mock, **not** an actual screenshot of the live system): [`docs/assets/design-preview.png`](assets/design-preview.png)
- Wallpaper replacement (file-in-place, no manifest change — wallpaper lives outside the `Configs/` tree).
- i3bar posture blocks: `anitails-i3status` (`posture`, `firewall`, `persistence`, `ramwipe`, `clock`);
  Waybar `custom/posture` (`waybar/config.jsonc` + `#custom-posture` in `style.css`) is Wayland-only fallback — see §3.3.
- Bar toggle: `bindsym $mod+Shift+b bar mode toggle`.
- i3 binding: `bindsym $mod+S exec /usr/local/bin/anitails-settings`.

## 6b. Trade-off & Quyết định

| Tiêu chí | Wayland Hyprland (cũ) | **X11 i3-gaps (mới)** |
|---|---|---|
| Vật lý trên màn hình | Cách ly theo app (mỗi app 1 screen) | X11 shared display — mọi app đọc được nội dung màn hình của app khác |
| Phù hợp AniTails | Rất cao (nhưng nặng) | Trung bình — chấp nhận rủi ro X11 khi muốn giảm độ phức tạp |
| Kích thước ISO | Vùng lớn (~123K dòng vendor) | Nhỏ (~500 dòng tự viết) |
| Offline/kiểm toán | Khó (485 hash + commit ghim) | Dễ (10 tệp, 1 manifest) |
| Ảnh nền/screenshot | `hyprpaper` (trong cluster) | `feh` + `scrot` (tool nhẹ, X11 chuẩn) |

Nếu muốn hoàn nguyên cho mục đích bảo mật cao hơn, sway/wlroots là hướng đi
kế tiếp cần đánh giá; i3-gaps/X11 là quyết định của chủ repo (đã ghi trong
PR/commit message). Xem mục §2.4b trong `SECURITY_LIMITATIONS.md`.

---

## 7. Gỡ lỗi

### 7.1. Cấu hình i3 sai mà không làm ISO "đỏ"

`i3` cố tình chạy tiếp với cấu hình lỗi: lỗi ngữ pháp → `i3-nagbar` ("You have an error in
your i3 config file!"), lệnh binding sai → thất bại im lặng khi bấm phím. Vì vậy mọi thay đổi
`Configs/.config/i3/config` phải qua lint trước khi commit:

```bash
python3 scripts/lint-i3-config.py    # exit 0 = không còn lỗi; exit 1 = in từng dòng lỗi
python3 -m unittest tests.test_i3_config -v
```

Hai lỗi đã sửa (`2026-11-22`):

| Dòng cũ | Lỗi i3 | Dòng mới |
|---|---|---|
| `bindsym $mod+d kill focused window` | `kill` chỉ nhận `[window\|client]`; lệnh sai nên **phím đóng cửa sổ không có tác dụng** | `bindsym $mod+d kill` |
| `hide_edge_borders vertical` + `smart_borders on` | `smart_borders` đã deprecated và bị bỏ kèm cảnh báo *"Both hide_edge_borders and smart_borders was used. Ignoring smart_borders as it is deprecated."* | `hide_edge_borders smart` (giữ đúng ý định ẩn viền khi chỉ một cửa sổ) |

Bảng ngữ pháp thường dùng (đã đối chiếu `parser-specs/`):

| Chỉ thị | Giá trị hợp lệ |
|---|---|
| `workspace_layout` | `default`, `stacking`, `stacked`, `tabbed` (**không** có `splitv`) |
| `hide_edge_borders` | `none`, `vertical`, `horizontal`, `both`, `smart`, `smart_no_gaps` |
| `smart_borders` | `on`/`no_gaps` — **đừng dùng cùng** `hide_edge_borders` (bị bỏ, sinh log) |
| `gaps` | `inner\|outer\|horizontal\|vertical\|top\|right\|bottom\|left <n>px` |
| `layout toggle` | danh sách các mode trong `{split, splitv, splith, stacking, stacked, tabbed, all, default}` |
| `kill` | không tham số, hoặc `kill window` / `kill client` |

### 7.2. Các lệnh chẩn đoán

```bash
# kiểm tra manifest i3 (không seed)
sudo /usr/local/lib/anitails-i3-seed --check
# báo cáo thành phần
kitty --single-instance -e /usr/local/bin/anitails-i3-doctor
# nhật ký session
journalctl -b
journalctl --user -b
```
