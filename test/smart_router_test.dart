import 'package:ai_chat_app/services/smart_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// F4 智能路由（规则版）单测：max 触发词 / 短消息 low / 默认 high
void main() {
  group('SmartRouter 规则决策', () {
    test('max 触发词命中：深入/推理/证明/代码/为什么', () {
      expect(SmartRouter.route('深入讲讲这个架构'), 'max');
      expect(SmartRouter.route('帮我推理一下'), 'max');
      expect(SmartRouter.route('证明这个定理'), 'max');
      expect(SmartRouter.route('写一段代码'), 'max');
      expect(SmartRouter.route('为什么会这样'), 'max');
      expect(SmartRouter.route('帮我调试这个报错'), 'max');
    });

    test('短消息（≤12 字）且无工具意图 → low', () {
      expect(SmartRouter.route('你好'), 'low');
      expect(SmartRouter.route('谢谢'), 'low');
      expect(SmartRouter.route('你好呀'), 'low');
      expect(SmartRouter.route('把这句话翻译成英文'), 'low'); // 9 字无工具词
    });

    test('短消息但含工具意图动词 → 不判 low（high 兜底）', () {
      expect(SmartRouter.route('现在几点'), 'high');
      expect(SmartRouter.route('帮我查一下天气'), 'high');
      expect(SmartRouter.route('记住我喜欢简洁'), 'high');
    });

    test('长消息（>12 字）无触发词 → 默认 high', () {
      expect(SmartRouter.route('帮我把这段话润色一下，语气正式一点'), 'high');
    });

    test('附件消息直接 max（视觉/文档理解）', () {
      expect(SmartRouter.route('这是什么', hasAttachments: true), 'max');
    });

    test('斜杠命令不判 low（工具/命令路由）', () {
      expect(SmartRouter.route('/翻译 你好'), 'high');
    });

    test('空消息回退 high', () {
      expect(SmartRouter.route(''), 'high');
      expect(SmartRouter.route('   '), 'high');
    });

    test('触发词在长句中间也命中（contains 语义）', () {
      expect(SmartRouter.route('我想让你帮我优化一下这段文字的表达'), 'max');
    });
  });
}
