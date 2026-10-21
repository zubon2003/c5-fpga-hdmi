# c5-fpga-hdmi

XIAO ESP32-C5 が GPIO に出している 4 ビット IQ（MODEM_DIAG Q4/I4）を
Tang Primer 25K（GW5A-25）で受け、FM 検波から NTSC デコードまで行って
HDMI に出す実験です。

## 現状: 720p でカラー映像を表示（2026-10-21）

- **カラー化**（`src/chroma.v`、`captures/hue_v_1x.png`）:
  - FM 検波の生の差分 d に 3.58 MHz の NCO を掛け、128 サンプルの移動和（CIC）で色信号を取り出す
  - バーストはライン毎に同期の後縁から 0.5〜2.5 µs で測る。NCO はバーストの位相の進みで周波数ロックし、
    基準ベクトル R はバーストを約 8 ライン平均したもの。R の向きを色相の基準、大きさを ACC に使う
  - U = -Re(M conj R)、V = Im(M conj R)。表示で V を反転したものが自然な色になった（NTSC の定義と一致）
  - 上下 2 ラインで色を平均（輝度からの偽色を打ち消す）、コアリング（|C| < 4 は 0）
  - 輝度は 22 サンプルの移動和（3.64 MHz にゼロ点）にして、色の網目模様を抑える
  - ラインバッファは 1 ライン 640 点、{Y, C}（C は U と V を交互）。表示で横 2 倍、BT.601 で RGB へ
- 途中で直した不具合（実機の内部状態と取り込みで特定）:
  - `pc <= (d1 * cs) >>> 4` は積が代入先の 13 ビットで切られる（Verilog の幅の規則）。色が副搬送波に追従しなかった
  - バースト窓を同期の前縁基準にしていたため、ヒステリシス（0.3 µs）入りの同期判定では窓が欠けた
  - 基準ベクトルの IIR で、連結 `{b16c, 3'b000}` が符号なし扱いになり発散した
  - VTX オフの間に雑音で黒レベルと同期の底を学習すると、しきい値が同期の底より下になって復帰しなかった。
    26 ms 水平同期がなければ学習をやり直す
  - 同期判定にヒステリシス（0.3 µs）。雑音のスパイクで垂直同期が切れてフィールドを取りこぼしていた
- UART コマンド（`scripts/viewer.py` のキーと同じ）: `P` / `W` 画像 / 波形、`u` / `d` 有効ライン、`h` / `l` 横位置、
  `f` フィールド補正、`c` 色、`v` V 反転、`a` / `z` 濃さ、`[` / `]` 色相、`T` 内部状態、`G` 色の内部信号の取り込み
- `scripts/viewer.py`: キャプチャ装置の映像をライブ表示し、キー操作を FPGA に送る。`captures/live.png` を毎秒保存し、
  `captures/viewer_cmd.txt` に書いたコマンド（`key`、`cap`、`snap`、`status`）を実行する
- 資源とタイミング: LUT 4958 / 23040、BSRAM 41 / 56、DSP 15 / 28。clk_iq の Fmax 87.9 MHz、clk_pixel 91.4 MHz
- ロジアナの深さは半分（16 BSRAM）に減らした: `C` 49 µs、`S` 410 µs、`B` / `G` 102 µs
- 既知の挙動: FPGA を書き込み直した直後、キャプチャ装置が真っ黒のままになることがある。表示モードを一度切り替えると戻る

## 720p でモノクロ映像を表示（2026-10-21）

- **C5 の GPIO の IQ から、FPGA だけで NTSC を復調し、1280×720p の HDMI にモノクロ映像を出せた**
  （`captures/pic6.png`、VTX の OSD の文字まで読める）
- `src/video_in.v`（IQ 側、84.375 MHz）:
  - 同期のしきい値は「同期の底と黒レベル（バックポーチ）の中間」。ラインごとの測定値を平均して使う。
    最初の版は「最小値から最大値の 1/4」で、OSD の白でしきい値が黒レベルより上がり、
    暗い部分を同期と誤検出して OSD の行が白い帯になった（`captures/pic5.png`）
  - パルス幅で水平同期（3〜8 µs）、等化パルス（1〜3 µs）、垂直同期（15 µs 以上）を区別。
    水平同期がなければ 1 ライン周期（5085 サンプル）ごとに補う
  - 垂直同期から 16 ライン目以降の 240 ラインを有効ラインとして取り込む
  - 黒レベル = バックポーチ、白 = 黒 + 同期の深さ × 2.5 として 0〜255 に正規化
  - 1 ラインの映像部分（同期の立ち下がりから 9.4 µs 後の 53.3 µs）を 1280 点にして、16 ライン分のバッファへ
- 720p 側: 入力の有効ライン 0 が書き終わったら出力フレームを開始（垂直帰線期間を最大 8 ライン延長して待つ）。
  入力の 1 ラインを 3 回表示して 720 ライン。第 2 フィールドは 1 出力ライン下げる（向きは未確認）
- UART の `P` で画像（既定）、`W` で波形モニター
- タイミング: clk_iq の Fmax 117.5 MHz、clk_pixel 104.2 MHz。BSRAM 51/56
- 未確認・未調整: 有効ラインの開始位置（上端に黒い帯が少しある）、フィールドの上下補正の向き、
  カラー（まだモノクロ）

## 720p 出力（2026-10-21）

- HDMI 出力を 1280×720p に変更（CEA VIC 4 のタイミング、1650×750）。ピクセルクロックは
  PLL の小数分周（1350 MHz / 3.625 / 5）で 74.48 MHz、規格の 74.25 MHz に対して +0.31 %、60.19 Hz
- 画面: 上 480 行が波形モニター（1 ライン 64 µs、20 MS/s で 1280 サンプル、200 px = 10 µs）、
  下に IQ 8 本の活動バーとリサンプラの票数のバー（`src/display.v`、3 段パイプライン）
- 実機確認: C8 USB3.0 Video（UVC キャプチャ）で 720p として表示されることを確認（`captures/hdmi720b.png`）
- タイミング: clk_pixel の Fmax 98.4 MHz（必要 74.48）、clk_iq 84.63 MHz（必要 84.375、余裕はほぼない）

## ステップ 2（IQ 簡易ロジアナ）

- HDMI（J6 の PMOD DVI）: 720×480p のテストパターン。下段に IQ 8 本の活動バーを表示
  （ビットごとの遷移回数を 15.5 ms ごとに集計、黄 = Q、シアン = I、橙/青 = 符号ビット）
- J4: IQ 入力 8 本。IDDR を使って 135 MHz の両エッジでサンプル（270 MS/s）
- UART（デバッガ、COM4、1 Mbaud）: `C` を送ると 65536 サンプル（242.7 µs）を取り込み、PC に送る
- BL616 の USB-UART ブリッジは実効約 27 kB/s しか通さず、超えた分を捨てる
  （実測 2026-10-21）。そのため 1 バイトごとに 50 µs 空けて送っている（約 3.3 秒）
- 資源: BSRAM 32/56、clk_5x の Fmax 175 MHz（必要 135 MHz）
- 実機確認（2026-10-21）: 未接続でのキャプチャが全サンプル 0 になることを確認済み
  （入力はプルダウン）

### 実測 1（2026-10-21、C5VRX-5 v5.0.332、F3、`captures/c5_first.bin`）

- 8 本とも信号あり（ピンごとの 1 の割合は 0.47〜0.51）。配線は正しい
- **GPIO の IQ は 80 MHz で更新されている**（遷移時刻の位相の揃い方 0.41、次の候補は 0.04）。
  FPGA のクロック基準では 80.0024 MHz（C5 と Dock の水晶の差、約 +30 ppm）。
  C5 の PARLIO RX は 40 MS/s で取り込んでいるので、FPGA は C5 の 2 倍のレートで IQ を受けられる
- 遷移は 12.5 ns 周期のうち約 6 ns の範囲に集まる。残り約 6 ns が安定区間（アイの開き）
- ピンごとの遷移位相の平均は 8.7〜10.5 ns の範囲で、ピン間のずれは約 1.7 ns
- 270 MS/s では 1 シンボルあたり 3.375 サンプルしかなく、選んだサンプルの前後が一致する割合は 0.79。
  クロックの差で位相が約 0.4 ms ごとに 1 シンボルずれるので、FPGA 側で位相を追従させる必要がある
- このときの IQ の振幅は小さかった（|z| の平均 1.2 セル）。VTX の有無は未確認

### 実測 2（2026-10-21、VTX オン、F3、`captures/c5_vtx.bin`）

- IQ は一定振幅の円になった（|z| の平均 2.83 セル、標準偏差 0.38）。FM キャリアを受けている
- `scripts/demod.py` で 80 MS/s にリサンプル（固定位相）→ 隣接サンプルの位相差で FM 検波 → 5 MHz の箱型 LPF
- **NTSC の水平同期が 4 本見えた**: 間隔 63.65 / 63.98 / 63.36 µs（NTSC は 63.56 µs）。
  同期の先端、バーストのあるバックポーチ、絵柄の傾斜、OSD の文字らしい細かい変化が波形に出ている
- PC 上での確認（243 µs、4 ライン分）。FPGA での連続処理はまだ

### 実測 3（2026-10-21、FPGA の位相追従リサンプラ、`captures/sym2.bin`）

- 入力を IDES8（337.5 MHz の両エッジ、675 MS/s、1 シンボルあたり 8.44 サンプル）に変更。
  生データでは 80 MHz への揃い方が 0.83（270 MS/s のときは 0.41）
- `src/iq_resampler.v`: 1 クロック（84.375 MHz）に 8 サンプルを受け、1 シンボルあたり 1 バイトを出す。
  バイト単位の Alexander 型位相比較、8 票で 1/64 サンプル動かす。ビット単位のモデルは `scripts/resampler_model.py`
- FPGA の出力 65536 シンボル（819 µs）を PC で FM 検波: IQ はきれいな円（|z| の平均 5.57、標準偏差 0.29）、
  **水平同期 13 本、間隔 63.52〜63.62 µs**（NTSC は 63.556 µs）、同期幅 4.84〜4.92 µs（NTSC は 4.7 µs）
- 注意: VTX がオフのときに取った `sym1.bin` はノイズのみ（入力側の状態で、リサンプラの問題ではない）
- 資源とタイミング: clk_iq（84.375 MHz）の Fmax 86.7 MHz で余裕は小さい

### 実測 4（2026-10-21、FPGA の FM 検波、`captures/both2.bin`）

- `src/fm_demod.v`: 位相 LUT（1 周 1024、`scripts/gen_phase_lut.py` で生成）→ 隣接差分 → 16 個の移動和
  （5 MHz にゼロ点）。1 MHz = 204.8
- モード `B` で FPGA の入力 IQ と出力 vid を同じ時刻で 16384 組取得し、`scripts/fm_model.py` で再計算:
  **16344 サンプル中、不一致 0**（VTX オフのノイズ入力 `both1.bin` と VTX オンの `both2.bin` の両方）
- `both2.bin` の vid に水平同期 3 本、間隔 63.49 / 63.54 µs。同期、バックポーチ、OSD の文字が見える
- HDMI の上 320 行に波形モニター（`src/scope_line.v`、同期でトリガ、1 ライン 63 µs）。
  clk_iq の Fmax は 84.46 MHz で、余裕はほぼない
- HDMI 出力を C8 USB3.0 Video（UVC キャプチャ）で取り込んで確認（`captures/hdmi3.png`）: 波形モニターに
  同期パルス、バックポーチ、絵柄の段差を持つ 1 ライン分の波形が出て、トリガ表示は緑。
  VTX が不安定なときは入力がノイズになり、波形も画面いっぱいに振れる（`hdmi1.png`、`hdmi2.png`）
- リサンプラの「早い」票が「遅い」票の約 2 倍なのは、C5 と Dock の水晶の差（約 30 ppm）を
  補正している分（モデルで、800 シンボルあたりの必要補正約 16 単位と票の差約 124 票 = 15 単位が一致）。
  位相は約 30 µs で合い、その後サンプル点はシンボルの中央（0.51〜0.52）に留まる

### 配線（XIAO ESP32-C5 → Dock J4）

J4 は 1/2 番 = +3V3、3/4 番 = GND、5〜12 番 = 信号です。
+3V3 同士は**つながない**でください（両方とも USB 給電）。GND は必ずつなぎます。

| J4 ピン | FPGA | XIAO | C5 GPIO | 内容 |
|---|---|---|---|---|
| 3 または 4 | GND | GND | - | 共通 GND |
| 5 | C11 | D0 | 1 | Q bit0 |
| 6 | C10 | D1 | 0 | Q bit1 |
| 7 | B11 | D2 | 25 | Q bit2 |
| 8 | B10 | D3 | 7 | Q 符号 |
| 9 | D11 | D10 | 10 | I bit0 |
| 10 | D10 | 裏面 MTDO | 5 | I bit1 |
| 11 | G11 | 裏面 MTDI | 3 | I bit2 |
| 12 | G10 | 裏面 MTCK | 4 | I 符号 |

裏面の MTMS（GPIO2）はフライホイールの同期出力に使われているので、つながないでください。

### 取り込み

```powershell
py -3.13 scripts\iqla.py capture --out captures\cap.bin   # 取り込みと解析
py -3.13 scripts\iqla.py analyse captures\cap.bin         # 保存済みファイルの解析
```

ピンごとの遷移レート、変化しない区間の長さの分布、更新周期の候補
（遷移時刻の位相の揃い方から推定）、Q/I の値の分布を表示します。

## ステップ 1（HDMI テストパターン、完了）

- 出力: 720×480p 59.94 相当（CEA VIC 2/3 のタイミング、ピクセルクロック 27.000 MHz、DVI モード、RGB フルレンジ）
- 絵: 75 % カラーバー、グレーランプ、白枠、毎フレーム動く白い四角
- TMDS エンコーダのアルゴリズムは、DVI 仕様の参照実装と 200 万シンボルで一致することを Python で確認済み
- 実機確認（2026-10-21）: SRAM 書き込みでテストパターンの表示を確認済み

### ビルドと書き込み

Gowin EDA Education 1.9.11.03（ライセンス不要）:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1
C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe --device GW5A-25A --run 2 --fsFile impl\pnr\c5_fpga_hdmi.fs
```

`--run 2` は SRAM（電源を切ると消える）、`--run 54` は外部フラッシュ（GW5A 用、消去・書き込み・照合、約 3 分）です。
デバッガは FT2232 互換として見えます（A = JTAG、B = UART の COM4）。

## 計画

0. 出力側: HDMI テストパターン（完了）
1. 入力側: FPGA で IQ 8 本を高速サンプルして UART で吐く簡易ロジアナ（更新レート、スキュー、波形の実測）（完了: 80 MHz 更新を確認）
2. 取り込んだ IQ を PC で FM 検波し、映像信号になることを確認（完了: NTSC の同期と絵柄を確認）
3'. FPGA 側の 80 MS/s 位相追従リサンプラ（完了: 819 µs 連続で NTSC の同期 13 本を確認）
4'. FPGA 内の FM 検波（完了: 実機でモデルとビット一致）
5'. 同期分離とモノクロ表示（完了: 720p で映像を表示）
6'. カラー化（完了: 実機で自然な色を確認）
3. FM 検波から CVBS までを RTL 化し、ソフトモデルとビット一致させる
4. 同期分離、フライホイール、モノクロ 480i → 480p ライン倍化 → HDMI
5. カラー（バーストに PLL を合わせる）

C5 側のファーム（ゲイン、AFC、チャンネル）は変えずに、FPGA は GPIO を並列に読むだけ、
という構成から始めます。

| PARLIO データビット | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| ESP32-C5 GPIO | 1 | 0 | 25 | 7 | 10 | 5 | 3 | 4 |
| 内容 | Q | Q | Q | Q 符号 | I | I | I | I 符号 |

## クレジット

This project adapts the ESP32-C5 MODEM_DIAG IQ GPIO routing (Q4/I4 lane
mapping and pin order) and the "C5 RF front end plus external DSP logic"
architecture research from [C5VRX](https://github.com/Twotoz/C5VRX) by
Twotoz and the C5VRX contributors (C5VRX-5 `main/rf.c`, C5VRX-4
`legacy/c5vrx4/RESEARCH.md`, "Wider architecture: C5 RF front end plus
external DSP logic"). Visit the [official C5VRX website](https://twotoz.github.io/C5VRX/)
for the original project and its Discord invite. See the source and license
notices for the applicable terms (C5VRX is GPL-3.0-only); this derivative is
not an official C5VRX release.

Tang Primer 25K Dock の PMOD/HDMI のピン配置と PLL の設定項目は、Sipeed の
[TangPrimer-25K-example](https://github.com/sipeed/TangPrimer-25K-example)
（`hdmi/svo`、commit 27c1737）を参考にしました。RTL は新しく書いたものです。
