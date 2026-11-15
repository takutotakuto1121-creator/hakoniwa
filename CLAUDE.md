# hakoniwa — 作業ルール

## 開発の流れ
- 機能ごとにブランチ(エージェントは worktree のブランチ)で作業してコミットする。PR は作らない。
- リーダーがブランチを main にマージし、ビルドとテストを確認してから push する(main へのコミットは毎回 push する)。
- エージェントはブランチを push しない。コミット単位は小さく(1機能・1修正)。
- コミットメッセージ末尾: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- UI の文言は日本語。

## 構成
- `Sources/HakoniwaCore` — シミュレーション(UI 非依存)。公開 API は `Inspection.swift`(描画・詳細・介入)、`Features.swift`(壁・気候・疫病・復活・伝記・英雄・履歴・対決用アリーナ)、`World.swift`、`Persistence.swift`。
- `Sources/Hakoniwa` — アプリ(Metal 描画 `Render/`、SwiftUI `UI/`、`Simulation/SimulationController.swift` が World を専用スレッドで回す)。
- `Sources/hakoniwa-cli` — ヘッドレス実行。
- `docs/REQUIREMENTS.md`, `docs/DESIGN.md`。

## 守ること
- World はスレッドセーフではない。アプリからの操作は SimulationController のコマンドキュー経由で、シミュレーションスレッド上で行う。
- 並列段階(sense/act)は自スロットにだけ書き、乱数を使わない(決定性を壊さない)。
- エネルギーは保存則を守る(介入も土との出し入れで行う)。
- 保存形式を変えたら `World.fileVersion` を上げ、`Resources/showcase.hkw` を `make showcase SEED=1 HOURS=10` で作り直す。

## 確認方法
- `make test` / `make app` / `make open`
- 見た目の確認: `.build/release/Hakoniwa --screenshot PATH [--load W | --seed N --ticks N] [--zoom Z] [--tab NAME] [--frames K] --select-first`
  撮った PNG は `sips -Z 1600` で縮小して見る。
