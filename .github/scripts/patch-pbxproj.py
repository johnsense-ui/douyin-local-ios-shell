#!/usr/bin/env python3
"""
把 _ios-shell/ios-plugin/*.swift 加进 Capacitor 生成的 Xcode 工程（App target），
替换 Main.storyboard 的根视图控制器，并用 ios-plugin/Info.plist.template 覆盖 Info.plist。

为什么需要：
  1. cap add ios 生成的 App.xcodeproj 只认识模板文件，我们写的
     NativeStage.swift / NativeVideoPlugin.swift / BridgeViewController.swift
     不手工 Add Files 就不会被编译。
  2. Capacitor 6 不会自动发现自定义插件，必须让 CAPBridgeViewController 的
     子类去 registerPluginInstance —— 也就是替换 storyboard 的 customClass。
  3. Info.plist 要补 ATS（http 局域网）/ 后台音频 / 竖屏锁；
     并且要用 ASCII 安全的内容，避免 Windows 上 GBK 写文件写坏 XML。

脚本是幂等的：重复跑不会重复添加。

用法（在 _ios-shell 目录下）：
    python3 .github/scripts/patch-pbxproj.py
    python3 .github/scripts/patch-pbxproj.py ios/App/App.xcodeproj/project.pbxproj ios/App/App/NativeStage
"""
import hashlib
import pathlib
import re
import shutil
import sys

PROJ = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "ios/App/App.xcodeproj/project.pbxproj")
SRC_DIR = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "ios/App/App/NativeStage")
APP_DIR = PROJ.parents[1] / "App"
STORYBOARD = APP_DIR / "Base.lproj" / "Main.storyboard"
PLIST = APP_DIR / "Info.plist"
PLIST_TPL = pathlib.Path(__file__).resolve().parents[2] / "ios-plugin" / "Info.plist.template"

if not PROJ.exists():
    sys.exit(f"[patch-pbxproj] 找不到 {PROJ}（先跑 npx cap add ios）")
if not SRC_DIR.exists():
    sys.exit(f"[patch-pbxproj] 找不到源码目录 {SRC_DIR}")

swifts = sorted(p for p in SRC_DIR.iterdir() if p.suffix == ".swift")
if not swifts:
    sys.exit(f"[patch-pbxproj] {SRC_DIR} 里没有 .swift 文件")

text = PROJ.read_text(encoding="utf-8")


def oid(seed: str) -> str:
    """稳定 24 位十六进制 object id（Xcode 要求）"""
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


def find_re(pattern: str, what: str) -> re.Match:
    m = re.search(pattern, text)
    if not m:
        sys.exit(f"[patch-pbxproj] 无法定位 {what}")
    return m


# ---------------------------------------------------------------- 定位 target
sources_phase_id = find_re(
    r"([0-9A-F]{24})\s*/\* Sources \*/ = \{\n\t+isa = PBXSourcesBuildPhase;",
    "App target 的 Sources build phase",
).group(1)

app_group_id = find_re(
    r"([0-9A-F]{24})\s*/\* App \*/ = \{\n\t+isa = PBXGroup;",
    "App group",
).group(1)

group_pat = re.compile(
    r"(" + re.escape(app_group_id) + r"\s*/\* App \*/ = \{\n\t+isa = PBXGroup;\n\t+children = \(\n)(.*?)(\t+\);)",
    re.S,
)
if not group_pat.search(text):
    sys.exit("[patch-pbxproj] 无法定位 App group 的 children")

new_refs, new_builds, new_children, new_phase = [], [], [], []

for f in swifts:
    name = f.name
    if oid(f"fileref:{name}") in text:
        print(f"[patch-pbxproj] 跳过（已存在）: {name}")
        continue

    ref_id = oid(f"fileref:{name}")
    build_id = oid(f"buildfile:{name}")

    new_refs.append(
        f'\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
        f'path = "{name}"; sourceTree = "<group>"; }};\n'
    )
    new_builds.append(
        f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {ref_id} /* {name} */; }};\n"
    )
    new_children.append(f"\t\t\t\t{ref_id} /* {name} */,\n")
    new_phase.append(f"\t\t\t\t{build_id} /* {name} in Sources */,\n")
    print(f"[patch-pbxproj] 添加: {name}")

if new_refs:
    text = group_pat.sub(
        lambda m: m.group(1) + "".join(new_children) + m.group(2) + m.group(3), text, count=1
    )

    phase_pat = re.compile(
        r"(" + re.escape(sources_phase_id) + r"\s*/\* Sources \*/ = \{\n\t+isa = PBXSourcesBuildPhase;\n"
        r"\t+buildActionMask = \d+;\n\t+files = \(\n)(.*?)(\t+\);)",
        re.S,
    )
    if not phase_pat.search(text):
        sys.exit("[patch-pbxproj] 无法定位 Sources files 列表")
    text = phase_pat.sub(
        lambda m: m.group(1) + "".join(new_phase) + m.group(2) + m.group(3), text, count=1
    )

    text = text.replace(
        "/* End PBXBuildFile section */",
        "".join(new_builds) + "/* End PBXBuildFile section */",
        1,
    )
    text = text.replace(
        "/* End PBXFileReference section */",
        "".join(new_refs) + "/* End PBXFileReference section */",
        1,
    )
    PROJ.write_text(text, encoding="utf-8")
    print(f"[patch-pbxproj] 写入 {PROJ}")
else:
    print("[patch-pbxproj] 源码已在工程里，跳过添加")

# ---------------------------------------------------------------- storyboard
if STORYBOARD.exists():
    sb = STORYBOARD.read_text(encoding="utf-8")
    if 'customClass="BridgeViewController"' in sb:
        print("[patch-pbxproj] storyboard 已指向 BridgeViewController")
    elif 'customClass="CAPBridgeViewController"' in sb:
        sb = re.sub(
            r'customClass="CAPBridgeViewController"\s+customModule="Capacitor"',
            'customClass="BridgeViewController" customModule="App" customModuleProvider="target"',
            sb,
        )
        STORYBOARD.write_text(sb, encoding="utf-8")
        print("[patch-pbxproj] 已把根 VC 换成 BridgeViewController")
    else:
        print("[patch-pbxproj] ! storyboard 里没找到 CAPBridgeViewController，请手工改 Custom Class")
else:
    print(f"[patch-pbxproj] ! 没找到 storyboard: {STORYBOARD}")

# ---------------------------------------------------------------- Info.plist
if PLIST_TPL.exists():
    # 模板里全是 ASCII 安全的写法，直接整体覆盖，不做字符串拼接（避免编码问题）
    shutil.copyfile(PLIST_TPL, PLIST)
    print(f"[patch-pbxproj] 已用模板覆盖 {PLIST.name}")
elif PLIST.exists():
    pl = PLIST.read_text(encoding="utf-8")
    if "NSAppTransportSecurity" in pl:
        print("[patch-pbxproj] Info.plist 已有 ATS（无模板可覆盖）")
    else:
        print("[patch-pbxproj] ! 缺 Info.plist.template，且 Info.plist 没有 ATS，请手动补")
else:
    print(f"[patch-pbxproj] ! 既没有模板也没有 {PLIST}")

print("[patch-pbxproj] 完成")
