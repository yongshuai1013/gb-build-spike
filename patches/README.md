# M1 客體補丁清單（工作線 A）

CI 在 sync 後由 `scripts/apply-patches.sh` 冪等套用：先把受影響專案
checkout 回原版（並刪去新增檔），再依檔名序 `git apply`。目錄外不動樹。

## bionic

### 0001-gb-gate-core.patch — 構建掛鉤與手寫樁

| 檔案 | 改動 | 理由／行為差異 |
|---|---|---|
| `libc/Android.mk` | ARM `libc_common_src_files` 加 `arch-arm/bionic/gb_gate.c.arm` | compat 分發器進靜態與動態 libc 本體。GBROOT 未設時行為不變（見下）。 |
| `libc/tools/gensyscalls.py` | EABI 兩模板（default／long）換成 gate 版 | 模板是已入樹樁的生成源頭；改法與 0002 的產出逐字一致（僅檔頭註解差一行），日後重跑 gensyscalls 不會把 gate 洗掉。 |
| `libc/arch-arm/bionic/syscall.S` | EABI 分支加 gate 路徑 | `syscall(2)` 是繞過具名樁的通用入口（libcutils 的 ioprio_set 等走它），一併納管；`mode==2` 時走標籤 10 的原指令序列逐字版。非 EABI 分支不動。 |
| `libc/arch-arm/bionic/kill.S` | 函數頭加 6 行 gate 檢查 | kill 是手寫樁、無生成版；gate 開時先呼叫 `__gb_gate_fix_pid()` 把虛擬 pid 參數翻回真 pid（只動 r0，其餘原樣）。 |

### 0002-gb-gate-stubs.patch — 全部生成樁（173 個）

`libc/arch-arm/syscalls/*.S`：每個 EABI 樁在函數頭讀 `__gb_gate_mode`：

- `mode == 2`（GBROOT 未設定、已定案）：跳標籤 10，執行**原版指令序列
  逐字版**（含原 `stmfd/ldr r7/swi/ldmfd` 與 errno 尾）——透明性由此保證，
  emulator 基線回歸即驗此路。
- 否則：把 r0–r5 與棧上參數（long 模板）組成 8 槽參數陣列，呼叫
  `__gb_gate_pre(nr, args, &skip_result)`；按回傳 action 決定直通 svc
  （參數可已被改寫）或跳過 svc 取 skip_result；svc 後呼叫
  `__gb_gate_post(nr, args, result)` 可換返回值（如 getpid）。
  幀布局（20B 保存寄存器＋52B 本地塊）保持 `bl` 時 sp 8 位元組對齊。

與原版的差異：去掉 `.save/.fnstart/.fnend` unwind 指示（手寫樁 kill.S
本就沒有；影響僅為穿過樁的棧回溯資訊，功能無差）。

**刻意不改的兩個樁**（維持原版逐字節）：

- `__sys_clone.S`——clone 的 svc 在子線程以**另一個棧**返回，svc 後
  觸碰任何幀都是未定義行為；線程建立實際走手寫 `clone.S`（亦不改）。
- `vfork.S`——子行程 exec 前與父共享地址空間，分發器的簿記不安全。
  進程建立的虛擬化由 `fork()`（`__fork` 樁）承擔。

再生成工具：`scripts/regen-gate-stubs.py <bionic-dir>`（冪等，含跳過
清單與理由）。

### 0003-gb-gate-dispatcher.patch — compat 分發器本體（新增檔）

新增 `libc/arch-arm/bionic/gb_gate.c.arm`（ARM 模式編譯；`.arm` 後綴
是 bionic 既有慣例）。內容與處置表（對照 DESIGN-M1.md）：

- **總開關**：`__gb_gate_mode`（0 未決／1 開／2 關）。首次樁呼叫時以
  `environ` 解析 GBROOT：未設定→定案 2（其後樁走原版序列）；解析
  發生在 `environ` 未裝好之前不快取、回退直通，下次重試。
- **直通**：未列管的 syscall，pre/post 原樣放行（僅計數）。
- **路徑翻譯**：open／openat（絕對路徑）＋ access／chmod／chown／
  lchown／chdir／mkdir／rmdir／unlink／rename（雙參數）／link（雙）／
  symlink（僅 linkpath）／readlink／stat64／lstat64／truncate／mknod／
  statfs(64)／inotify_add_watch／faccessat／utimensat／renameat。
  例外不加前綴：`/proc`、`/sys`、`/dev/null`、`/dev/zero`、
  `/dev/urandom`、`/dev/random`。譯後超長回 `-ENAMETOOLONG` 不截斷。
  譯文緩衝為 16 槽環形緩衝（每槽 1024B），槽申請以 kernel cmpxchg
  helper（0xffff0fc0，ARMv5 可用）自旋鎖串行化。
- **裝置重定向**：`/dev/console`、`/dev/log/*` 靠路徑翻譯落 rootfs
  內一般檔案（rootfs 骨架預建，見 assemble-rootfs.sh），無專屬碼。
  `/dev/binder`：pre 直接以 raw svc 開宿主 `/dev/null` 交還並登記
  dummy fd（dup 家族在 post 補登記、close 時銷記）。
- **ioctl 假辦**（僅 dummy binder fd）：`BINDER_VERSION`
  （0xC0046209，GB binder.h 為 _IOWR）填 protocol version 7 回 0；
  `BINDER_WRITE_READ`（0xC0186201）進 pause 迴圈停泊（servicemanager
  在 binder_loop 存活；binder 傳輸未實作，M2 工作）；
  `BINDER_SET_MAX_THREADS`、`BINDER_SET_CONTEXT_MGR` 與其他請求一律
  回 0——後兩者是 DESIGN 表外補列：servicemanager 啟動即呼叫，
  在 /dev/null 上回 ENOTTY 會令其退出，與 M1「首批服務存活」判據
  直接衝突，故假辦。常數皆對 GB `linux/binder.h` 核實。
- **虛擬身份**：post 把 getpid 換成 `$GBVPID`；fork：pre（持 fork 鎖）
  預備下一個 vpid，子行程 post 認領、父行程 post 記 real↔virt 對照
  並**回傳真 pid**（DESIGN 未明定父回傳值；回真 pid 使 init 以
  fork 返回值 kill／wait 的既有邏輯零改動成立，對照表專供 pid
  參數翻譯）。getuid／geteuid post 回 0（gid 家族按 DESIGN 原文
  不動）。pid 參數翻譯：kill（含 kill.S 直呼）、setpgid、getpgid、
  getsid、wait4、waitid(P_PID)、ioprio_set(PROCESS)。
- **execve**：pre 以 raw svc 讀目標 ELF（不經樁，無遞迴）查
  PT_INTERP：無→僅路徑翻譯＋環境注入；有→改寫為 exec
  `$GBROOT/system/bin/gbexec`，argv' = {"/system/bin/gbexec",
  客體目標路徑, 原 argv...}。兩路徑皆重寫 env：去掉舊 GBVPID／
  LD_LIBRARY_PATH，注入 `GBVPID=<本行程 vpid>` 與
  `LD_LIBRARY_PATH=$GBROOT/system/lib:$GBROOT/vendor/lib`
  （宿主絕對路徑，linker 以 raw syscall 開檔、不經翻譯，必須如此）。
  **與 DESIGN 的偏差**：DESIGN 寫「改 exec linker 本體並以目標為
  其第一參數」——經查 GB 2.3.7 linker 源碼，`__linker_init` 把
  AT_PHDR／argv[0] 認定的映像當主程式、`main()` 為空殼，**沒有**
  以參數接收程式的支援（該能力是後世版本才有）。故改以靜態跳板
  gbexec（probes/gbexec.c）手工完成核心的另一半 exec：映射目標與
  linker（ET_EXEC，鏈結址 0xB0001000）→造 kernel 式初始棧
  （含 AT_PHDR／AT_PHNUM／AT_BASE／AT_ENTRY）→跳 linker `_start`。
  linker 本體零改動，行為意圖（動態客體程式由客體 linker 拉起）
  不變；力學已以手寫假 linker 本機 qemu 驗證（見 README M1-A）。
- **AF_UNIX 路徑翻譯**：bind／connect 的 sockaddr_un 絕對路徑同樣
  加前綴（`/dev/socket/*` 的 create_socket 與 property／logd 通道
  靠它落進 rootfs）；譯後 ≥108 字回 ENAMETOOLONG。
- **mount 等**：不攔截，回真實結果（DESIGN 原文）。
- 計數器 `__gb_gate_pre_calls`／`__gb_gate_handled` 供煙霧測試與
  後續診斷讀取。

已知限制（M1 接受）：fork vpid 計數器為行程內序號，跨行程不協調
（同 DESIGN 模型）；相對路徑不翻譯（靠 chdir 翻譯後客體 cwd
自洽）；symlink 內容（arg0）不翻譯，客體內建的絕對 symlink 目標
由宿主核心解析、屬已知缺口；exec scratch 緩衝全行程共用一份，
並發 execve 有競態（成功即換像、影響僅失敗路徑）。

## system-core

### 0001-ueventd-no-uevent-idle.patch

| 檔案 | 改動 | 理由／行為差異 |
|---|---|---|
| `init/ueventd.c` | `device_init()` 後若 `get_device_fd() < 0`：記 ERROR 並進 `pause()` 迴圈 | 原版在此情形 poll(-1) 立即回錯、`nr<=0 continue` 成 100% CPU 熱迴圈（不退出、也不工作）。改後服務存活待機、init 不重拉。uevent 正常時路徑逐字不變。加 `<unistd.h>` 供 pause 宣告。 |
| `init/devices.c` | `open_uevent_socket()` 的 `addr.nl_pid = getpid()` 改為 `0` | nl_pid=0 由核心指派真 pid，語義等價；原版在 getpid 被虛擬化（回 vpid）時 bind 必失敗。emulator（gate 關）行為不變。 |

### 核實後判定「不需補丁」兩項（附證據，勿再找）

1. **property 區去 ashmem**——GB 2.3.7 的 `init/property_service.c`
   `init_workspace()` 本就開一般檔案 `/dev/__properties__`
   （O_RDWR|O_CREAT→ftruncate→mmap MAP_SHARED→以唯讀 fd 重開→
   unlink），全程無 ashmem（ashmem 版 property 是 4.x 的事）。
   客戶端（bionic `system_properties.c`）由 env
   `ANDROID_PROPERTY_WORKSPACE` 取得 fd 後 mmap，一般檔案語義
   成立；libcutils 無 ashmem 專屬呼叫。gate 路徑翻譯自動把該檔
   落到 `$GBROOT/dev/__properties__`。**零補丁**。
2. **init 的 pid 1 假設**——通讀 `init/*.c`：無 `getpid()==1` 類
   硬檢查；init 以 fork() 返回值（真 pid，見上）追蹤子行程，
   wait／kill 自洽。子行程側 `setpgid(0, getpid())` 與 ioprio 的
   pid 參數由 compat 的 pid 翻譯兜住（getpid 雖回 vpid，
   setpgid／ioprio_set 的 pid 參數 pre 會翻回真 pid）。
   **零補丁**。
