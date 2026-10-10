#!/usr/bin/env bash
# 在远端 4090 机器上执行 NovelCraft 的 state tuning。
#
# 前置（详见 tools/state_tuning/README.md）：
#   1) 已编译出 rwkv_state_tune（rwkv_lightning_cuda，CUDA 构建默认 RWKV7_STATE_TUNING=ON）
#   2) 有两份与线上完全同版本的 .pth 权重
#   3) 已把 main72b.jsonl / writer29b.jsonl 传到本机
#
# 用法：
#   ./train_remote.sh check                 # 只做环境自检
#   SMOKE=1 ./train_remote.sh 72b           # 20 步小跑，验证显存与产出
#   ./train_remote.sh 72b                   # 7.2B 主编全量
#   SMOKE=1 ./train_remote.sh 29b
#   ./train_remote.sh 29b                   # 2.9B 写手全量
#   ./train_remote.sh all                   # 先 72b 后 29b
#
# 可用环境变量覆盖默认值：
#   BIN             rwkv_state_tune 路径
#   WEIGHTS_DIR     权重目录（默认取线上现状 /home/rwkv/rwkv-stack/weights）
#   DATA_DIR        数据目录
#   OUT_DIR         输出根目录
#   MODEL_72B / MODEL_29B  具体权重文件名
set -euo pipefail

BIN="${BIN:-./build/rwkv_state_tune}"
WEIGHTS_DIR="${WEIGHTS_DIR:-/home/rwkv/rwkv-stack/weights}"
DATA_DIR="${DATA_DIR:-./novelcraft_data}"
OUT_DIR="${OUT_DIR:-./state_out}"
MODEL_72B="${MODEL_72B:-rwkv7-g1k-7.2b-20260930-ctx25600.pth}"
MODEL_29B="${MODEL_29B:-rwkv7-g1k-2.9b-20260930-ctx25600.pth}"

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

check() {
  say "环境自检"
  for f in "$BIN" "$WEIGHTS_DIR/$MODEL_72B" "$WEIGHTS_DIR/$MODEL_29B" \
           "$DATA_DIR/main72b.jsonl" "$DATA_DIR/writer29b.jsonl"; do
    if [ -e "$f" ]; then
      printf '  [OK]   %s\n' "$f"
    else
      printf '  [缺失] %s\n' "$f"
    fi
  done
  echo
  echo "若 rwkv_state_tune 缺失，在 rwkv_lightning_cuda 目录执行："
  echo "  cmake -B build -DCMAKE_BUILD_TYPE=Release -DRWKV7_STATE_TUNING=ON && cmake --build build -j"
}

run_one() {
  local tag="$1" model="$2" data="$3" ctx="$4" chunk="$5" steps="$6" bs="$7"
  local out="$OUT_DIR/state_out_$tag"

  say "训练 $tag  (ctx=$ctx chunk=$chunk steps=$steps batch=$bs)"
  mkdir -p "$out"
  "$BIN" \
    --model  "$WEIGHTS_DIR/$model" \
    --data   "$DATA_DIR/$data" \
    --output "$out" \
    --ctx "$ctx" --chunk "$chunk" \
    --epochs 1 --max-steps "$steps" \
    --lr 0.0005 --lr-final 0.0005 --warmup-steps 10 \
    --save-every "$([ "$steps" -le 50 ] && echo 10 || echo 200)" \
    --batch-size "$bs"

  echo
  echo "产出目录: $out"
  ls -la "$out" | tail -5
  echo
  echo "下一步：挑最后一个 checkpoint，重命名后上传（文件名 = state_id）："
  if [ "$tag" = "72b" ]; then
    echo "  mv <最后checkpoint> ./novelcraft-g1k-72b-main-v1.pth"
    echo "  python tools/state_tuning/upload_state.py --endpoint 7b upload --file ./novelcraft-g1k-72b-main-v1.pth"
  else
    echo "  mv <最后checkpoint> ./novelcraft-g1k-29b-writer-v1.pth"
    echo "  python tools/state_tuning/upload_state.py --endpoint 3b upload --file ./novelcraft-g1k-29b-writer-v1.pth"
  fi
}

[ $# -ge 1 ] || { sed -n '2,20p' "$0"; exit 1; }

case "$1" in
  check) check ;;
  72b)
    check
    # 7.2B FP16 权重约 14.4GB，ctx 保守取 1024；OOM 就先降 batch-size 再降 ctx
    if [ "${SMOKE:-0}" = "1" ]; then run_one 72b "$MODEL_72B" main72b.jsonl 1024 256 20 2
    else run_one 72b "$MODEL_72B" main72b.jsonl 1024 256 1200 4; fi ;;
  29b)
    check
    if [ "${SMOKE:-0}" = "1" ]; then run_one 29b "$MODEL_29B" writer29b.jsonl 2048 512 20 4
    else run_one 29b "$MODEL_29B" writer29b.jsonl 2048 512 3000 8; fi ;;
  all)
    "$0" 72b
    "$0" 29b ;;
  *) echo "未知参数: $1"; sed -n '2,20p' "$0"; exit 1 ;;
esac
