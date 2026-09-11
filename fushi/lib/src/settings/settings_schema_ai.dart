/// 查词设置里的「AI 解释」分区（BYOK）。
///
/// 完整契约见 [docs/agent/ai-explanation.md](../../../docs/agent/ai-explanation.md)；
/// 这里只负责把那套配置摆成设置行。
///
/// 分区结构对齐参考实现的设置页：一个 provider 选择，四组各自的字段按当前 provider
/// 显隐（对应参考实现的 `_updateProviderVisibility`），再加一组通用行为与提示词。
/// 显隐用 item 自带的 `visible` 闭包——它在**渲染时**求值，不会破坏 schema 树按
/// locale 的缓存（`settings_schema_cache_test.dart` 钉死了这条）。
library;

import 'package:flutter/material.dart';
import 'package:fushi/src/ai/ai_prompt_renderer.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_request_builder.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 当前选中的 provider。
AiProvider _provider(SettingsContext c) =>
    c.appModel.aiSettings.read().provider;

bool _isOpenAi(SettingsContext c) => _provider(c) == AiProvider.openai;
bool _isGemini(SettingsContext c) => _provider(c) == AiProvider.gemini;
bool _isDeepSeek(SettingsContext c) => _provider(c) == AiProvider.deepseek;
bool _isCustom(SettingsContext c) => _provider(c) == AiProvider.custom;

/// 自定义端点是否指向 OpenRouter。
///
/// OpenRouter 专属的三行（路由策略 / provider 标识 / 允许兜底）在别的端点上是**惰性
/// 的**——请求构造器会整段跳过它们。摆出来只会让人以为配了有用，所以按真实判据显隐，
/// 与出站那条判据同源（`AiRequestBuilder.isOpenRouterEndpoint`，按注册域名匹配，不是
/// 子串）。
bool _isOpenRouter(SettingsContext c) =>
    _isCustom(c) &&
    AiRequestBuilder.isOpenRouterEndpoint(
      c.appModel.aiSettings.read().customEndpoint,
    );

/// 思考强度选到「自定义」时才需要那个自由值输入框。
bool _needsThinkingValue(SettingsContext c) =>
    _isCustom(c) &&
    c.appModel.aiSettings.read().customThinkingIntensity ==
        AiThinkingIntensity.custom;

List<SettingsSegmentOption<AiThinkingMode>> _thinkingModeOptions() =>
    <SettingsSegmentOption<AiThinkingMode>>[
      SettingsSegmentOption<AiThinkingMode>(
        value: AiThinkingMode.unset,
        label: t.ai_explain_option_default,
      ),
      SettingsSegmentOption<AiThinkingMode>(
        value: AiThinkingMode.enabled,
        label: t.ai_explain_option_enabled,
      ),
      SettingsSegmentOption<AiThinkingMode>(
        value: AiThinkingMode.disabled,
        label: t.ai_explain_option_disabled,
      ),
    ];

List<SettingsSegmentOption<AiThinkingIntensity>> _thinkingIntensityOptions({
  required bool withCustom,
}) => <SettingsSegmentOption<AiThinkingIntensity>>[
  SettingsSegmentOption<AiThinkingIntensity>(
    value: AiThinkingIntensity.unset,
    label: t.ai_explain_option_default,
  ),
  SettingsSegmentOption<AiThinkingIntensity>(
    value: AiThinkingIntensity.high,
    label: t.ai_explain_option_high,
  ),
  SettingsSegmentOption<AiThinkingIntensity>(
    value: AiThinkingIntensity.max,
    label: t.ai_explain_option_max,
  ),
  if (withCustom)
    SettingsSegmentOption<AiThinkingIntensity>(
      value: AiThinkingIntensity.custom,
      label: t.ai_explain_option_custom,
    ),
];

/// 「AI 解释」分区。
///
/// 默认折叠：绝大多数用户不配 AI，展开会把查词分类顶得很长。
SettingsSection buildAiExplanationSection() {
  return SettingsSection(
    id: 'lookup.section.ai_explain',
    title: t.ai_explain_section,
    footer: t.ai_explain_section_hint,
    presentation: SettingsSectionPresentation.collapsed,
    items: <SettingsItem>[
      // ---- provider ----
      SettingsSegmentedItem<AiProvider>(
        id: 'lookup.ai_explain.provider',
        title: t.ai_explain_provider,
        subtitle: t.ai_explain_provider_hint,
        icon: Icons.auto_awesome_outlined,
        dropdown: true,
        options: const <SettingsSegmentOption<AiProvider>>[
          SettingsSegmentOption<AiProvider>(
            value: AiProvider.openai,
            label: 'OpenAI',
          ),
          SettingsSegmentOption<AiProvider>(
            value: AiProvider.gemini,
            label: 'Google Gemini',
          ),
          SettingsSegmentOption<AiProvider>(
            value: AiProvider.deepseek,
            label: 'DeepSeek',
          ),
          SettingsSegmentOption<AiProvider>(
            value: AiProvider.custom,
            label: 'Custom (OpenAI-compatible)',
          ),
        ],
        selected: _provider,
        onChanged: (SettingsContext c, AiProvider value) async {
          await c.appModel.aiSettings.setProvider(value);
          c.refresh();
        },
      ),

      // ---- 凭据：一行，按当前 provider 读写对应的 key ----
      SettingsTextItem(
        id: 'lookup.ai_explain.api_key',
        title: t.ai_explain_api_key,
        subtitle: t.ai_explain_api_key_hint,
        icon: Icons.key_outlined,
        secret: true,
        value: (SettingsContext c) =>
            c.appModel.aiCredentials.readApiKey(_provider(c)),
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiCredentials.writeApiKey(_provider(c), value);
          c.refresh();
        },
      ),

      // ---- 模型 ----
      //
      // 参考实现给 OpenAI / Gemini 摆的是写死的下拉（11 个 Gemini 条目里已经混着
      // preview 名），但 BYOK 用户必须能用上 app 没听说过的模型，写死的清单只会过期。
      // 这里统一用文本框 + 占位提示 + 一键重置成默认值（见 §8 的偏离说明）。
      SettingsTextItem(
        id: 'lookup.ai_explain.openai_model',
        title: t.ai_explain_model,
        subtitle: t.ai_explain_model_hint,
        icon: Icons.memory_outlined,
        visible: _isOpenAi,
        placeholder: AiDefaults.openaiModel,
        resetValue: (SettingsContext c) => AiDefaults.openaiModel,
        value: (SettingsContext c) => c.appModel.aiSettings.read().openaiModel,
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiSettings.setOpenaiModel(value);
          c.refresh();
        },
      ),
      SettingsTextItem(
        id: 'lookup.ai_explain.gemini_model',
        title: t.ai_explain_model,
        subtitle: t.ai_explain_model_hint,
        icon: Icons.memory_outlined,
        visible: _isGemini,
        placeholder: AiDefaults.geminiModel,
        resetValue: (SettingsContext c) => AiDefaults.geminiModel,
        value: (SettingsContext c) => c.appModel.aiSettings.read().geminiModel,
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiSettings.setGeminiModel(value);
          c.refresh();
        },
      ),
      SettingsTextItem(
        id: 'lookup.ai_explain.deepseek_model',
        title: t.ai_explain_model,
        subtitle: t.ai_explain_model_hint,
        icon: Icons.memory_outlined,
        visible: _isDeepSeek,
        placeholder: 'deepseek-chat',
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().deepseekModel,
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiSettings.setDeepseekModel(value);
          c.refresh();
        },
      ),
      SettingsTextItem(
        id: 'lookup.ai_explain.custom_model',
        title: t.ai_explain_model,
        subtitle: t.ai_explain_model_hint,
        icon: Icons.memory_outlined,
        visible: _isCustom,
        placeholder: 'vendor/model',
        value: (SettingsContext c) => c.appModel.aiSettings.read().customModel,
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiSettings.setCustomModel(value);
          c.refresh();
        },
      ),

      // ---- Gemini 思考级别 ----
      SettingsSegmentedItem<AiGeminiThinkingLevel>(
        id: 'lookup.ai_explain.gemini_thinking',
        title: t.ai_explain_thinking_level,
        icon: Icons.psychology_outlined,
        visible: _isGemini,
        dropdown: true,
        options: <SettingsSegmentOption<AiGeminiThinkingLevel>>[
          SettingsSegmentOption<AiGeminiThinkingLevel>(
            value: AiGeminiThinkingLevel.unset,
            label: t.ai_explain_option_default,
          ),
          SettingsSegmentOption<AiGeminiThinkingLevel>(
            value: AiGeminiThinkingLevel.minimal,
            label: t.ai_explain_option_minimal,
          ),
          SettingsSegmentOption<AiGeminiThinkingLevel>(
            value: AiGeminiThinkingLevel.low,
            label: t.ai_explain_option_low,
          ),
          SettingsSegmentOption<AiGeminiThinkingLevel>(
            value: AiGeminiThinkingLevel.medium,
            label: t.ai_explain_option_medium,
          ),
          SettingsSegmentOption<AiGeminiThinkingLevel>(
            value: AiGeminiThinkingLevel.high,
            label: t.ai_explain_option_high,
          ),
        ],
        selected: (SettingsContext c) =>
            c.appModel.aiSettings.read().geminiThinkingLevel,
        onChanged: (SettingsContext c, AiGeminiThinkingLevel value) async {
          await c.appModel.aiSettings.setGeminiThinkingLevel(value);
          c.refresh();
        },
      ),

      // ---- DeepSeek 思考 ----
      SettingsSegmentedItem<AiThinkingMode>(
        id: 'lookup.ai_explain.deepseek_thinking_mode',
        title: t.ai_explain_thinking_mode,
        icon: Icons.psychology_outlined,
        visible: _isDeepSeek,
        dropdown: true,
        options: _thinkingModeOptions(),
        selected: (SettingsContext c) =>
            c.appModel.aiSettings.read().deepseekThinkingMode,
        onChanged: (SettingsContext c, AiThinkingMode value) async {
          await c.appModel.aiSettings.setDeepseekThinkingMode(value);
          c.refresh();
        },
      ),
      SettingsSegmentedItem<AiThinkingIntensity>(
        id: 'lookup.ai_explain.deepseek_thinking_intensity',
        title: t.ai_explain_thinking_intensity,
        icon: Icons.tune_outlined,
        visible: _isDeepSeek,
        dropdown: true,
        options: _thinkingIntensityOptions(withCustom: false),
        selected: (SettingsContext c) =>
            c.appModel.aiSettings.read().deepseekThinkingIntensity,
        onChanged: (SettingsContext c, AiThinkingIntensity value) async {
          await c.appModel.aiSettings.setDeepseekThinkingIntensity(value);
          c.refresh();
        },
      ),

      // ---- 自定义端点 ----
      SettingsTextItem(
        id: 'lookup.ai_explain.endpoint',
        title: t.ai_explain_endpoint,
        subtitle: t.ai_explain_endpoint_hint,
        icon: Icons.link_outlined,
        visible: _isCustom,
        placeholder: 'https://api.example.com/v1/chat/completions',
        keyboardType: TextInputType.url,
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().customEndpoint,
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiSettings.setCustomEndpoint(value);
          // 端点决定 OpenRouter 三行的显隐，所以必须刷新整页。
          c.refresh();
        },
      ),

      // ---- OpenRouter 路由（仅当端点真是 OpenRouter）----
      SettingsSegmentedItem<AiProviderRoutingMode>(
        id: 'lookup.ai_explain.routing_mode',
        title: t.ai_explain_routing_mode,
        icon: Icons.alt_route_outlined,
        visible: _isOpenRouter,
        dropdown: true,
        options: <SettingsSegmentOption<AiProviderRoutingMode>>[
          SettingsSegmentOption<AiProviderRoutingMode>(
            value: AiProviderRoutingMode.unset,
            label: t.ai_explain_option_default,
          ),
          SettingsSegmentOption<AiProviderRoutingMode>(
            value: AiProviderRoutingMode.order,
            label: t.ai_explain_routing_prioritize,
          ),
          SettingsSegmentOption<AiProviderRoutingMode>(
            value: AiProviderRoutingMode.only,
            label: t.ai_explain_routing_only,
          ),
          SettingsSegmentOption<AiProviderRoutingMode>(
            value: AiProviderRoutingMode.ignore,
            label: t.ai_explain_routing_ignore,
          ),
        ],
        selected: (SettingsContext c) =>
            c.appModel.aiSettings.read().customRoutingMode,
        onChanged: (SettingsContext c, AiProviderRoutingMode value) async {
          await c.appModel.aiSettings.setCustomRoutingMode(value);
          c.refresh();
        },
      ),
      SettingsTextItem(
        id: 'lookup.ai_explain.routing_slugs',
        title: t.ai_explain_routing_slugs,
        subtitle: t.ai_explain_routing_slugs_hint,
        icon: Icons.dns_outlined,
        visible: _isOpenRouter,
        placeholder: 'deepinfra/turbo, fireworks',
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().customRoutingSlugs,
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiSettings.setCustomRoutingSlugs(value);
        },
      ),
      SettingsSwitchItem(
        id: 'lookup.ai_explain.allow_fallbacks',
        title: t.ai_explain_allow_fallbacks,
        icon: Icons.backup_outlined,
        visible: _isOpenRouter,
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().customAllowFallbacks,
        onChanged: (SettingsContext c, bool value) async {
          await c.appModel.aiSettings.setCustomAllowFallbacks(value);
          c.refresh();
        },
      ),

      // ---- 自定义端点的思考选项 ----
      SettingsSegmentedItem<AiThinkingMode>(
        id: 'lookup.ai_explain.custom_thinking_mode',
        title: t.ai_explain_thinking_mode,
        icon: Icons.psychology_outlined,
        visible: _isCustom,
        dropdown: true,
        options: _thinkingModeOptions(),
        selected: (SettingsContext c) =>
            c.appModel.aiSettings.read().customThinkingMode,
        onChanged: (SettingsContext c, AiThinkingMode value) async {
          await c.appModel.aiSettings.setCustomThinkingMode(value);
          c.refresh();
        },
      ),
      SettingsSegmentedItem<AiThinkingIntensity>(
        id: 'lookup.ai_explain.custom_thinking_intensity',
        title: t.ai_explain_thinking_intensity,
        icon: Icons.tune_outlined,
        visible: _isCustom,
        dropdown: true,
        options: _thinkingIntensityOptions(withCustom: true),
        selected: (SettingsContext c) =>
            c.appModel.aiSettings.read().customThinkingIntensity,
        onChanged: (SettingsContext c, AiThinkingIntensity value) async {
          await c.appModel.aiSettings.setCustomThinkingIntensity(value);
          // 选到「自定义」才出自由值输入框。
          c.refresh();
        },
      ),
      SettingsTextItem(
        id: 'lookup.ai_explain.custom_thinking_value',
        title: t.ai_explain_thinking_value,
        subtitle: t.ai_explain_thinking_value_hint,
        icon: Icons.edit_outlined,
        visible: _needsThinkingValue,
        placeholder: 'medium, 2000, or {"max_tokens":2000}',
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().customThinkingValue,
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiSettings.setCustomThinkingValue(value);
        },
      ),

      // ---- 自定义请求体 ----
      //
      // 就地校验：非法 JSON 在这里说出来，用户还看着这个框；否则要等到下一次查词
      // 才在弹窗里看到一句「生成失败」，而那时错在哪根本无从判断。
      SettingsTextItem(
        id: 'lookup.ai_explain.request_body',
        title: t.ai_explain_request_body,
        subtitle: t.ai_explain_request_body_hint,
        icon: Icons.data_object_outlined,
        visible: _isCustom,
        placeholder: '{"reasoning":{"max_tokens":2000}}',
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().customRequestBodyJson,
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiSettings.setCustomRequestBodyJson(value);
          final String? error = validateAiRequestBodyJson(value);
          if (error != null && c.context.mounted) {
            ScaffoldMessenger.maybeOf(
              c.context,
            )?.showSnackBar(SnackBar(content: Text(error)));
          }
          c.refresh();
        },
      ),

      // ---- 通用行为 ----
      SettingsSwitchItem(
        id: 'lookup.ai_explain.auto_generate',
        title: t.ai_explain_auto_generate,
        subtitle: t.ai_explain_auto_generate_hint,
        icon: Icons.play_circle_outline,
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().autoGenerateOnLookup,
        onChanged: (SettingsContext c, bool value) async {
          await c.appModel.aiSettings.setAutoGenerate(value);
          c.refresh();
        },
      ),
      SettingsSwitchItem(
        id: 'lookup.ai_explain.stream',
        title: t.ai_explain_stream,
        subtitle: t.ai_explain_stream_hint,
        icon: Icons.bolt_outlined,
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().streamResponse,
        onChanged: (SettingsContext c, bool value) async {
          await c.appModel.aiSettings.setStreamResponse(value);
          c.refresh();
        },
      ),
      SettingsSwitchItem(
        id: 'lookup.ai_explain.cancel_pending',
        title: t.ai_explain_cancel_pending,
        subtitle: t.ai_explain_cancel_pending_hint,
        icon: Icons.cancel_outlined,
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().cancelPendingRequests,
        onChanged: (SettingsContext c, bool value) async {
          await c.appModel.aiSettings.setCancelPending(value);
          c.refresh();
        },
      ),
      SettingsSwitchItem(
        id: 'lookup.ai_explain.unknown_fallback',
        title: t.ai_explain_unknown_fallback,
        subtitle: t.ai_explain_unknown_fallback_hint,
        icon: Icons.help_outline,
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().unknownWordFallback,
        onChanged: (SettingsContext c, bool value) async {
          await c.appModel.aiSettings.setUnknownWordFallback(value);
          c.refresh();
        },
      ),

      // ---- 提示词 ----
      SettingsTextItem(
        id: 'lookup.ai_explain.prompt',
        title: t.ai_explain_prompt,
        subtitle: t.ai_explain_prompt_hint,
        icon: Icons.chat_outlined,
        placeholder: kAiDefaultUserPrompt,
        resetValue: (SettingsContext c) => kAiDefaultUserPrompt,
        value: (SettingsContext c) => c.appModel.aiSettings.read().userPrompt,
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiSettings.setUserPrompt(value);
        },
      ),
      SettingsTextItem(
        id: 'lookup.ai_explain.system_prompt',
        title: t.ai_explain_system_prompt,
        subtitle: t.ai_explain_system_prompt_hint,
        icon: Icons.rule_outlined,
        value: (SettingsContext c) => c.appModel.aiSettings.read().systemPrompt,
        onChanged: (SettingsContext c, String value) async {
          await c.appModel.aiSettings.setSystemPrompt(value);
        },
      ),
      SettingsTextItem(
        id: 'lookup.ai_explain.temperature',
        title: t.ai_explain_temperature,
        subtitle: t.ai_explain_temperature_hint,
        icon: Icons.thermostat_outlined,
        placeholder: '0.7',
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        resetValue: (SettingsContext c) => AiDefaults.temperature.toString(),
        value: (SettingsContext c) =>
            c.appModel.aiSettings.read().temperature.toString(),
        onChanged: (SettingsContext c, String value) async {
          // 逗号小数点：很多地区就是这么打的，参考实现的设置页也接受。
          final double? parsed = double.tryParse(
            value.trim().replaceAll(',', '.'),
          );
          await c.appModel.aiSettings.setTemperature(
            parsed ?? AiDefaults.temperature,
          );
          c.refresh();
        },
      ),
    ],
  );
}
