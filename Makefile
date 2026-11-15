# 箱庭 (hakoniwa) — よく使う操作
#
#   make            使い方を表示
#   make app        アプリをビルド(build/Hakoniwa.app)
#   make open       ビルドして起動
#
# 変数は make evolve SEED=3 HOURS=6 のように上書きできる。

SEED     ?= 1
HOURS    ?= 4
SEEDS    ?= 1,2,3
WORLD    ?= out/world.hkw
REPORT   ?= 15

CLI      := .build/release/hakoniwa-cli
APP      := build/Hakoniwa.app

.DEFAULT_GOAL := help
.PHONY: help app open run cli test bench profile evolve assay sweep showcase clean distclean

help: ## この一覧を表示
	@echo "使い方: make <ターゲット> [SEED=1 HOURS=4 SEEDS=1,2,3 WORLD=out/world.hkw]"
	@echo
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

app: ## アプリをビルド(build/Hakoniwa.app)
	scripts/build-app.sh

open: app ## アプリをビルドして起動
	open $(APP)

run: ## アプリをビルドせずにデバッグ実行(swift run)
	swift run -c release Hakoniwa

cli: ## ヘッドレス CLI をビルド
	swift build -c release --product hakoniwa-cli

test: ## 単体テストを実行
	swift test

bench: cli ## シミュレーションの速度を測る
	$(CLI) bench --seconds 8 --warmup 3000

profile: cli ## 処理段階ごとの時間を測る
	$(CLI) bench --seconds 8 --warmup 3000 --profile

evolve: cli ## 画面なしで進化させて保存(SEED, HOURS, WORLD)
	@mkdir -p $(dir $(WORLD))
	$(CLI) run --seed $(SEED) --hours $(HOURS) --report $(REPORT) --save $(WORLD) --csv $(WORLD:.hkw=.csv)

assay: cli ## 保存した世界の採餌能力を第0世代と比較(WORLD)
	$(CLI) assay --load $(WORLD)

sweep: cli ## 複数シードで受け入れ基準を判定(SEEDS, HOURS)
	$(CLI) sweep --seeds $(SEEDS) --hours $(HOURS)

showcase: ## アプリに同梱する進化済みの世界を作り直す(SEED, HOURS=10 推奨)
	scripts/make-showcase.sh $(SEED) $(HOURS)

clean: ## ビルド成果物を削除
	rm -rf build .build

distclean: clean ## ビルド成果物と実験データ(out/)を削除
	rm -rf out
