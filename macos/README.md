# Desktop Icon Billiards for macOS

Mac 原型 v0.2.0，支援 macOS 13 以上。點擊「桌面開局」，就能把你桌面上的圖示收進球桌，用滑鼠瞄準、蓄力擊球；退出時，圖示會飛回原位，遊戲視窗隨後關閉。

這個版本位於 [clark970417-eng/desktop-icon-billiards](https://github.com/clark970417-eng/desktop-icon-billiards) fork，由 Swift 和 AppKit 實作。原作者 [LXG 的 Windows 版](https://github.com/liuxiaogang-com/desktop-icon-billiards) 保留在專案根目錄；以下操作說明適用於 Mac 原型。

## 啟動與桌面開局

取得已建置的 `.app` 後，雙擊 `Desktop Icon Billiards.app` 啟動。App 先顯示一般視窗，使用 15 個本機 App 圖示供你試玩；「選取資料夾…」也能載入其他資料夾的圖示，少於 15 個項目時會重複補足。

要使用真正的桌面圖示：

1. 點擊「桌面開局」。第一次使用時，macOS 可能詢問是否允許 App 控制 Finder；允許後，遊戲才會讀取桌面項目的圖示與位置。
2. 圖示從桌面原本的位置飛入球桌。桌面球局最多使用 45 個項目，不足 15 個時依實際數量開局，不重複補球。
3. 點擊「退出還原」、按 `Esc` 或 `⌘Q`，圖示會飛回開局時的位置，然後結束 App。

如果拒絕 Finder 權限，遊戲會保留原本的視窗與桌面。要重新允許，請開啟「系統設定 → 隱私權與安全性 → 自動化」，允許 Desktop Icon Billiards 控制 Finder，再按一次「桌面開局」。一般視窗試玩不會要求 Finder 自動化權限，也不需要螢幕錄製或輔助使用權限。

桌面球局以當前桌布的靜態圖片覆蓋原始圖示，再繪製可移動的遊戲圖示。原本的 Finder 檔案、圖示位置與設定始終保留；即使 App 當掉或被強制結束，覆蓋視窗消失後也會露出原桌面。

這是開發原型，使用本機 ad-hoc 簽章，尚未經 Apple Developer ID 簽署或公證。從網路下載的版本可能需要在 Finder 中按右鍵選「打開」，或在系統設定的「隱私權與安全性」確認開啟。

## 玩法

1. 移動滑鼠，指定白球的出球方向。
2. 球靜止時，按住左鍵蓄力，鬆開擊球。力度在 0% 和 100% 之間循環，1.5 秒升滿，再用 1.5 秒降回。
3. 把所有圖示打進球袋完成一局。白球落袋後會重新放回；需要手動擺球時，點擊球台空位。

| 按鍵 | 動作 |
| --- | --- |
| `R` | 重新開始目前球局 |
| `G` | 切換瞄準輔助線 |
| `Space` | 暫停或繼續 |
| `Esc` | 退出；桌面球局會先播放圖示歸位動畫 |
| `⌘Q` | 結束 App；桌面球局會先播放圖示歸位動畫 |

切換到其他 App 或讓遊戲失去焦點時，已開球的球局會自動暫停，並取消尚未完成的蓄力。回到遊戲後，按 `Space` 或「繼續」恢復。桌面球局開啟期間，遊戲視窗會接收主螢幕遊戲區域內的滑鼠操作。

## 目前限制

桌面球局只使用主螢幕可用區內的圖示，排除選單列與 Dock 所占的區域。Finder 超過 45 個桌面項目時，只讀取前 45 個；未入選的原始圖示在遊戲期間也會被桌布覆蓋，退出後一併重新顯示。其他螢幕的圖示不會加入球局。堆疊或分組桌面的顯示方式可能與 Finder 有差異，尚未完整支援。

桌布必須能透過 macOS 讀取為靜態圖片。動態或影片桌布只會使用可讀取的靜態圖片；若無法讀取，App 會顯示錯誤並保留一般視窗，請先選擇可讀取的圖片桌布後再試。遊戲不會截取螢幕來替代桌布。

桌面圖示與桌布在開局時讀取一次。遊戲期間若從其他地方新增、移除或重新排列桌面項目，遊戲圖示不會同步更新；原始桌面保留你所做的變更，下次「桌面開局」會重新讀取。

## 圖示與隱私

遊戲只讀取項目名稱、來源路徑、系統圖示與桌面位置，不修改、移動、刪除或開啟來源檔案，也不更改 Finder 的排列設定或系統桌布。圖示與位置只用於本機遊戲畫面，不會寫入原始碼或發行套件。原型沒有排行榜、更新連線或遙測，不上傳桌面內容或遊戲成績。

## 從原始碼建置

需要 Apple 的 Xcode Command Line Tools（含 Swift 5.9 以上）。首次安裝可執行 `xcode-select --install`。

在專案根目錄執行：

```sh
bash macos/check.sh
bash macos/check-desktop.sh
bash macos/check-session.sh
bash macos/build.sh
open "macos/dist/Desktop Icon Billiards.app"
```

腳本會產生本機架構的 App，以及 `macos/dist/DesktopIconBilliards-0.2.0-macOS-<架構>.zip`。App 內附原專案的 MIT 授權。

要同時包含 Apple Silicon 與 Intel 執行檔：

```sh
bash macos/build.sh --universal
```

Universal 封存檔為 `macos/dist/DesktopIconBilliards-0.2.0-macOS-universal.zip`。建置需要所用 macOS SDK 支援 `arm64` 與 `x86_64`，完成後可用 `lipo -archs "macos/dist/Desktop Icon Billiards.app/Contents/MacOS/DesktopIconBilliards"` 檢查架構。單一架構的本機測試不代表已在另一種 Mac 實機驗證。

三個檢查腳本可在只有 Command Line Tools 的 Mac 上執行：`check.sh` 驗證撞球模型，`check-desktop.sh` 使用產生的資料驗證桌面資料解析與座標換算，`check-session.sh` 用不顯示的視窗和測試資料驗證桌面球局流程。這些檢查不會向 Finder 讀取真正的桌面，也不會要求 Finder 權限。

安裝完整 Xcode 並將其設為目前的開發工具後，也可執行保留的 XCTest 套件：

```sh
swift test --package-path macos
```

開發時可直接執行 `swift run --package-path macos DesktopIconBilliards`。真實 Finder 權限、桌面顯示與滑鼠操作仍需實際操作驗證。

## 授權與原作

原專案為 [liuxiaogang-com/desktop-icon-billiards](https://github.com/liuxiaogang-com/desktop-icon-billiards)，作者 LXG。Mac 原型延續桌面圖示撞球的玩法，並保留原專案的 [MIT License](../LICENSE) 與圖示來源。本機圖示由 macOS 在執行時取得，不包含在原始碼或發行套件內。
