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
- **編譯在年代容器內**：Docker `ubuntu:10.04`（lucid）——GB 官方文檔的
  年代環境：gcc 4.4.3、GNU make 3.81、OpenJDK 6、Python 2.6，
  主機 32 位運行庫供 prebuilt 工具鏈（32 位二進位）使用。
  lucid 已 EOL，apt 源改指 `old-releases.ubuntu.com`。
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

## 驗證結論

（待首輪成功後回填：實際配方差異、總耗時、樹規模。）

## 目錄

- `.github/workflows/build.yml` — workflow 本體
- `scripts/sync-tree.sh` — runner 上拉樹＋記錄修訂號
- `scripts/build-tree.sh` — 宿主側 docker 啟動
- `scripts/in-container.sh` — 容器內裝年代環境＋降權
- `scripts/build-as-user.sh` — envsetup／lunch／全量 make
- `scripts/collect-report.sh` — 蒐集證據成 `report/` 並上傳
