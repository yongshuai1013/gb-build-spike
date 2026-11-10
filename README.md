# gb-build-spike

探針：在現代 GitHub Actions 上**全量編譯 AOSP `android-2.3.7_r1` 整棵系統樹**，
驗證 Gingerbread 構建流水線的可行性與確切環境配方。

動機：VMOS 式「自編改造客體」路線的第一個未知數，就是 GB 全樹在今天的 CI
基礎設施上到底編不編得通。單一二進位（init／libc）已由 PocketIDE 的
GingerVM 探針證明可編（釘版 Bionic `3f14ff34…`、system/core `838a24ac…`、
arm-eabi-4.4.3 工具鏈 SHA-256 `fe166ff8…`）；本探針驗的是整棵樹。

## 做法

- **拉樹在 runner 上**：`repo init -u https://android.googlesource.com/platform/manifest -b android-2.3.7_r1`，
  `repo sync -c`；已 sync 的樹以 `actions/cache` 緩存（key 含 branch），
  環境迭代不重拉全樹。
- **編譯在年代容器內**：Docker `ubuntu:12.04`（precise）——GB 年代文檔
  認可的環境：gcc 4.6、GNU make 3.81、OpenJDK 6、Python 2.7，
  32 位運行庫供 prebuilt 工具鏈（32 位二進位）使用。
  precise 已 EOL，apt 源改指 `old-releases.ubuntu.com`。
  （首選原本是 10.04，但 Docker Hub 的 `ubuntu:10.04` 映像仍是 manifest
  v2 schema 1、現代 Docker 拒收；12.04 是 schema 2 可拉。另注意 precise
  早期 multiarch 的 `:i386` -dev 套件會與 amd64 版衝突，容器腳本因此
  分組安裝：核心工具鏈＋32 位運行庫必裝，`:i386` -dev 組選裝。）
- 容器內以 root 裝環境，再降權到與 runner 相同 uid 的 `builder` 用戶編譯，
  保證緩存的樹在後續 run 仍可寫。
- 產品：`lunch generic-eng`（樹不提供時退 `full-eng`，實際用哪個記在報告裡），
  全量 `make`。

## 成功判據

- `make` 完成（rc=0）；
- artifact `gb-build-report` 內含：容器環境版本、`lunch` 結果、make 耗時、
  各關鍵專案的 checkout 修訂號、`out/target/product/generic/system/` 全樹
  清單（路徑＋大小），以及關鍵二進位存在性檢查：
  `root/init`、`system/bin/app_process`、`system/bin/dalvikvm`、
  `system/bin/servicemanager`、`system/lib/libbinder.so`、
  `system/lib/libandroid_runtime.so`、`system/lib/libandroid_servers.so`、
  `system/framework/services.jar`、`system/framework/framework.jar`、
  `system.img`（逐項列有無與大小）；
- 若產出 `system.img`，另存 artifact `gb-system-img`。

## 觸發

`workflow_dispatch` 手動觸發，或 push 到 `main`。

## 驗證結論（2026-11-10）

**結論：可行。** run 42744326975 全綠，`make` rc=0。端到端約 20 分鐘
（其中全量 `make -j4` 1100 秒），產出完整 `generic-eng` 系統樹。

### 確認的環境配方

- 宿主：GitHub `ubuntu-22.04` runner；樹以 `repo init --depth=1 -b
  android-2.3.7_r1`＋`repo sync -c` 拉取——淺樹 4.0 GB、cache 壓縮後
  1.9 GB（全歷史樹 33 GB，超過 cache 上限，不可用）。修訂號與釘版
  一致：bionic `3f14ff34dfbd00fcffb18b10a1a3e17e2cc5ebdf`、
  system/core `838a24ac661dfb5147dd584e6dc36dc74c61725e`。
- 容器：`ubuntu:12.04`（precise；10.04 映像是 manifest schema 1
  被現代 Docker 拒收）。apt 源改指 `old-releases.ubuntu.com`；
  套件分三組裝（precise 早期 multiarch 的 `:i386` -dev 會與 amd64
  衝突）：核心工具鏈組、32 位運行庫組、`:i386` -dev 選裝組。
  實測版本：OpenJDK 1.6.0_41、GNU Make 3.81、gcc 4.6.3、Python 2.7.3。
- 兩個關鍵坑：
  1. GB 的 host 工具以 `-m32` 編譯，需要 32 位**開發標頭**
     `libc6-dev-i386`（缺了報 `bits/predefs.h: No such file`）；
     32 位運行庫（`libc6-i386` 等）只夠 prebuilt 工具鏈跑，不夠編。
  2. host 編譯器墊片（不改 AOSP 源码）：`/usr/local/bin/g++` wrapper
     追加 `-fpermissive -Wno-error`、`/usr/local/bin/gcc` 追加
     `-Wno-error`。前者放行 gcc 4.6 對 4.4 年代 C++ 的新嚴格檢查
     （首例 `frameworks/base/libs/utils/RefBase.cpp`）；後者中和
     Ubuntu gcc 預定義 `_FORTIFY_SOURCE` 與 `-Werror` 模組
     （如 obbtool）的衝突。目標編譯器是 prebuilt arm-eabi-4.4.3，
     年代正確，不需墊片。

### 產出（out/target/product/generic/）

- `system/`：320 個檔案、共 64 MB（完整清單在 artifact 的
  `system-tree.txt`）。
- `system.img`：68,832,192 bytes（另存 artifact `gb-system-img`）。
- 關鍵二進位（全數存在）：

  | 檔案 | 大小（bytes） |
  |---|---|
  | root/init | 94,168 |
  | system/bin/app_process | 5,660 |
  | system/bin/dalvikvm | 5,508 |
  | system/bin/servicemanager | 9,880 |
  | system/lib/libbinder.so | 145,436 |
  | system/lib/libandroid_runtime.so | 512,320 |
  | system/lib/libandroid_servers.so | 61,552 |
  | system/framework/services.jar | 634,031 |
  | system/framework/framework.jar | 2,965,444 |
  | system.img | 68,832,192 |

### 迭代史（六輪，每輪一類問題）

1. `ubuntu:10.04` 映像 manifest schema 1 被 Docker 拒收 → 換 12.04。
2. apt 整批被 multiarch 衝突拖垮 → 分組安裝。
3. host 工具 `-m32` 缺 32 位標頭 → 補 `libc6-dev-i386`。
4. gcc 4.6 嚴格度（RefBase）→ g++ wrapper `-fpermissive`。
5. `_FORTIFY_SOURCE` 重定義＋`-Werror` → wrapper `-Wno-error`。
6. 全綠。

## 目錄

- `.github/workflows/build.yml` — workflow 本體
- `scripts/sync-tree.sh` — runner 上拉樹＋記錄修訂號
- `scripts/build-tree.sh` — 宿主側 docker 啟動
- `scripts/in-container.sh` — 容器內裝年代環境＋降權
- `scripts/build-as-user.sh` — envsetup／lunch／全量 make
- `scripts/collect-report.sh` — 蒐集證據成 `report/` 並上傳
- `.github/workflows/boot.yml` — 開機基線 workflow（手動觸發）
- `scripts/boot-tree.sh` / `scripts/in-container-boot.sh` / `scripts/boot-as-user.sh` — 開機基線三段

## 開機基線（未改造自編 GB 能否正常開機）

結論：**能，四項里程碑全過**。方法：探針一同批流程全量編出的未改造映像
（system.img／ramdisk.img／userdata.img），在同一個 Ubuntu 12.04 容器內以
SDK r12 emulator（dl.google.com `android-sdk_r12-linux_x86.tgz`）＋樹內 prebuilt
goldfish 內核 `prebuilt/android-arm/kernel/kernel-qemu` 啟動（成品
`ro.product.cpu.abi=armeabi` → 選非 armv7 內核）。成品指紋
`generic/generic/generic:2.3.7/GWK74/eng...:eng/test-keys`。

決定性一跑：run 42754645850（2026-11-10 04:15 UTC 觸發，head 13d00a8），
artifact `gb-boot-report`（id 13736410167）。里程碑（adb 輪詢時間軸）：

- 20s：adb device 上線，init.svc.servicemanager／zygote／bootanim 皆 running
- 31s：`sys.boot_completed=1`、bootanim stopped
- M1 init＋init.rc ✓（ps 有 /init 為 pid 1、init.svc.* 一排 running）
- M2 servicemanager＋zygote ✓（ps 實證 pid 27／32）
- M3 system_server ✓（ps pid 68；logcat `I/SystemServer: Entered the Android system server!`）
- M4 boot_completed ✓（logcat SurfaceFlinger `Boot is finished (13349 ms)`、Email 收到 BOOT_COMPLETED 廣播）

調用踩坑（皆 emulator 組合問題、非映像／客體問題，各一輪修好）：

1. run 42749100370：無 AVD 時 emulator 找不到 system 目錄直接退出 →
   設 `ANDROID_PRODUCT_OUT=<abs product out>`（AOSP 開發流）＋ `-sysdir` 同址。
2. run 42752130023：相對路徑的 `-system` 被 emulator 以 sysdir 為基準再拼一次、
   路徑雙倍前綴 → kernel 與三個映像一律傳絕對路徑；並預建 `~/.android`。
3. run 42754645850：全過（見上）。另：r12 的 `tools/emulator` 只是啟動器，
   本體 `tools/emulator-arm` 只依賴 glibc 家族，SDL/X11 運行庫非必要
   （workflow 內仍 best-effort 裝著備用）。

## M1-B：宿主 App＋APK 構建管線（工作線 B）

`app/` 是獨立寫的簡潔殼（不複製 PaxVM 源码），把自編 GB 客體在真機
（moto g51、未 root）由 App 拉起。設計見 `DESIGN-M1.md` 的「宿主 App」
與「構建與交付管線」兩節。

- 套件：applicationId `dev.gbguest.host`、versionCode 1、
  versionName `0.1.0-m1b`、minSdk 26、**targetSdk 28**（Android 只對
  target ≤ 28 的 App 允許從私有目錄 exec，這是 rootfs 直接放
  `filesDir/gbroot` 的政策前提，代碼與 build.gradle 皆有註解，勿調高）、
  compileSdk 34。
- 主畫面（MainActivity）：狀態行、啟動／停止鈕、即時日誌區、匯出鈕。
- GateService（前台 Service）：管 `gbroot/init` 行程生死（啟動、監看
  退出、停止時 destroy＋以 gbroot 路徑 best-effort 清整樹）；在
  `gbroot/dev/socket/gate` 開 filesystem LocalServerSocket，M1 協議：
  行 `PING` 回 `PONG`，其餘行作 `CONSOLE` 收錄進 `filesDir/logs/gate.log`。
  **M1 實際分工**：客體主通道是檔案（`dev/console`、`dev/log/*`），
  socket 是已就位的接口；binder 傳輸在 M1 未實現（DESIGN 定案），
  不得宣稱可用。
- 啟動流程：首啟把 assets 的 `rootfs.tar.gz` 解壓到 `filesDir/gbroot`
  （以 asset 的 SHA-256 作版本戳記存 `gbroot/.asset-sha256`，戳記
  不同才重解——CI 換入真 rootfs artifact 後自動觸發重解）；以
  ProcessBuilder 拉起 `gbroot/init`，env `GBROOT=<gbroot 絕對路徑>`、
  `GBVPID=1`、`GBGATE=1`，cwd=gbroot，stdout/stderr 合流 append 到
  `filesDir/logs/launcher.log`。
- 日誌區每秒 tail：`gbroot/dev/console`、`gbroot/dev/log/*`、
  `filesDir/logs/launcher.log`、`gate.log`、`host.log`。宿主 log
  （`filesDir/logs/host.log`）另同步鏡像一份到 Download 的
  `gbguest-host.log`（檔案管理員可見，App 死掉也還在）。

### 操作說明（真機）

1. 從 CI artifact `gb-host-apk` 下載 APK 安裝（與先前版本同簽名，
   可覆蓋裝）。
2. 開 App，允許儲存權限（Download 鏡像／匯出用）。
3. 按 **Start**：狀態行應依序出現 extracted → running；日誌區應看到
   客體 init 的輸出（佔位版會印 `[placeholder-init] booting` 與每
   5 秒一次的 heartbeat；真 rootfs 換入後是 GB init／init.rc 的日誌）。
4. 按 **Stop**：狀態行變 stopped，客體行程樹應被清掉。
5. 按 **Export logs**：把日誌（launcher/gate/host/status＋
   `gbroot` 內 `dev/console`、`dev/log/*`）打包成
   `Download/gbguest-logs-<時間>.zip` 並跳分享意圖，回傳時傳這個
   zip 即可。

### 構建管線（.github/workflows/app-build.yml）

checkout → 嘗試下載最近一次成功 gate-build（工作線 A）的
`gb-rootfs` artifact 替換 assets（**有真 artifact 優先**；拿不到
則用倉內佔位 `app/app/placeholder-rootfs/` 打成的 tar.gz，管線照樣
全綠）→ JDK 17＋Gradle 8.7 打 release → secrets 金鑰簽名 →
apksigner 驗簽＋指紋斷言＋aapt badging 檢查 → 上傳 artifact
`gb-host-apk`。

- 簽名：專案長期 PKCS12（alias `gbkey`），備份在倉外
  `~/workspace/gb-build-spike-keystore-backup/`（權限 600），
  **金鑰與密碼絕不入倉**。憑證 SHA-256 指紋：
  `49:91:7D:B4:A0:DE:56:DD:20:A5:2B:DC:6C:4C:D5:57:B3:A0:D4:2D:CE:20:A5:43:00:38:E7:35:09:B5:05:A0`，
  效期至 2076。
- Secrets 設置記錄（只記名稱，2026-11-10 已設並以 API 名單核實
  存在）：`GBKEY_P12_B64`（p12 的 base64）、`GBKEY_PW`（密碼）。

### 佔位 rootfs 說明

工作線 A 的真 rootfs 就緒前，assets 內是佔位版：一個假 `init`
（shell 腳本，印字＋寫 `dev/console`、`dev/log/main`＋每 5 秒
heartbeat，`GBROOT_ONCE=1` 時跑一拍即退）＋最小骨架，讓殼的
解壓／啟動／日誌／匯出全鏈可先驗證。換上真 artifact 後佔位即被
取代，不需改 App 代碼（戳記是 asset 內容雜湊）。
