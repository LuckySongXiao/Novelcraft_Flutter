import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:novelcraft/application/services/agent_module_contract.dart';

void main() {
  test('all modules expose the same bounded JSON contract', () {
    for (final AgentModule module in AgentModule.values) {
      final AgentModuleContract contract = AgentModuleContracts.forModule(module);
      final Map<String, dynamic> json = jsonDecode(contract.template) as Map<String, dynamic>;
      expect(json['module'], module.name);
      expect(json['input'], contains('content'));
      expect((json['output'] as Map<String, dynamic>)['updates'], isNotEmpty);
      expect(json['allowedFields'], contains('history'));
    }
  });
}
