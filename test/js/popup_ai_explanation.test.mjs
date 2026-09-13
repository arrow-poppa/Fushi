// AI 解释区块的渲染与流式更新（jsdom 真 DOM）。
//
// Dart 侧只能守到「注入了什么」，守不到这里真正要命的两件事：流式期间会不会把
// 用户正在拖的选择清掉，以及加载中/出错的占位文案会不会被当成答案带进 Anki 卡片。
// 两者都只有真 DOM 能问出来。
//
// 契约见 docs/agent/ai-explanation.md §10。
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

const POPUP_URL = new URL("../../fushi/assets/popup/popup.js", import.meta.url);
const popupSrc = readFileSync(POPUP_URL, "utf8");

function createPopup() {
  const dom = new JSDOM(
    `<!DOCTYPE html><body><div id="entries-container"></div></body>`,
    { runScripts: "outside-only", pretendToBeVisual: true },
  );
  const win = dom.window;
  const calls = [];
  win.flutter_inappwebview = {
    callHandler: (name, payload) => {
      calls.push({ name, payload });
      return Promise.resolve();
    },
  };
  win.matchMedia = (query) => ({
    media: query,
    matches: false,
    addListener() {},
    removeListener() {},
  });
  win.HTMLElement.prototype.getBoundingClientRect = () => ({
    x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0,
  });
  win.eval(popupSrc);
  return { win, calls };
}

/// 造盒子并挂进容器，返回盒子元素。
function mount(win, state) {
  win.__fushiAiState = state;
  const box = win.buildAiExplanationBox();
  if (box) win.document.getElementById("entries-container").appendChild(box);
  return box;
}

const bodyOf = (box) => box.querySelector('[data-ai-role="text"]').textContent;
const actionsOf = (box) =>
  [...box.querySelectorAll(".ai-explanation-action")].map((b) =>
    b.textContent,
  );

test("没有状态时不画任何东西", () => {
  const { win } = createPopup();
  assert.equal(mount(win, null), null);
  assert.equal(mount(win, { status: "hidden" }), null);
});

test("取消态不重画——保留用户眼前已有的内容", () => {
  // 放弃一个请求是正常操作，不是错误；参考实现在这个态下什么都不改。
  const { win } = createPopup();
  assert.equal(mount(win, { status: "cancelled" }), null);
});

test("每个状态渲染对应文案", () => {
  const { win } = createPopup();
  const cases = [
    ["notConfigured", "Configure a provider"],
    ["manual", "Automatic generation is off"],
    ["loading", "Generating explanation"],
    ["timedOut", "timed out"],
  ];
  for (const [status, fragment] of cases) {
    const box = mount(win, { status });
    assert.ok(
      bodyOf(box).includes(fragment),
      `${status} 应包含 ${JSON.stringify(fragment)}，实际 ${JSON.stringify(bodyOf(box))}`,
    );
    box.remove();
  }
});

test("出错时优先显示 provider 自己的那句（已脱敏）", () => {
  // 通用文案帮不了用户判断是 key 错了还是额度没了。
  const { win } = createPopup();
  const box = mount(win, { status: "failed", detail: "Incorrect API key provided" });
  assert.equal(bodyOf(box), "Incorrect API key provided");
});

test("没有 detail 时退回通用失败文案", () => {
  const { win } = createPopup();
  const box = mount(win, { status: "failed" });
  assert.ok(bodyOf(box).includes("Failed to generate"));
});

test("done 态显示答案，空答案退回占位文案", () => {
  const { win } = createPopup();
  assert.equal(bodyOf(mount(win, { status: "done", text: "猫 means cat." })), "猫 means cat.");
  const empty = mount(win, { status: "done", text: "" });
  assert.ok(bodyOf(empty).includes("No explanation available"));
});

test("有请求在飞时只给取消，其余时候只给重新生成", () => {
  // 参考实现压根没有取消按钮——用户只能靠关弹窗，这是需求里点名要补的。
  const { win } = createPopup();
  for (const status of ["loading", "streaming"]) {
    const box = mount(win, { status, text: "x" });
    assert.deepEqual(actionsOf(box), ["×"], `${status} 只应有取消`);
    box.remove();
  }
  for (const status of ["done", "failed", "timedOut", "manual"]) {
    const box = mount(win, { status, text: "x" });
    assert.deepEqual(actionsOf(box), ["↻"], `${status} 只应有重新生成`);
    box.remove();
  }
});

test("manual 态的按钮说的是「生成」而不是「重新生成」", () => {
  const { win } = createPopup();
  const box = mount(win, { status: "manual" });
  const button = box.querySelector(".ai-explanation-action");
  assert.match(button.title, /Generate explanation/);
});

test("按钮把意图回传给 Dart，且不冒泡出去", () => {
  const { win, calls } = createPopup();
  const done = mount(win, { status: "done", text: "a" });
  const regenerate = done.querySelector(".ai-explanation-action");
  let bubbled = false;
  win.document.getElementById("entries-container").addEventListener("click", () => {
    bubbled = true;
  });
  regenerate.dispatchEvent(new win.MouseEvent("click", { bubbles: true, cancelable: true }));
  // 逐字段比对而不是 deepEqual：payload 是在 jsdom 那个 realm 里造的，
  // 严格深比较会因为 prototype 不同一而失败，和内容无关。
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, "aiExplainAction");
  assert.equal(calls[0].payload.action, "regenerate");
  assert.equal(bubbled, false, "点按钮不应触发弹窗的点击处理（会关掉弹窗或换词）");

  done.remove();
  calls.length = 0;
  const streaming = mount(win, { status: "streaming", text: "a" });
  streaming
    .querySelector(".ai-explanation-action")
    .dispatchEvent(new win.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].payload.action, "cancel");
});

test("流式更新只改文本节点，不换 DOM 结构", async () => {
  // 这是整个区块最要紧的一条：每个 chunk 都重建 DOM 会把用户正在拖的选择清掉，
  // 而制卡的 {popup-selection-text} 全靠那个选择。节点同一性就是选择能活下来的机制。
  const { win } = createPopup();
  const box = mount(win, { status: "streaming", text: "Hel" });
  const node = box.querySelector('[data-ai-role="text"]');

  win.__fushiAiUpdate({ status: "streaming", text: "Hello" });
  await new Promise((r) => win.requestAnimationFrame(() => r()));

  const after = win.document.querySelector('[data-ai-role="text"]');
  assert.equal(after, node, "文本节点必须是同一个元素");
  assert.equal(after.textContent, "Hello");
  assert.equal(
    win.document.querySelectorAll(".ai-explanation").length,
    1,
    "不应出现第二个盒子",
  );
});

test("同一帧内的多个 chunk 合并成一次写入", async () => {
  // provider 一秒能推几十个 chunk；每个都同步写一次会在低端机上掉帧。
  const { win } = createPopup();
  const box = mount(win, { status: "streaming", text: "a" });
  const node = box.querySelector('[data-ai-role="text"]');
  let writes = 0;
  Object.defineProperty(node, "textContent", {
    set(v) {
      writes += 1;
      this.__v = v;
    },
    get() {
      return this.__v;
    },
    configurable: true,
  });

  win.__fushiAiUpdate({ status: "streaming", text: "ab" });
  win.__fushiAiUpdate({ status: "streaming", text: "abc" });
  win.__fushiAiUpdate({ status: "streaming", text: "abcd" });
  await new Promise((r) => win.requestAnimationFrame(() => r()));

  assert.equal(writes, 1, "三个 chunk 只应写一次");
  assert.equal(node.textContent, "abcd", "写的是最后那个值");
});

test("状态类别变化时整块重建，按钮跟着换", async () => {
  const { win } = createPopup();
  mount(win, { status: "streaming", text: "partial" });
  win.__fushiAiUpdate({ status: "done", text: "final" });

  const box = win.document.querySelector(".ai-explanation");
  assert.equal(box.getAttribute("data-status"), "done");
  assert.deepEqual(actionsOf(box), ["↻"], "流式结束后取消要换成重新生成");
  assert.equal(bodyOf(box), "final");
});

test("换词清空状态，不串到下一个词", async () => {
  // 热槽 WebView 跨查词不重载页面，一次性镜像不清就会串味。
  const { win } = createPopup();
  mount(win, { status: "done", text: "previous word" });
  win.resetAiExplanation();
  assert.equal(win.__fushiAiState, null);
  assert.equal(win.buildAiExplanationBox(), null);
});

test("只有 done 态的文本能进 Anki", () => {
  // 「正在生成……」「请求超时」进了卡片就是永久污染，而且当时不会有人发现。
  const { win } = createPopup();
  for (const status of ["loading", "streaming", "failed", "timedOut", "manual", "notConfigured"]) {
    win.__fushiAiState = { status, text: "占位或半截文本" };
    assert.equal(win.__fushiAiFinalText(), "", `${status} 不得导出`);
  }
  win.__fushiAiState = { status: "done", text: "the answer" };
  assert.equal(win.__fushiAiFinalText(), "the answer");
  win.__fushiAiState = null;
  assert.equal(win.__fushiAiFinalText(), "");
});

test("模型输出按纯文本处理，不当 HTML 渲染", () => {
  // 模型完全可能吐出尖括号；innerHTML 一用就是注入面。
  const { win } = createPopup();
  const box = mount(win, { status: "done", text: "<img src=x onerror=alert(1)>" });
  const node = box.querySelector('[data-ai-role="text"]');
  assert.equal(node.querySelector("img"), null, "不应真的造出元素");
  assert.equal(node.textContent, "<img src=x onerror=alert(1)>");
});

test("保留换行与 Unicode", () => {
  const { win } = createPopup();
  const text = "一行\n二行\n\n猫が好きです 🐱";
  const box = mount(win, { status: "done", text });
  assert.equal(bodyOf(box), text);
});
