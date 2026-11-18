# Desktop Icon Billiards for macOS

可以在 Mac 上玩的原生撞球原型，支援 macOS 13 以上。球面使用本機 App 或選取資料夾中的檔案圖示，有六個球袋、碰撞、反彈、蓄力擊球、計時與清台結算。

這個版本位於 [clark970417-eng/desktop-icon-billiards](https://github.com/clark970417-eng/desktop-icon-billiards) fork，由 Swift 和 AppKit 實作。原作者 [LXG 的 Windows 版](https://github.com/liuxiaogang-com/desktop-icon-billiards) 保留在專案根目錄；以下操作說明適用於 Mac 原型。

## 啟動

取得已建置的 `.app` 後，雙擊 `Desktop Icon Billiards.app` 即可啟動。這是開發原型，使用本機 ad-hoc 簽章，尚未經 Apple Developer ID 簽署或公證。從網路下載的版本可能需要在 Finder 中按右鍵選「打開」，或在系統設定的「隱私權與安全性」確認開啟。

## 玩法

1. 移動滑鼠，指定白球的出球方向。
2. 球靜止時，按住左鍵蓄力，鬆開擊球。力度在 0% 和 100% 之間循環，1.5 秒升滿，再用 1.5 秒降回。
3. 把所有圖示打進球袋完成一局。白球落袋後會重新放回；需要手動擺球時，點擊球台空位。

| 按鍵 | 動作 |
| --- | --- |
| `R` | 重新開始 |
| `G` | 切換瞄準輔助線 |
| `Space` | 暫停或繼續 |
| `Esc` | 離開遊戲 |
| `⌘Q` | 結束 App |

點擊「桌面模式」可切換為透明遊戲視窗，點擊「視窗模式」切換回來。圖示來源預設為本機 App；點擊「選取資料夾…」可換成桌面或其他資料夾中的圖示。每局使用 15 顆圖示，資料夾少於 15 個項目時會重複補足。若系統詢問資料夾存取權限，由你決定是否允許。

切換到其他 App 或讓遊戲失去焦點時，已開球的球局會自動暫停，並取消尚未完成的蓄力。回到遊戲後，按 `Space` 或「繼續」恢復。

## 圖示與隱私

遊戲只在自己的視窗內繪製圖示。選取資料夾時，讀取項目名稱與系統圖示，不修改、移動、刪除或開啟那些檔案，也不更改 Finder 的圖示位置。原型沒有排行榜、更新連線或遙測，不上傳資料夾內容或遊戲成績。

目前的桌面模式是置於其他視窗上方的透明遊戲視窗，遊戲開啟時會接收該區域的滑鼠操作，Finder 桌面仍保留在原位。多螢幕、原生桌面圖示的起始位置，以及正式發行的簽署與公證尚待後續整合。

## 從原始碼建置

需要 Apple 的 Xcode Command Line Tools（含 Swift 5.9 以上）。首次安裝可執行 `xcode-select --install`。

在專案根目錄執行：

```sh
bash macos/check.sh
bash macos/build.sh
open "macos/dist/Desktop Icon Billiards.app"
```

腳本會產生本機架構的 App，以及 `macos/dist/DesktopIconBilliards-0.1.0-macOS-<架構>.zip`。App 內附原專案的 MIT 授權。

要同時包含 Apple Silicon 與 Intel 執行檔：

```sh
bash macos/build.sh --universal
```

Universal 建置需要所用 macOS SDK 支援 `arm64` 與 `x86_64`，完成後可用 `lipo -archs "macos/dist/Desktop Icon Billiards.app/Contents/MacOS/DesktopIconBilliards"` 檢查架構。單一架構的本機測試不代表已在另一種 Mac 實機驗證。

`check.sh` 直接編譯並執行獨立的撞球模型檢查，只有 Command Line Tools 的 Mac 也能使用。安裝完整 Xcode 並將其設為目前的開發工具後，也可執行 XCTest 套件：

```sh
swift test --package-path macos
```

開發時可直接執行 `swift run --package-path macos DesktopIconBilliards`。模型測試涵蓋碰撞、袋口、白球重置與時間狀態；App 的滑鼠操作和 macOS 視窗行為仍需實際操作驗證。

## 授權與原作

原專案為 [liuxiaogang-com/desktop-icon-billiards](https://github.com/liuxiaogang-com/desktop-icon-billiards)，作者 LXG。Mac 原型延續桌面圖示撞球的玩法，並保留原專案的 [MIT License](../LICENSE) 與圖示來源。本機 App 圖示由 macOS 在執行時取得，不包含在原始碼或發行套件內。
