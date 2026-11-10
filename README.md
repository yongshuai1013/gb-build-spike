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
