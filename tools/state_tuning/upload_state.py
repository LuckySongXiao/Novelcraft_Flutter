# -*- coding: utf-8 -*-
"""把 state tuning 产出的 state 张量推到远端 rwkv_lightning 推理服务，并做验证。

远端是 api-7b.rwkvos.com（3x4090）这套 rwkv_lightning_cuda 服务，其 state 接口是：

    POST   /v1/state/upload     multipart 上传（<=512MiB，按 PyTorch state archive 校验）
    GET    /v1/state/list       列出已上传的 state
    DELETE /v1/state/delete     {"state_id": "..."} 删除
    推理时带 state_id（JSON 字段或 X-RWKV-State-Id 请求头）

上传返回的 state_id 就是**上传文件的 basename**，所以文件名务必带版本语义，
且 7.2B 主编与 2.9B 写手的 state 必须用不同文件名（避免互相覆盖）。

用法
----
    set CF_ACCESS_CLIENT_ID=xxxx
    set CF_ACCESS_CLIENT_SECRET=yyyy

    python tools/state_tuning/upload_state.py list   --endpoint 7b
    python tools/state_tuning/upload_state.py upload --endpoint 7b  --file ./novelcraft-g1k-72b-main-v1.pth
    python tools/state_tuning/upload_state.py chat   --endpoint 7b  --state-id novelcraft-g1k-72b-main-v1.pth
    python tools/state_tuning/upload_state.py delete --endpoint 7b  --state-id novelcraft-g1k-72b-main-v1.pth

凭据也可以直接用 --cf-id / --cf-secret 传入（不要写进仓库）。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ENDPOINTS = {
    "1b5": "https://api-1b5.rwkvos.com",
    "3b": "https://api-3b.rwkvos.com",
    "7b": "https://api-7b.rwkvos.com",
    "13b": "https://api-13b.rwkvos.com",
}

DEMO_PROMPT = (
    "为长篇小说《测试书》制定主线大纲。\n要求：\n"
    "- 全书共 3 卷，每卷约 400 章。\n"
    "- 必须包含：核心冲突、主角成长线、主要人物名单、结局方向。\n"
    "- 600-900 字，条目化输出。"
)

# ⚠ 实测（2026-10-07）：远端对 `Python-urllib/3.x` 这个 User-Agent 直接返回 403，
# 而 curl / Mozilla / 自定义 UA 都是 200。这是 Cloudflare 侧的机器人规则，
# 不是鉴权失败 —— 不显式覆盖 UA 的话，本脚本所有请求都会被拦掉。
BASE_HEADERS = {"User-Agent": "novelcraft-state-tuning/1.0"}


def auth_headers(args: argparse.Namespace) -> dict[str, str]:
    headers = dict(BASE_HEADERS)
    cid = args.cf_id or os.environ.get("CF_ACCESS_CLIENT_ID", "")
    secret = args.cf_secret or os.environ.get("CF_ACCESS_CLIENT_SECRET", "")
    if cid and secret:
        headers["CF-Access-Client-Id"] = cid
        headers["CF-Access-Client-Secret"] = secret
    else:
        print("[提示] 未提供 CF Access 凭据 —— 当前远端未启用 Access 保护，"
              "实测无凭据也可直接访问；若日后启用了保护，请用 --cf-id/--cf-secret "
              "或环境变量 CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET 传入。")
    return headers


def request(url: str, headers: dict[str, str], data: bytes | None = None,
            method: str = "POST", timeout: int = 600) -> tuple[int, str]:
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001 - 网络异常统一报告
        return -1, "连接失败: %s" % exc


def guess(content: str) -> str:
    """Cloudflare Access 被绕过时会返回 HTML，这里显式点出来，避免误判成业务错误。"""
    head = content.lstrip()[:120].lower()
    if head.startswith("<!doctype") or head.startswith("<html"):
        return "  ⚠ 返回的是 HTML（Cloudflare Access 未通过 / 凭据大小写不对）"
    return ""


def cmd_list(args: argparse.Namespace) -> int:
    base = ENDPOINTS[args.endpoint]
    status, body = request(base + "/v1/state/list", auth_headers(args), method="GET")
    print("GET %s/v1/state/list -> HTTP %s%s" % (base, status, guess(body)))
    print(body[:4000])
    return 0 if status == 200 else 1


def cmd_upload(args: argparse.Namespace) -> int:
    path = os.path.abspath(args.file)
    if not os.path.isfile(path):
        print("[错误] 文件不存在: %s" % path)
        return 1
    size = os.path.getsize(path)
    if size > 512 * 1024 * 1024:
        print("[错误] 超过 512MiB 上传上限: %.1f MiB" % (size / 1048576))
        return 1
    name = os.path.basename(path)

    boundary = "----NovelCraftState" + uuid.uuid4().hex
    with open(path, "rb") as fh:
        payload = fh.read()
    body = (
        ("--%s\r\n" % boundary).encode()
        + ('Content-Disposition: form-data; name="file"; filename="%s"\r\n' % name).encode()
        + b"Content-Type: application/octet-stream\r\n\r\n"
        + payload
        + ("\r\n--%s--\r\n" % boundary).encode()
    )
    headers = auth_headers(args)
    headers["Content-Type"] = "multipart/form-data; boundary=" + boundary

    print("上传 %s (%.1f MiB) -> %s/v1/state/upload" % (
        name, size / 1048576, ENDPOINTS[args.endpoint]))
    status, resp = request(ENDPOINTS[args.endpoint] + "/v1/state/upload", headers, body)
    print("HTTP %s%s" % (status, guess(resp)))
    print(resp[:2000])
    if status == 200:
        print("\n提示：state_id 就是文件名 `%s`，推理时把它放进 JSON 的 state_id 字段"
              "或 X-RWKV-State-Id 请求头。" % name)
    return 0 if status == 200 else 1


def cmd_delete(args: argparse.Namespace) -> int:
    base = ENDPOINTS[args.endpoint]
    body = json.dumps({"state_id": args.state_id}).encode()
    headers = auth_headers(args)
    headers["Content-Type"] = "application/json"
    status, resp = request(base + "/v1/state/delete", headers, body, method="DELETE")
    print("DELETE %s/v1/state/delete -> HTTP %s%s" % (base, status, guess(resp)))
    print(resp[:1000])
    return 0 if status == 200 else 1


def cmd_chat(args: argparse.Namespace) -> int:
    base = ENDPOINTS[args.endpoint]
    payload = {
        "model": args.model or "api-test",
        "messages": [{"role": "user", "content": args.prompt or DEMO_PROMPT}],
        "stream": False,
        "max_tokens": args.max_tokens,
        "temperature": 1.0,
    }
    if args.state_id:
        payload["state_id"] = args.state_id
    headers = auth_headers(args)
    headers["Content-Type"] = "application/json"
    status, resp = request(base + "/v1/chat/completions", headers,
                           json.dumps(payload, ensure_ascii=False).encode())
    tag = "带 state_id=%s" % args.state_id if args.state_id else "零初始化 state（对照）"
    print("POST %s/v1/chat/completions -> HTTP %s  [%s]%s" % (base, status, tag, guess(resp)))
    try:
        obj = json.loads(resp)
        text = obj["choices"][0]["message"]["content"]
        print("\n--- 生成内容（前 1200 字）---")
        print(text[:1200])
    except Exception:  # noqa: BLE001
        print(resp[:2000])
    return 0 if status == 200 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--endpoint", default="7b", choices=sorted(ENDPOINTS),
                    help="7b=主编端点, 3b=写手端点（默认 7b）")
    ap.add_argument("--cf-id", default="", help="CF-Access-Client-Id")
    ap.add_argument("--cf-secret", default="", help="CF-Access-Client-Secret")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="列出远端已缓存的 state")

    up = sub.add_parser("upload", help="上传 state 张量")
    up.add_argument("--file", required=True)

    de = sub.add_parser("delete", help="删除一个 state")
    de.add_argument("--state-id", required=True)

    ch = sub.add_parser("chat", help="带 state_id 试推理（不给 state_id 即对照组）")
    ch.add_argument("--state-id", default="")
    ch.add_argument("--model", default="")
    ch.add_argument("--prompt", default="")
    ch.add_argument("--max-tokens", type=int, default=256)

    args = ap.parse_args()
    return {
        "list": cmd_list,
        "upload": cmd_upload,
        "delete": cmd_delete,
        "chat": cmd_chat,
    }[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
