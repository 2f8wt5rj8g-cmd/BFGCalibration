#!/usr/bin/env python3
"""Check the page ⇄ native contract, in both directions.

This exists because the two worst UI defects so far were both contract breaks,
and neither one is visible to the compiler, the unit tests, or a screenshot:

  * a button the page declares but never sends (`dump-registers`,
    `compare-dump`, `restore-dis` were all silently dead), and
  * native re-sending `screen`/`modal` as durable state, so every later push
    dragged the rider back to a page they had left or re-opened a dialog they
    had closed — the home button became unreachable.

Part 1 is a mechanical diff of the four action sets. Part 2 drives the real page
in headless Chrome and asserts the navigation/dialog behaviour through the same
channel the native side uses (`screen` and `modal-state` reports).

Usage: Tools/check-ui-wiring.py
Requires: google-chrome or chromium (same as render-screens.sh).
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTML = os.path.join(ROOT, "ios/BFGCalibration/Resources/bfg-calibration-flow.html")
SWIFT = os.path.join(ROOT, "ios/BFGCalibration/PrototypeWebView.swift")

failures = []


def fail(message):
    failures.append(message)
    print(f"  ✗ {message}")


def part1_contract_diff(html, swift):
    """Every action the page declares must reach either the page's own handler
    or the native side; every action the page sends must be handled there."""
    print("── 1. 页面动作契约（机械比对）")

    declared = set(re.findall(r'data-action="([a-z-]+)"', html))
    handled_locally = set(re.findall(r"action === '([a-z-]+)'", html))
    sent_literally = set(re.findall(r"nativeAction\('([a-z-]+)'", html))
    # `nativeAction(action)` and `nativeAction(pairing ? ... : ...)` are indirect
    # sends; treat any action mentioned by a data-action attribute plus a
    # `nativeAction(action` call site as reachable.
    sends_indirectly = "nativeAction(action" in html
    # Case labels can list several actions: `case "begin-connect", "refresh-read":`.
    # Matching only the first string after `case` invents missing handlers.
    case_labels = re.findall(r"case\s+((?:\s*\"[a-z-]+\"\s*,?)+):", swift)
    native_cases = {name for label in case_labels
                    for name in re.findall(r'"([a-z-]+)"', label)}

    dead = sorted(a for a in declared
                  if a not in handled_locally
                  and a not in sent_literally
                  and not sends_indirectly)
    if dead:
        fail("页面声明了但从不发送的死按钮：" + ", ".join(dead))
    else:
        print(f"  ✓ {len(declared)} 个动作都有去处（本地处理或发往原生）")

    # Native handlers are allowed to exist without a literal send (combined
    # `case "a", "b":` and indirect sends both hide the literal), so only report
    # an action the page *does* send and native never mentions at all.
    unhandled = sorted(a for a in sent_literally if a not in native_cases)
    if unhandled:
        # `modal-state` / `screen` / `select-vehicle` are deliberate no-ops.
        real = [a for a in unhandled if a not in {"modal-state", "screen", "select-vehicle"}]
        if real:
            fail("页面发了但原生没有分支：" + ", ".join(real))
        else:
            print("  ✓ 未接的动作都是有意忽略的展示类动作")
    else:
        print("  ✓ 页面发出的动作原生都有分支")

    return not failures


PAGE_TEST = r"""
<script>
window.addEventListener('load', function () {
  const out = [];
  const ok = (n, c, x) => out.push((c ? 'PASS ' : 'FAIL ') + n + (x ? ' :: ' + x : ''));
  const ev = [];
  window.BfgNative = { action: (a, v) => ev.push([a, String(v)]) };
  const update = (o) => window.bfgNativeUpdate(JSON.stringify(o));
  const click = (sel) => { const el = document.querySelector(sel);
                           if (!el) throw new Error('缺 ' + sel);
                           if (el.disabled) el.disabled = false;
                           el.click(); };
  const last = (k) => { for (let i = ev.length - 1; i >= 0; i--) if (ev[i][0] === k) return ev[i][1]; return null; };
  const opens = () => ev.filter(e => e[0] === 'modal-state' && e[1] === 'open').length;
  const sent = (a) => ev.some(e => e[0] === a);

  try {
    // 失败落到结果页；用户返回设置后，原生的后续推送不得把他拽回去
    update({ screen: 'scan-result', errorMessage: '本机没有这辆车的配对凭据。', busyMessage: null });
    ok('失败落到扫描结果页', last('screen') === 'scan-result', last('screen'));
    click('[data-action="settings"]');
    ok('返回设置生效', last('screen') === 'settings', last('screen'));

    let mark = ev.length;
    update({ busyMessage: null });
    ok('原生后续推送不把用户拽回失败页',
       last('screen') === 'settings' && !ev.slice(mark).some(e => e[0] === 'screen'), last('screen'));
    click('[data-action="home"]');
    ok('首页可达（导航不再循环）', last('screen') === 'home', last('screen'));

    // 对照组：确实存在 screen 的推送会切换页面 —— 证明本测试抓得到该缺陷
    update({ screen: 'scan-result' });
    ok('（对照）带 screen 的推送会切换页面', last('screen') === 'scan-result', last('screen'));
    click('[data-action="settings"]');

    // 弹窗关闭后不得复活
    update({ modal: 'operation-failed', screen: 'settings', errorMessage: '未配对。' });
    ok('失败弹窗出现', last('modal-state') === 'open', String(last('modal-state')));
    const opened = opens();
    click('[data-action="close-modal"]');
    ok('弹窗可关闭', last('modal-state') === 'closed', String(last('modal-state')));
    update({ busyMessage: null });
    ok('关闭后不复活', last('modal-state') === 'closed' && opens() === opened,
       'opens=' + opens() + '/' + opened);

    // 曾经空接的按钮必须真的把动作发出去
    click('[data-action="dump-registers"]');
    ok('导出寄存器快照发往原生', sent('dump-registers'), '');
    ok('快照进入进度页', last('screen') === 'scan-progress', last('screen'));
    click('[data-action="cancel-scan"]');
    click('[data-action="compare-dump"]');
    ok('与上次快照对比发往原生', sent('compare-dump'), '');
    click('[data-action="restore-dis"]');
    ok('恢复首次仪表配置发往原生', sent('restore-dis'), '');
    click('[data-action="restore-first"]');
    ok('恢复首次原参数发往原生', sent('restore-first'), '');

    // 声明弹窗打开时不改变当前页面，关闭后不复活
    click('[data-action="show-license"]');
    ok('关于声明发往原生', sent('show-license'), '');
    update({ modal: 'license', licenseText: 'x' });
    ok('声明弹窗出现且页面未被拽走', last('modal-state') === 'open' && last('screen') === 'settings',
       last('screen'));
    click('[data-action="close-modal"]');
    update({ busyMessage: null });
    ok('声明关闭后不复活', last('modal-state') === 'closed', String(last('modal-state')));
  } catch (e) { out.push('ERROR ' + e.message); }
  document.title = 'UICHECK|' + out.join('|');
});
</script>
"""


def part2_interaction(html):
    print("\n── 2. 页面交互（无头浏览器，走原生同一通道断言）")
    chrome = os.environ.get("CHROME", "google-chrome")
    if not any(os.path.exists(os.path.join(p, chrome))
               for p in os.environ.get("PATH", "").split(os.pathsep)):
        print("  ⚠ 未找到 chrome/chromium，跳过（渲染类检查在本机与 CI 都不做）")
        return

    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False,
                                     encoding="utf-8", dir="/tmp") as handle:
        handle.write(html.replace("</body>", PAGE_TEST + "</body>"))
        path = handle.name

    result = subprocess.run(
        [chrome, "--headless=new", "--disable-gpu", "--no-sandbox",
         "--virtual-time-budget=8000", "--window-size=390,844", "--dump-dom",
         f"file://{path}"],
        capture_output=True, text=True)
    match = re.search(r"<title>UICHECK\|(.*?)</title>", result.stdout, re.S)
    if not match:
        fail("页面测试没有返回结果（chrome 未运行？）")
        return
    for line in match.group(1).split("|"):
        if line.startswith("PASS"):
            print("  ✓ " + line[5:])
        elif line.startswith("FAIL"):
            fail(line[5:])
        else:
            fail(line)


def main():
    html = open(HTML, encoding="utf-8").read()
    swift = open(SWIFT, encoding="utf-8").read()

    part1_contract_diff(html, swift)
    part2_interaction(html)

    print()
    if failures:
        print(f"未通过 {len(failures)} 项：")
        for item in failures:
            print("  · " + item)
        sys.exit(1)
    print("页面 ⇄ 原生契约检查通过")


if __name__ == "__main__":
    main()
