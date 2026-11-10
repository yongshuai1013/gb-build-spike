# M1 設計：門頁改造版 GB 在真機（moto g51、未 root）由 App 拉起

目標判據：App 拉起客體 init → init 執行 init.rc → 首批服務存活；
App 內可見日誌、可匯出整包。不以 boot_completed 為 M1 線。

## 形態定調（真機 vs CI 探針的差異）

- 客體行程＝App 私有目錄內的原生 32 位 ARM 行程（同機 PaxVM 已實證
  GB 二進位可跑）。宿主 App targetSdk 28，使 app 私有目錄可 exec
  （Termux 同款政策）——rootfs 直接放 filesDir，不需 nativeLibraryDir 搬運。
- CI 探針原定的「固定 VA 門頁」在真機不成立（宿主無法往已 exec 的
  行程映射頁面）。門頁改為**客體內建 compat 層**：改造後的 bionic
  syscall 樁一律先進 compat 分發器 `__gb_gate()`，由它決定
  直通／翻譯／虛擬化／假辦。需宿主參與的少數呼叫才走 rootfs 內
  Unix socket（`dev/socket/gate`）連宿主 App 的 GateService。
  此即 twoyi／VMOS 客體合作層的形態。
- **總開關**：環境變量 `GBROOT` 未設定時，compat 完全透明（樁行為
  與原版逐字一致）——改造版樹因此仍能在 emulator 正常開機（基線回歸
  不破），gate 只在真機 App 形態下啟用。

## compat 分發器處置表（M1 子集）

- **直通**：絕大多數 syscall 原樣 svc（read/write 於真 fd、mmap、
  futex、clone/fork 本體、signal 等）。
- **路徑翻譯**：絕對路徑先加 `GBROOT` 前綴再直通。例外（不加前綴）：
  `/proc`、`/sys`（宿主真身，唯讀使用）、`/dev/null`、`/dev/zero`、
  `/dev/urandom`、`/dev/random`（宿主真身、App 可開）。
  翻譯後路徑長度超限回 ENAMETOOLONG，不靜默截斷。
- **裝置重定向**：
  - `/dev/console` → `$GBROOT/dev/console`（一般檔案，O_RDWR 開，
    init 的 std fd dup 到它；宿主 tail 此檔＝客體主控台）。
  - `/dev/log/{main,radio,events,system}` → `$GBROOT/dev/log/<name>`
    一般檔案 O_APPEND（GB logd_write 逐訊 open/write/close，檔案語義成立；
    宿主 tail ＝客體 logcat）。
  - `/dev/binder` → 回一個 dummy fd（/dev/null），且 ioctl 假辦（見下）。
- **ioctl 假辦**（僅對 dummy binder fd）：`BINDER_VERSION` 回成功並
  填 GB 期望的 protocol version；`BINDER_WRITE_READ` 令呼叫線程
  睡眠等待（pause 迴圈）——servicemanager 因此停在 binder_loop 存活，
  但 binder 傳輸本身未實現（M2 工作，README 須明說，不得宣稱可用）。
- **虛擬身份**：`getpid()` 回 env `GBVPID`（啟動器給 init=1）；
  `fork()` 包裝：父行程在 fork 前把下一個 vpid 放進全域，子行程分支
  領取為己用，父行程記 real→virtual 對照；`execve()` 包裝把當前
  vpid 寫進新 env `GBVPID` 傳承。`getuid()/geteuid()` 回 0
  （客體內部權限判斷用；真實檔案存取仍是宿主 App uid）。
  fork vpid 分配以簡單鎖串行化；多線程並發 fork 的競態列已知限制。

- **exec 動態連結處理**：guest 動態二進位的 PT_INTERP 是客體絕對
  路徑 `/system/bin/linker`，真機內核解析必失敗。`execve()` 包裝：
  先以翻譯後路徑開目標檔讀 ELF，若有 PT_INTERP，改 exec
  `$GBROOT/system/bin/linker` 並把目標作為其第一參數（GB linker
  支援以程式路徑為參數執行），同時確保 env 帶
  `LD_LIBRARY_PATH=$GBROOT/system/lib:$GBROOT/vendor/lib`。
  init 本人是靜態連結，不受影響；此包裝位於呼叫方 libc（含 init 的
  靜態 libc），故 init 拉起所有動態服務都走此路。
- **mount 等無權操作**：不攔截，回真實 EPERM——GB init 對 mount
  失敗僅記錄續行（以源码為準，WS-A 核實）；若某處失敗是致命的，
  改 init 源码跳過並逐項記錄，不在 compat 層偽造成功。

## 客體源码補丁（system/core 等，與 bionic 補丁分開列帳）

1. **property 區去 ashmem**：`init/property_service.c` 建 property 區
   時改開一般檔案（路徑經翻譯落 `$GBROOT/dev/__properties__`）、
   ftruncate 到原 PA 大小再 mmap(MAP_SHARED)；`libcutils/properties.c`
   客戶端本就開同路徑 mmap，一般檔案語義成立，不需改（WS-A 核實
   是否有 ashmem 專屬 ioctl 呼叫，有則一併補丁）。
2. **init 的 pid 1 假設**：WS-A 讀 `init/init.c` 核實；有硬性
   getpid()==1 檢查則改為接受 GBVPID 虛擬身份（compat getpid 已回 1，
   若檢查走 libc getpid 即自動通過；若有直接 syscall 的，一併記錄處理）。
3. **ueventd 無 uevent 源**：netlink uevent socket 在沙盒預期 bind
   失敗；補丁：socket/bind 失敗時不退出，改進 idle 等待（服務存活、
   init 不重拉）。coldboot 的 mknod 失敗維持原樣記錄（不偽造）。
4. **init.rc 原則上不刪改**；若個別服務令 init 主迴圈受阻，
   先以 log 證據提出，再逐項記錄理由後才動。

## 宿主 App

- 殼：單一 Activity——狀態行、啟動／停止鈕、即時日誌區（tail
  `$GBROOT/dev/console`、`dev/log/*`、`gate.log` 與啟動器自身 log）、
  匯出鈕（打包 filesDir 內 rootfs 關鍵日誌＋App log 成 zip 放
  Download 並可分享）。
- 啟動器（Java ProcessBuilder 即可，不需 JNI）：首啟解壓 assets
  `rootfs.tar.gz` → `filesDir/gbroot`（版本戳記比對，變更才重解）；
  設 env `GBROOT`、`GBVPID=1`、`GBGATE=1`；exec `gbroot/init`，
  cwd=gbroot；init 的 stdout/stderr 由 ProcessBuilder 重定向 append
  到 `filesDir/logs/launcher.log`。宿主自身 log 同步鏡像一份到
  Download 目錄（比照 PaxVM 日誌觀：檔案管理員可見）。
- GateService（前台 Service）：管 init 行程生死（啟動、監看退出、
  停止時整樹清理）；在 `$GBROOT/dev/socket/gate` 開 LocalServerSocket，
  M1 協議先做 PING→PONG 與 CONSOLE 行收錄（客體 compat 暫以檔案為
  主通道，socket 為已就位接口，README 明說 M1 的實際分工）。

## 構建與交付管線

- `patches/` 存客體補丁（bionic／system-core 分檔），CI 在 sync 後
  先把受影響專案 checkout 回原版再套補丁（冪等），目錄外不動樹。
- 新 workflow：gate 構建（補丁→全樹 make→反組譯抽驗樁→qemu-user
  gate 煙霧→產出 rootfs.tar.gz artifact）與 app 構建（取 rootfs
  artifact→Gradle 打包→長期金鑰簽名→APK artifact）。金鑰：專案
  專用 PKCS12，備份於倉外 `~/workspace/gb-build-spike-keystore-backup/`
  （權限 600），CI 以 GitHub Secrets 注入。
- rootfs 組裝：out 的 `root/`（ramdisk 內容）為根，疊 `system/`，
  建空 `data/`、`dev/log` 等骨架；打包時記錄檔案清單。

## 實作註記（WS-A，2026-11-10，以 GB 2.3.7 樹內源碼逐項核實）

1. **execve／linker（偏差，重要）**：本文假設「GB linker 支援以程式
   路徑為參數執行」——查 `bionic/linker/linker.c`：`__linker_init`
   無條件把 AT_PHDR／argv[0] 認定的映像當主程式鏈結、`main()` 是
   空殼，全文無 argv[1] 處理，該能力在 2.3.7 **不存在**。改實作：
   execve 包裝改寫為 exec 靜態跳板 `/system/bin/gbexec`
   （`probes/gbexec.c`），由它映射目標與 linker（ET_EXEC@0xB0001000）、
   造 kernel 式初始棧（AT_PHDR／PHNUM／BASE／ENTRY）後跳 linker
   `_start`。linker 本體不改；行為意圖不變。力學已本機 qemu 以手寫
   假 linker 驗證（造棧被正確讀取）；真 GB linker 全鏈路由 CI
   煙霧的 exec_dynamic 項作證據（非首輪門檻，見 patches/README）。
2. **property 區（核實免補丁）**：2.3.7 的 `init_workspace()` 本就
   用一般檔案 `/dev/__properties__`（open+ftruncate+mmap+重開唯讀
   fd+unlink），無 ashmem；客戶端經 env fd mmap，語義成立。
   本文第 1 項補丁取消，證據見 patches/README.md。
3. **init pid 假設（核實免補丁）**：init 無 getpid()==1 硬檢查；
   fork 父回傳值定為**真 pid**（本文未明定），init 追蹤／kill／wait
   零改動；子行程 setpgid／ioprio 的 pid 參數由 compat 翻譯兜底。
4. **binder 假辦補列**：除 VERSION／WRITE_READ 外，
   SET_MAX_THREADS／SET_CONTEXT_MGR（及 dummy fd 上其他 ioctl）
   一律回 0——servicemanager 啟動必經，於 /dev/null 回 ENOTTY 會
   令其退出，牴觸 M1 存活判據。常數對 GB binder.h 核實
   （VERSION 為 _IOWR 0xC0046209、protocol 7）。
5. **樁的例外**：`__sys_clone` 與 `vfork` 兩樁維持原版（svc 後棧／
   地址空間語義使 svc 後簿記不安全）；線程 clone 本走手寫 clone.S。
6. **AF_UNIX 路徑**：bind／connect 的 sun_path 納入路徑翻譯
   （本文處置表未明列；`/dev/socket/*` 通道成立的前提）。
