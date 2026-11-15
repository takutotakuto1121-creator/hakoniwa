# 箱庭 (hakoniwa)

画面の中の小さな世界で、ニューラルネットの脳を持つ生き物たちが生まれ、食べ、戦い、増え、
世代を重ねて**誰も設計していない行動を自分で獲得していく**様子を眺める macOS アプリです。

「餌に向かう」「逃げる」といった行動ルールはコードのどこにも書かれていません。
決めているのは物理・代謝・感覚器・環境だけで、行動はすべて脳の重みの進化から生まれます。

## 動かし方

macOS 15 以降、Apple Silicon、Xcode(Swift 6)が必要です。

```sh
scripts/build-app.sh          # build/Hakoniwa.app ができる
open build/Hakoniwa.app
```

### 操作

| 操作 | 内容 |
|---|---|
| ドラッグ / スクロール / ピンチ | 移動 / ズーム |
| クリック / ダブルクリック | 個体を選択 / 追尾 |
| スペース | 一時停止・再開 |
| 1〜5 | 速度(1×, 4×, 16×, 64×, 最大) |
| F / Esc | 追尾 / 選択解除 |

## ヘッドレス実行

画面なしで高速に進化させ、統計を確認できます。

```sh
swift build -c release --product hakoniwa-cli
.build/release/hakoniwa-cli run --seed 1 --hours 4 --save world.hkw   # 4時間分の進化
.build/release/hakoniwa-cli assay --load world.hkw                    # 第0世代と採餌能力を比較
.build/release/hakoniwa-cli sweep --seeds 1,2,3 --hours 2             # 複数シードで判定
.build/release/hakoniwa-cli bench --profile                           # 性能測定
```

## 仕組み

- [要件定義書](docs/REQUIREMENTS.md)
- [設計書](docs/DESIGN.md)

## テスト

```sh
swift test
```
