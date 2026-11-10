# -*- coding: utf-8 -*-
"""创建 Gitee Release 并上传发布产物。

用法（在项目根目录）：
    set GITEE_TOKEN=<私人令牌>
    python scripts/gitee_release.py

令牌获取：Gitee -> 设置 -> 私人令牌 -> 生成新令牌（勾选 projects 权限）。
也可放在 ~/.gitee/token 或项目根目录 .gitee-token（均已 gitignore）。

依赖：仅 Python 标准库。
"""
import json
import mimetypes
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

OWNER = "xppobnome"
REPO = "water_quality_detector_assistant"
VERSION = "0.6.6"
TAG = "v" + VERSION
API = "https://gitee.com/api/v5/repos/%s/%s" % (OWNER, REPO)

RELEASE_BODY = """## 水质检测仪助手 v0.6.6

### 本次发布
- 新增工作空间「默认存储路径」与「按年月分组（yyyy-MM）」设置
- 新增自定义判定限编辑（工作空间详情页顶栏「自定义判定限」）
- 计算结果标注档位覆盖率（如「合格（1/4 档）」）
- 修正扩展量程下自定义判定限不生效的问题
- 第 9 轮遗留文案与措辞清理

### 产物
- `water_quality_detector_assistant_0.6.6_arm64.apk`：Android arm64-v8a release，使用专用签名密钥
- `water_quality_detector_assistant_0.6.6_windows_x64.zip`：Windows x64 release（解压后运行 `water_quality_detector_assistant.exe`）

### 说明
- Windows 端 OCR 引擎随程序分发，解压时请保持目录结构完整。
- Android 最低支持 Android 7.0（API 24），仅适用于 arm64-v8a 设备。
"""


def resolve_token():
    token = os.environ.get("GITEE_TOKEN", "").strip()
    if token:
        return token
    for candidate in (
        pathlib.Path.home() / ".gitee" / "token",
        pathlib.Path(__file__).resolve().parent.parent / ".gitee-token",
    ):
        if candidate.exists():
            token = candidate.read_text(encoding="utf-8").strip()
            if token:
                return token
    return ""


def post_json(path, payload):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        path, data=data,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def post_file(url, token, file_path):
    """multipart/form-data：字段 access_token + file。"""
    boundary = "----WQA" + uuid.uuid4().hex
    name = file_path.name
    content = file_path.read_bytes()
    parts = []
    parts.append(("--%s\r\n" % boundary).encode())
    parts.append(
        b'Content-Disposition: form-data; name="access_token"\r\n\r\n'
        + token.encode() + b"\r\n"
    )
    parts.append(("--%s\r\n" % boundary).encode())
    ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
    disp = (
        'Content-Disposition: form-data; name="file"; filename="%s"\r\n'
        "Content-Type: %s\r\n\r\n" % (name, ctype)
    ).encode()
    parts.append(disp)
    parts.append(content)
    parts.append(b"\r\n")
    parts.append(("--%s--\r\n" % boundary).encode())
    body = b"".join(parts)
    req = urllib.request.Request(
        url, data=body,
        headers={
            "Content-Type": "multipart/form-data; boundary=%s" % boundary,
            "Content-Length": str(len(body)),
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main():
    token = resolve_token()
    if not token:
        print("错误：未找到 Gitee 私人令牌。")
        print("请设置环境变量 GITEE_TOKEN，或写入 ~/.gitee/token / .gitee-token。")
        return 2

    root = pathlib.Path(__file__).resolve().parent.parent
    dist = root / "dist"
    assets = [
        dist / ("water_quality_detector_assistant_%s_arm64.apk" % VERSION),
        dist / ("water_quality_detector_assistant_%s_windows_x64.zip" % VERSION),
    ]
    for a in assets:
        if not a.exists():
            print("错误：缺少产物 %s" % a)
            return 3
        print("产物 %s  %.1f MB" % (a.name, a.stat().st_size / 1024 / 1024))

    # 先校验令牌有效性
    check_url = "https://gitee.com/api/v5/user?access_token=" + urllib.parse.quote(token)
    try:
        with urllib.request.urlopen(check_url, timeout=30) as resp:
            who = json.loads(resp.read().decode("utf-8")).get("login")
            print("令牌有效，用户：%s" % who)
    except urllib.error.HTTPError as e:
        print("令牌校验失败：HTTP %s %s" % (e.code, e.read().decode(errors="replace")[:200]))
        return 4

    payload = {
        "access_token": token,
        "tag_name": TAG,
        "name": "水质检测仪助手 v" + VERSION,
        "body": RELEASE_BODY,
        "target_commitish": "main",
        "prerelease": False,
    }
    try:
        release = post_json(API + "/releases", payload)
    except urllib.error.HTTPError as e:
        text = e.read().decode(errors="replace")
        print("创建 Release 失败：HTTP %s %s" % (e.code, text[:400]))
        return 5
    release_id = release.get("id")
    print("已创建 Release id=%s tag=%s" % (release_id, TAG))

    upload_url = "%s/releases/%s/attach_files?access_token=%s" % (
        API, release_id, urllib.parse.quote(token)
    )
    for a in assets:
        try:
            post_file(upload_url, token, a)
            print("已上传：%s" % a.name)
        except urllib.error.HTTPError as e:
            print("上传失败 %s：HTTP %s %s" %
                  (a.name, e.code, e.read().decode(errors="replace")[:300]))
            return 6
    print("完成：https://gitee.com/%s/%s/releases/tag/%s" % (OWNER, REPO, TAG))
    return 0


if __name__ == "__main__":
    sys.exit(main())
