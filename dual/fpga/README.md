# C5VRX ×2 → Tang Primer 25K → HDMI 720p FPGA ロジック（第1版・白黒）

XIAO ESP32-C5（C5VRX）2台の 6bit 映像を受けて SDRAM に貯め、1280×720p で HDMI に出す。表示は2種類で、Dock の **S1** を押すたびに切り替わる。

- **ダイバーシティ**: 2台のうち画質の良い方を 960×720 で表示する。電源を入れた直後はこちら。
- **2画面**: 左に A、右に B を、それぞれ 640×480 で表示する。

第1版は**白黒**。カラーの復調は次の段階で足す。SDRAM には色差の場所も確保してあるので、構成は変えずに足せる。

## 状態

| 項目 | 状態 |
|---|---|
| シミュレーション（Verilator） | 合格。NTSC / PAL、ダイバーシティの自動切替、S1 で2画面、TMDS 符号の検算、SDRAM のタイミング検査（違反 0） |
| 回路規模（Yosys で見積もり） | LUT 約 3,000＋加算器 約 1,800、FF 約 1,400、BSRAM 12 個、乗算器 4 個前後。GW5A-25 の 1/4 程度 |
| Gowin IDE での合成・配置配線 | **未実施**（この環境に Gowin のツールがないため）。最初のビルドでエラーが出たら、そのまま貼ってください |
| 実機 | 未確認 |

シミュレーション結果（`sim_results/`）:

| ファイル | 内容 |
|---|---|
| `ntsc_diversity_A.png` | ダイバーシティ表示。B に雑音があるので A（左上の四角が緑）を表示している |
| `ntsc_diversity_B.png` | 途中で A を雑音だらけにすると、B（四角がマゼンタ）に自動で切り替わる |
| `ntsc_dual.png` | S1 を押した後の2画面表示（雑音の多い A が左、B が右） |
| `pal_diversity_B.png` | B を PAL にした場合 |

## 構成

```
XIAO-A ─┐ 150MHz で         同期分離・輝度   1ライン      SDRAM（32MB）
        ├ オーバーサンプリング → 640画素/ライン → バッファ ─→ 受信機ごとに
XIAO-B ─┘ (cvbs_os_rx)      (cvbs_decode)    (chan_buf)   フィールド3面
                                                             │
HDMI ← TMDS 符号化 ← 720p 表示・拡大・選択 ← ライン読み出し ←┘
       (tmds_enc)    (display)              (sdram_fb)
```

- **クロック**: 50MHz を PLL で VCO 750MHz にし、そこから 375MHz（HDMI シリアル）と 150MHz（受信）を作る。375MHz を 1/5 にした **75MHz で、SDRAM・処理・画素出力を全部動かす**。720p の標準 74.25MHz ではなく 75MHz（約 60.6Hz）になるが、Sipeed の NESTang と同じ設定。
- **受信**: C5VRX はクロック線を出さないので、150MHz（7.5倍）で取り込む。データが変化した位置からサンプル点を合わせる（PLL 方式）。
- **同期分離**:
  - 同期パルスを幅で H 同期、等化パルス、垂直同期に分ける。
  - 垂直同期のタイミングから、フィールドの奇偶と NTSC / PAL を自動で判定する。
  - 同期が欠けても、ライン周期で補う。
- **輝度**:
  - 5 タップの平均でカラー副搬送波を消す。
  - バックポーチで黒レベルを合わせる。
  - 有効期間 52.6µs を 640 画素に線形補間する。
- **インターレース**:
  - フィールドごとに1枚の絵として拡大して表示する（ボブ方式）。遅延が最小になる。
  - 下側のフィールドは半ライン下げて、上下に揺れないようにしている。
- **ダイバーシティの指標**: H 同期の底の揺れと、同期が欠けたラインの数（小さいほど良い）。出力1フレームごとに比べ、差が十分あるときだけ切り替える。
- **SDRAM**:
  - 受信機ごとに3面のバッファを持つ。書き込み中の面と表示中の面は重ならない。
  - 128 語のフルページバースト、CAS 2、75MHz で動かす。
  - SDRAM のクロックは ODDR で作った反転クロック。読み出しデータは立ち下がりで取り込む。

## ファイル

| パス | 内容 |
|---|---|
| `c5vrx_tang.gprj` | Gowin IDE のプロジェクト |
| `impl/project_process_config.json` | ビルド設定。Sipeed nestang-25k と同じで、SDRAM が使う兼用ピン（MSPI/CPU/I2C/SSPI）を通常の I/O にする |
| `src/c5vrx_tang_top.v` | トップ（PLL、CLKDIV、ODDR、IOBUF、OSER10、ELVDS） |
| `src/c5vrx_core.v` | 本体の接続。ベンダーのプリミティブを使わないのでシミュレーションできる |
| `src/cvbs_os_rx.v` / `cvbs_decode.v` / `chan_buf.v` / `sdram_fb.v` / `display.v` / `tmds_enc.v` / `button.v` | 各ブロック |
| `src/c5vrx_tang.cst` / `.sdc` | ピン配置（基板 rev A に合わせてある）とクロック制約 |
| `sim/` | テストベンチ、C5VRX の模擬信号源、SDRAM モデル。`./sim/run_sim.sh`（PAL は `./sim/run_sim.sh pal`）で実行 |

## ビルドと書き込み

1. Gowin IDE（教育版 V1.9.9 以降）で `c5vrx_tang.gprj` を開く。
2. デバイスが GW5A-LV25MG121 になっていることを確認する。
   - Sipeed の例と同じ型番（`…NES`）にしてある。
   - 手元の IDE で選べない場合は、Project → Configuration で 25K の型番を選び直す。
3. Project → Configuration → Place & Route → Dual-Purpose Pin で、次の4つに印を付ける（SDRAM と 50MHz クロックが兼用ピンを使うため）: Use SSPI as regular IO / Use MSPI as regular IO / Use I2C as regular IO / Use CPU as regular IO
4. Run All を実行すると、`impl/pnr/c5vrx_tang.fs` ができる。
5. Gowin Programmer か `openFPGALoader -b tangprimer25k impl/pnr/c5vrx_tang.fs` で書き込む。
   - フラッシュに書くときは `-f` を付ける。

## 画面の見方

| 表示 | 意味 |
|---|---|
| 左上の四角が緑 | A を表示中（2画面ではそれぞれの受信機が正常） |
| 左上の四角がマゼンタ | B を表示中（ダイバーシティ） |
| 左上の四角が赤、背景が濃い紺 | その受信機の信号が 40ms 以上来ていない |

## 実機で確認・調整する点

1. **SDRAM の読み出しタイミング**（`sdram_fb.v` の `RD_TAP`、既定 3）
   - 画像に細かいノイズが乗る、または 1 画素ずれた縞が出るときは、2 か 4 に変える。
   - 75MHz で、読み出しデータを立ち下がりで取り込む前提で計算した値。
2. **画面の位置**（`cvbs_decode.v` の `H_ACT0` / `V_ACT0`）
   - 左右・上下が切れる、または黒い帯が出るときに調整する。
   - C5VRX の実際の出力タイミングは、まだ測っていない。
3. **フィールドの上下**（`display.v` の `BOB_SWAP`）
   - 細かい横線が上下に震えるときは 1 にする。
4. **ピン**: 基板 rev A のとおり。A は J4（右）、B は J5（中央）、HDMI は J6（左）。
   - 何も挿していない入力はプルダウンで 0 になり、「信号なし」と表示される。

## 次の段階

- カラーの復調: NTSC / PAL のバーストに同期した副搬送波で U/V を取り出す。乗算器の見積もりは `design/multiplier_budget.md` のとおり。
- 拡大の画質改善: ダイバーシティの 1.5 倍拡大を、最近傍から線形補間にする。
- 任意: C5VRX から出せるクロック線（OPT_CLK）を使う受信方式。
