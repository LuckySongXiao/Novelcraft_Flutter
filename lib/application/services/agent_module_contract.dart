import 'dart:convert';

enum AgentModule {
  project,
  volume,
  chapter,
  character,
  faction,
  plot,
  world,
  timeline,
  race,
  resource,
  realm,
  cultivation,
  political,
  currency,
  relationship,
}

class AgentModuleContract {
  const AgentModuleContract(this.module, this.name, this.fields);
  final AgentModule module;
  final String name;
  final List<String> fields;

  Map<String, Object?> toJson() => <String, Object?>{
        'module': name,
        'input': <String>['projectId', 'chapterId', 'content', 'context'],
        'output': <String, Object?>{
          'updates': <Object?>[
            <String, String>{
              'action': 'create|update',
              'name': 'exact entity name',
              'field': fields.first,
              'value': 'new value',
              'evidence': 'verbatim sentence from content',
            },
          ],
        },
        'allowedFields': fields,
      };

  String get template => const JsonEncoder.withIndent('  ').convert(toJson());
}

abstract final class AgentModuleContracts {
  static const List<String> commonFields = <String>[
    'status',
    'description',
    'content',
    'notes',
    'history',
  ];

  static final Map<AgentModule, AgentModuleContract> all = <AgentModule, AgentModuleContract>{
    for (final AgentModule module in AgentModule.values)
      module: AgentModuleContract(module, module.name, commonFields),
  };

  static AgentModuleContract forModule(AgentModule module) => all[module]!;
}
