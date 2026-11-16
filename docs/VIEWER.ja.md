# テストアプリ（viewer）説明書 — v0.3.1

[English](VIEWER.md)

`scripts/viewer.py` は、FPGA の HDMI 出力を PC で見ながら、FPGA の設定を
ボタンで変えるための Windows 用のアプリです。HDMI の映像は UVC キャプチャ
装置で取り込み、設定は Dock の USB デバッガの UART で送ります。

このアプリがなくても受信機は動きます。設定を変えたいとき、映り方を
確かめたいときに使ってください。v0.3.1 では、変えた設定は FPGA の
フラッシュに保存されるので、一度合わせればアプリなしで同じ設定で起動します。

## 用意するもの

| もの | 備考 |
|---|---|
| Windows PC | Windows 11 で確認 |
| HDMI キャプチャ装置（UVC） | 720p の入力に対応したもの。開発では "C8 USB3.0 Video" という名前で見える装置を使用 |
| Dock の USB-C ケーブル | Dock の USB デバッガ（書き込みに使うのと同じ端子）。2 つ目の COM ポートが FPGA の UART（1 Mbaud） |
| Python 3 | [python.org](https://www.python.org/) の版（tkinter と `py` ランチャーが入る） |
| numpy、pyserial、Pillow | `py -3 -m pip install numpy pyserial pillow` |
| ffmpeg | PATH の通った場所に置く。録画には libx264 入りのビルドが必要（[gyan.dev](https://www.gyan.dev/ffmpeg/builds/) の版など） |

キャプチャ装置がなくても、UART だけで設定の変更とステータスの表示はできます
（映像の部分に「no picture」と出ます）。HDMI モニターで映像を見ながら、
このアプリで操作することもできます。

## 起動

リポジトリ（リリースのソース zip を展開したもの）の直下にある
`viewer.bat` をダブルクリックします。必要なものがそろっているかを先に
確かめ、足りなければその内容を表示して止まります。

コマンドで起動する場合:

```powershell
py -3 scripts\viewer.py
py -3 scripts\viewer.py --device "C8 USB3.0 Video" --port COM4
py -3 scripts\viewer.py --list-devices      # キャプチャ装置の名前を一覧表示
```

| 引数 | 意味 |
|---|---|
| `--device 名前` | キャプチャ装置。省略すると "C8 USB3.0 Video" があればそれ、なければ最初の映像デバイス |
| `--port COMn` | FPGA の UART。省略（`auto`）すると Dock のデバッガの 2 つ目のチャンネルを探し、なければ COM4 |
| `--list-devices` | 映像デバイスの名前を表示して終了 |
| `--set first=14,act=736` | `R` に答えない古いビットストリーム用。FPGA にすでに入っている設定を伝える（v0.3.0 以降では不要） |

`viewer.bat` にも同じ引数を付けられます（`viewer.bat --port COM5`）。

## 画面

```
┌ Device  Port  View ───────────────────────────────────────────┐
│                                         │ Display             │
│                                         │ Genlock             │
│            HDMI の映像                   │ FM demodulator      │
│     （ウィンドウに合わせて拡大縮小）      │ Colour              │
│                                         │ Picture position    │
│                                         │ SDRAM / capture     │
│                                         │ Live status         │
├─────────────────────────────────────────┴─────────────────────┤
│ UART COM4 open | capture C8 USB3.0 Video 30.0 fps | settings … │
└────────────────────────────────────────────────────────────────┘
```

- **映像**: キャプチャ装置の映像を 1280×720 で取り込み、ウィンドウの大きさに
  合わせて表示します。
- **操作パネル**（右）: FPGA の設定をボタンで変えます（下の表）。
- **ステータスバー**（下）: UART の状態、キャプチャ装置と fps、録画中は経過
  秒数、今の設定。`settings from FPGA` は FPGA から読み出した値、`tracked` は
  アプリが送った内容から推定した値です。

### メニュー

| メニュー | 内容 |
|---|---|
| Device | キャプチャ装置を選ぶ。Refresh list で一覧を更新 |
| Port | UART を選ぶ。Auto は Dock のデバッガを自動で探す。Refresh list で一覧を更新 |
| View > Fullscreen (F11) | 全画面。Esc で戻る |
| View > Control panel | 操作パネルの表示・非表示 |
| View > Live status | ステータスを 1 秒ごとに読むかどうか |

ボードやキャプチャ装置を抜いて挿し直すと、アプリは自動でつなぎ直します
（キャプチャは 3 秒ごとに再試行）。

## 操作パネル

ボタンを押すと、対応する 1 文字を FPGA に送ります。キーボードで同じ文字を
押しても同じです（ウィンドウを選んだ状態で）。パネルの表示は、送るたびと
1 秒ごとに FPGA から読み出した値（`R`）で更新されます。

| グループ | 項目 | キー | 内容 |
|---|---|---|---|
| Display | Picture / Waveform | `P` / `W` | 画像 / 復調した 1 ラインの波形モニター。この項目だけは保存されず、起動時は常に Picture |
| | 4:3 / 16:9 stretch | `A` | 4:3（左右に黒帯、起動時）/ 16:9 に引き伸ばし |
| Genlock | Off — SDRAM field store (HDZero) | `g` | 出力は固定クロック、SDRAM を通す（起動時）。HDZero ゴーグルはこれ |
| | Porch lines — no SDRAM | `g` | 出力を入力に同期（フロントポーチのラインの長さを変える）。SDRAM を使わない |
| | Pixel clock — no SDRAM | `g` | 出力を入力に同期（ピクセルクロックの位相を動かす）。SDRAM を使わない |
| FM demodulator | 0 adjacent 〜 3 PLL slow | `m` | FM 復調の方式（起動時は 3） |
| Colour | Colour | `c` | 色のオン・オフ |
| | V invert | `v` | V の符号。色相が大きくずれるときに切り替える |
| | Saturation − / + | `z` / `a` | 色の濃さ 0.25 倍ずつ |
| | Hue − / + | `[` / `]` | 色相 11.25° ずつ |
| Picture position | First line − / + | `u` / `d` | 表示を始めるライン。画像の上下位置 |
| | Start − / + | `h` / `l` | 画像の左右位置、0.2 µs ずつ |
| | Field offset flip | `f` | インターレースの上下補正の向き。細い横線や文字が上下に揺れるときに切り替える |
| SDRAM / capture | Timing test (K) | `K` | SDRAM の読み出しタイミングのテスト。結果は Live status の SDRAM |
| | Invert clock + test (k) | `k` | SDRAM のクロックを反転してからテスト |
| | Snapshot (s) | `s` | 今の映像を PNG で保存（FPGA には送らない） |
| | Record (r) | `r` | 録画の開始・停止（H.264、30 fps の mp4。FPGA には送らない） |
| | Logic analyser C / S / B / G | `C` `S` `B` `G` | 開発用。生の IQ / シンボル / FM 検波出力 / 色信号を FPGA から取り込み、ファイルに保存 |
| | Read settings from the FPGA | `R` | FPGA の設定を読み直す |

`q` でアプリを終了します（録画中なら録画を閉じてから）。

Genlock の 3 つのボタンは、目的のモードになるまで `g` を必要な回数送ります
（`g` はオフ → Porch lines → Pixel clock → オフ の順に回ります）。

**設定の保存**: `P` / `W` 以外の設定は、最後に変えてから 2 秒後に FPGA の
フラッシュに保存され、次に電源を入れたときに戻ります。ビットストリームを
書き直しても残ります。アプリを閉じても設定は FPGA に残ります。

## Live status

FPGA の状態（`T`）を 1 秒ごとに読んで表示します。

| 行 | 表示の例 | 見方 |
|---|---|---|
| Signal | `OK  lines 253  h …` | ラインが 200 本以上、フィールドが 40 以上で緑の OK。VTX がないと赤の NO SYNC |
| Fields | `48/0.8s  synth 0  vsync 48` | 0.8 秒あたりのフィールド数（正常で 47〜48）。synth は同期が取れずに補ったフィールドの数 |
| Levels | `tip … black … gain …` | 同期の先端と黒のレベル、映像の振幅の補正 |
| Colour | `locked  burst …  │R│ …` | カラーバーストに同期していれば緑の locked。killed なら白黒で表示 |
| Receiver | `F3  5780 MHz` | 受信機のチャンネル。改変版の C5 ファームウェアと受信機リンクがあるときだけ。なければ no link report |
| Output | `pclk 74.1818 MHz  re-locks 0` | HDMI のピクセルクロックの実測値と、出力が同期し直した回数 |
| SDRAM | `pass  pos …  ckinv …  ok …` | 最後の SDRAM テストの結果。SDRAM モジュールがないときは FAIL（ゲンロックのモードでは問題なし） |

## よくあるつまずき

- **映像が真っ黒のまま**: FPGA を書き込んだ直後に、キャプチャ装置が HDMI を
  つかみ直さないことがあります。パネルで Waveform → Picture と一度切り替えるか、
  キャプチャ装置の USB を挿し直してください。
- **SDRAM モジュールがない**: 起動時（Genlock Off）は映りません。Genlock で
  Porch lines を選んでください。2 秒後に保存されるので、次からはそのモードで
  起動します。Off に戻すと、また映らなくなります。HDZero ゴーグルは Genlock の
  モードでは真っ白になります。
- **UART not connected**: Port メニューで Dock のデバッガの 2 つ目の COM ポートを
  選んでください。ほかのソフト（シリアルターミナル、書き込みツール）が同じ
  ポートを開いていると開けません。逆に、このアプリが開いている間は、ほかの
  ソフトからは開けません。
- **FPGA の書き込み**: アプリを開いたままでも書き込めます。書き込みの間は
  UART が一度切れ、終わると自動でつなぎ直します。
- **画像が左右や上下にずれる**: Picture position の First line と Start で
  合わせます。
- **色が変**: V invert を切り替え、Hue で合わせます。色が出ないときは Colour の
  行が locked になっているかを見てください。
- **Record で何も保存されない**: ffmpeg が libx264 なしのビルドです。

## 保存されるファイル

すべてリポジトリ直下の `captures/` に保存されます。

| ファイル | 内容 |
|---|---|
| `snap_HHMMSS.png` | スナップショット |
| `rec_YYYYMMDD_HHMMSS.mp4` | 録画 |
| `la_X_HHMMSS.bin` | ロジアナの取り込み（開発用） |
| `live.png` | 今の映像。1 秒ごとに上書き |
| `viewer_log.txt` | ログ |
| `viewer_cmd.txt` | ほかのプログラムからの操作用（下記） |

## ほかのプログラムからの操作（開発用）

アプリは UART を開いたままにするので、ほかのツールは
`captures/viewer_cmd.txt` に 1 行ずつ追記して操作します。結果は
`captures/viewer_log.txt` に書かれます。

| コマンド | 内容 |
|---|---|
| `key 文字列` | 文字を FPGA に送る |
| `cap C\|S\|B\|G パス` | ロジアナの取り込み |
| `snap パス` | 今の映像を保存 |
| `rec start [パス]` / `rec stop` | 録画の開始・停止 |
| `fm 0..3` | FM 復調の方式を設定 |
| `defaults` | 設定を読み直す（`R`） |
| `status` | ステータス（`T`）をログに書く |
| `device 名前` / `port 名前\|auto` | キャプチャ装置 / UART の切り替え |
