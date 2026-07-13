# DEVLOG — Tcl_VonMises-stress-on-mutiple-step-load- (Max Stress tool)

> 🔄 **HANDOFF (2026-07-10):** Đọc khối này trước khi làm gì tiếp. Context đầy
> đủ hơn nằm ở memory `project_hv_tools_panel.md` + `reference_hv14_api.md`
> (đọc bằng Claude Code auto-memory, không phải file trong repo này).
>
> **Trạng thái:** bộ 2 tool TCL (Max Stress + Safety Factor) cho HyperView,
> gộp vào 1 panel `HVTools_Panel.tcl`. **Đang test thật trên máy user khác
> (F4213) qua HV14 và HV2022** — máy dev (Claude) KHÔNG có HV console, mọi
> API đều verify gián tiếp qua user paste screenshot console.
>
> **Nhánh làm việc: `feat/multi-window-summary`** (KHÔNG phải `main` — main
> chỉ có 1 commit gốc `188cbff`, toàn bộ 24 commit sau đều ở feature branch,
> chưa merge, đợi user duyệt xong mới merge).
>
> **File quan trọng nhất: `maxstress_lib.tcl`** — toàn bộ logic (không UI).
> `HVTools_Panel.tcl` = panel gộp 2 tab (Max Stress + Safety Factor), đây là
> file user thực sự dùng. `MaxStress_Panel.tcl` = panel đơn lẻ cũ, vẫn giữ
> nhưng không còn cập nhật tính năng mới (đã lệch với HVTools_Panel).
>
> **⏳ Đang chờ user test lại (chưa có xác nhận cuối):**
> 1. Fix animator-sync (commit `a056e88`) — `SetCurrentSimulation` không tự
>    vẽ lại viewport, phải sync `page GetAnimatorHandle` riêng. Đã áp cho
>    annotate + re-query.
> 2. Fix mới nhất `e8a126b` — annotate giờ nhảy thẳng vào **subcase GỐC**
>    (khớp angle trong CSV) thay vì derived case ẩn danh, để dropdown frame
>    hiện tên step thật (`Step10_Combustion/Angle_1454.99deg:`) — user tự
>    nhìn dropdown là biết đúng/sai, không cần tin console log nữa.
> 3. Legend TCL per-window (`e8a126b`'s sibling fix `4a3544e`) — thiếu
>    release `con`/`leg` khiến legend chỉ apply lên window 1 do "handle name
>    already exists" bị catch nuốt lỗi. Đã fix, chưa có xác nhận cả 8 window
>    ăn legend chưa.
>
> **Nếu account/máy đổi:** mở Claude Code tại thư mục repo này, đọc file
> này + `../Tcl_Safety-Factor-/DEVLOG.md` + `../HV_Tools_Panel/DEVLOG.md`
> (3 repo liên quan chặt). Push policy: **commit tự do, KHÔNG tự push** —
> chỉ push khi user gõ "push". Sau khi push 2 repo lib, PHẢI re-zip +
> push repo deploy `HV_Tools_Panel` (xem DEVLOG của repo đó).

---

## Kiến trúc

```
HVTools_Panel.tcl          ← panel gộp, user source cái này (hoặc hvtools_menu.tcl)
  ├── source maxstress_lib.tcl       (namespace ::MaxStress)
  └── source ../Tcl_Safety-Factor-/safetyfactor_lib.tcl  (namespace ::SafetyFactor,
        phải COPY file này vào cùng thư mục HVTools_Panel.tcl khi deploy)

maxstress_lib.tcl — API công khai:
  ::MaxStress::LoadAll modelFile resultFiles cols rows   — load N result vào N window
  ::MaxStress::ResetSession                              — sess New (File>New)
  ::MaxStress::RunExport selectionSets (outputDir)        — sweep max stress → Stress_Summary.csv
  ::MaxStress::MakeReport (outputDir) (groupCols)          — pivot CSV → Stress_Report.csv (thuần file I/O)
  ::MaxStress::RunAnnotate setID (outputDir)               — vẽ marker+note từ CSV lên mọi window
  ::MaxStress::QueryNodeValue winIdx nodeID angle          — re-query 1 giá trị (dùng cho bảng sửa)
  ::MaxStress::ApplyDisplay legendOn meshMode              — bật/tắt legend + display mode toàn window

hvtools_menu.tcl — đăng ký menu "Applications > Tools > HV Tools Panel"
  (Tk thuần, KHÔNG dùng hw API tạo menu — xem lý do ở mục Gotchas)
```

Panel `HVTools_Panel.tcl` có 4 phần: **0. Load** (chung) → tab **Max Stress**
/ **Safety Factor**, mỗi tab: 1.Export → 2.Annotate (+Legend TCL optional)
→ Options (size/màu/precision/datatype/legend/display) → 3.Results (lưới
block theo layout trang, mỗi block = 1 window, sửa Node ID/Angle rồi
Re-query lấy giá trị mới từ HV, ghi đè CSV).

## File output (nằm cạnh `maxstress_lib.tcl`, tức thư mục chứa panel)

- `Stress_Summary.csv` — nguồn sự thật: `WindowID,SetName,MaxNodeID,MaxStressValue_MPa,SimulationID,CrankAngle_deg,SimulationLabel`
- `Stress_Report.csv` — bảng pivot copy-paste Excel (nút "Make Report", đọc CSV trên, KHÔNG đụng HV)
- `maxstress_config.txt` — model path + layout + result paths của lần Load All gần nhất (chỉ prefill khi mở panel, KHÔNG auto-load)

## Gotchas đã giải (silent-fail kinh điển của HV TCL API)

1. **`page GetWindowHandle win N`** — N là **INDEX 1..GetNumberOfWindows**,
   KHÔNG phải ID từ `GetWindowIDList` (VD IDs `4 6 8 10...` nhưng index vẫn
   phải là `1 2 3 4...`).
2. **`page SetLayout code`** — code là **preset index của grid layout GUI**,
   KHÔNG phải số window (`SetLayout 8` từng ra layout 3-window!). Cách đo:
   click layout trên GUI rồi `page GetLayout` đọc mã thật. Đã confirm
   **4×2 = 19** trên HV14 (`LAYOUT_CODES` dict trong lib). Chưa đo mã khác.
3. **`model GetSelectionSetHandle`** với id không tồn tại → **KHÔNG báo
   lỗi**, trả về set rỗng (`GetLabel=""`, `GetSize=0`). Luôn resolve ID
   thật qua `model GetSelectionSetList` trước khi query.
4. **Data type label có padding nội bộ** — VD thật là `"1.  Endure_SF_A"`
   (2 space sau "1."), không phải `"1. Endure_SF_A"` (1 space). `SetDataType`
   nhận chuỗi sai **không báo lỗi**, `GetDataType` đọc ngược **còn echo y
   chang chuỗi sai** — nhưng contour không bind data (`con GetBinding` =
   `'null'`, query 0 rows). Fix: normalize-whitespace match với
   `rctrl GetDataTypeList` trước khi Set.
5. **Contour cần full apply recipe**, không chỉ `SetEnableState true`:
   phải kèm `page GetAnimatorHandle → SetCurrentStep` refresh +
   `clt SetDisplayOptions "contour"/"legend" true` + `clt Draw`.
6. **`rctrl SetCurrentSimulation` không tự vẽ lại viewport** (bug lớn nhất,
   phát hiện muộn 2026-07-10) — data pointer đổi đúng, dropdown frame
   selector hiện đúng tên, nhưng **hình vẫn giữ frame vẽ gần nhất**. Sau 1
   vòng Export (dừng ở frame cuối), Annotate set về frame đầu mà hình vẫn
   hiện frame cuối. Fix: sync `page GetAnimatorHandle → SetCurrentStep`
   SAU khi set simulation, TRƯỚC `clt Draw`.
7. **Measure (marker annotation) per-window** — `clt` gắn với `win` đang
   active lúc lấy handle; tạo measure ở clt của window A không hiện ở
   window B. Loop từng window phải re-grab `win/clt/model` MỖI VÒNG.
8. **Display-mode flags của measure mặc định TẮT HẾT trừ `scalar`** (với
   type "Nodal Contour") — phải bật tường minh `id` và tắt tường minh
   `scalar` (không phải mặc định off như các flag khác).
9. **`mea GetFontHandle`/`note GetFontHandle`**: KHÔNG được đặt tên handle
   là `font` — trùng lệnh Tcl/Tk built-in, lỗi "command already exists".
10. **Handle "already exists" là silent-fail nguy hiểm nhất trong toàn bộ
    dự án** — nếu quên `ReleaseHandle` một handle nào đó ở đầu vòng lặp
    window, lần grab thứ 2 fail (bị `catch` nuốt), và code phía sau **âm
    thầm thao tác trên handle của window trước đó**. Ca gần nhất: thiếu
    `con leg` trong list release → legend TCL chỉ apply window 1
    (`4a3544e`). Bài học: **method cleanup list dùng `foreach handle {...}`
    ở đầu MỌI proc thao tác window phải liệt kê ĐẦY ĐỦ mọi handle được
    grab trong proc đó**, không được thiếu 1 cái nào.
11. **Menu bar HyperView là Tk thuần** — build menu qua hw API
    (`sess GetMenuControllerHandle` → `CreateAppendMenu`/`InsertItem`)
    **THÀNH CÔNG theo return code nhưng GUI không bao giờ repaint**. Cách
    đúng: `<menu handle> GetExternalName` trả về **Tk widget path sống**
    (VD `.mainPulldowns.applications94.tools101`, số đổi theo session,
    KHÔNG hardcode) → `$path add command ...` bằng Tk thuần, hiện ngay.
    Xem `hvtools_menu.tcl`.
12. **File legend export từ GUI** (Edit Legend → Save) chỉ **định nghĩa**
    `proc ::post::LoadSettings {legend_handle}`, source xong phải **tự gọi**
    `::post::LoadSettings leg` mới áp dụng — không tự chạy khi source.

## Lịch sử commit (mới nhất trước, nhánh `feat/multi-window-summary`)

- `e8a126b` fix: annotate nhảy vào subcase GỐC (không phải derived case) để show đúng tên frame
- `4a3544e` fix: legend TCL chỉ apply window 1 — thiếu release `con`/`leg` mỗi vòng
- `a056e88` fix: annotate render sai frame — sync animator theo sim
- `e05b233` fix: chữ note đen (HV2022 mặc định trắng) + lộ lại nút Make Report (bug thứ tự pack Tk)
- `6d5ae3d` tweak: bỏ auto-load khi mở panel — chỉ prefill text đường dẫn
- `680403c` refactor: report tách khỏi export — Make Report đọc CSV thuần
- `9982c30` feat: Stress_Report.csv — bảng pivot copy-paste Excel
- `11671fa` fix: file odb thiếu → log + skip, không chết cả Load All
- `2e7c7ce` feat: nút Reset (New) + dọn model cũ có fallback (khi `GetModelList` không tồn tại)
- `92844fb` fix: gọi `::post::LoadSettings` sau khi source file legend GUI-saved
- `045685e` feat: ô Legend TCL optional cho Annotate (chỉ ảnh hưởng styling, không đụng CSV)
- `50481ce` feat: toggle Legend + dropdown display mode (Shaded/Mesh/Feature Lines) — Apply Display toàn window
- `cbeb2d0` → `44ee458` → `a186a79` tweak/feat: style note trắng (vị trí góc trái-dưới, padding né triad, "MAX:")
- `db31359` tweak: bỏ ô Load case khỏi tab SF (không cần thiết)
- `30b112a`, `ce980e4` feat: precision + data type/component droplist (cả 2 tab)
- `272027c`, `4a9c9ea` feat: bảng Results per-window dạng lưới theo layout + toggle note header
- `b8dd3e3`, `3cb185c` fix: `page SetLayout` là preset index không phải window count — đo được 4×2=19
- `86f1cd6`, `ff9fe41`, `2bce3cb` feat: menu-bar integration, panel gộp 2 tab, mục Load model+results

(24 commit kể từ base `188cbff`. Xem `git log --oneline` để đầy đủ.)

## Việc còn treo / chưa xác nhận

- 3 mục "⏳ Đang chờ user test lại" ở đầu file này.
- `page SetActiveWindow` dùng dò đoán (bọc catch, không lỗi nhưng chưa chắc
  có tác dụng thật — chưa có ai xác nhận rõ ràng qua console).
- Set "Pos1" từng biến mất khỏi `model GetSelectionSetList` trên 1 file
  FEMFAT test (id=1 xuất hiện 2 lần đều rỗng) — nghi do pool node/element
  tách riêng trong `GetSelectionSetList (pool)`, chưa dò lại.
- Mã layout preset ngoài 4×2=19 chưa đo (2×4, 3×3, 2×2...) — nếu cần, đo
  bằng `page GetLayout` sau khi click layout đó trên GUI, thêm vào
  `LAYOUT_CODES` dict trong `maxstress_lib.tcl`.
- Component list dropdown (`FetchComponentList`) dùng 3 biến thể gọi
  `GetDataComponentList` (signature chưa doc-confirm) — nếu cả 3 đều fail
  trên máy nào đó, combobox vẫn gõ tay được (fallback).
