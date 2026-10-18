// Generates assets/transforms/pt.json and assets/transforms/it.json.
//
// Neither language has a Yomitan transform table to port, so the tables are
// written here from the conjugation and declension paradigms and serialised in
// the same descriptor format as the ported ones (es.json is the closest
// sibling). The engine loads every table at once and stays language-agnostic:
// a rule only produces a result when a dictionary actually has the lemma it
// points at, with a matching part of speech.
//
// Usage (from fushi/): dart run tool/gen_romance_transforms.dart
import 'dart:convert';
import 'dart:io';

typedef Rule = Map<String, Object>;

class TransformTable {
  TransformTable(this.language, this.conditions);

  final String language;
  final Map<String, Object> conditions;
  final Map<String, Map<String, Object>> _transforms =
      <String, Map<String, Object>>{};

  _Transform transform(String name, String description) {
    final _Transform t = _Transform();
    _transforms[name] = <String, Object>{
      'name': name,
      'description': description,
      'rules': t.rules,
    };
    return t;
  }

  String encode() => jsonEncode(<String, Object>{
    'language': language,
    'conditions': conditions,
    'transforms': _transforms,
  });
}

class _Transform {
  final List<Rule> rules = <Rule>[];
  final Set<String> _seen = <String>{};

  void _add(Rule rule) {
    if (_seen.add(jsonEncode(rule))) rules.add(rule);
  }

  void suffix(String from, String to, List<String> into, List<String> out) {
    if (from == to) return;
    _add(<String, Object>{
      'type': 'suffix',
      'fromSuffix': from,
      'toSuffix': to,
      'conditionsIn': into,
      'conditionsOut': out,
    });
  }

  void whole(String from, String to, List<String> into, List<String> out) {
    if (from == to) return;
    _add(<String, Object>{
      'type': 'wholeWord',
      'from': from,
      'to': to,
      'conditionsIn': into,
      'conditionsOut': out,
    });
  }

  void prefix(String from, String to, List<String> into, List<String> out) {
    _add(<String, Object>{
      'type': 'prefix',
      'fromPrefix': from,
      'toPrefix': to,
      'conditionsIn': into,
      'conditionsOut': out,
    });
  }

  /// Regular endings of one verb class: every form maps back to the
  /// infinitive ending and keeps the class condition, so the result can chain.
  void endings(String infinitive, List<String> forms, String condition) {
    for (final String f in forms) {
      suffix(f, infinitive, <String>[condition], <String>[condition]);
    }
  }

  /// Irregular forms of one verb. Suffix rules let compounds share them
  /// (desfazer, mantenho, compongo); whole-word rules are used for forms too
  /// short to be safe as a suffix.
  void irregular(String lemma, List<String> forms, {bool asSuffix = false}) {
    for (final String f in forms) {
      if (asSuffix) {
        suffix(f, lemma, const <String>['v'], const <String>['v']);
      } else {
        whole(f, lemma, const <String>['v'], const <String>['v']);
      }
    }
  }
}

const List<String> _v = <String>['v'];
const List<String> _adj = <String>['adj'];

// ---------------------------------------------------------------------------
// Portuguese (Brazilian and European forms)
// ---------------------------------------------------------------------------

TransformTable portuguese() {
  final TransformTable table = TransformTable('pt', <String, Object>{
    'n': <String, Object>{
      'name': 'Noun',
      'isDictionaryForm': true,
      'subConditions': <String>['ns', 'np'],
    },
    'ns': <String, Object>{'name': 'Noun singular', 'isDictionaryForm': false},
    'np': <String, Object>{'name': 'Noun plural', 'isDictionaryForm': false},
    'v': <String, Object>{
      'name': 'Verb',
      'isDictionaryForm': true,
      'subConditions': <String>['v_ar', 'v_er', 'v_ir'],
    },
    'v_ar': <String, Object>{'name': '-ar verb', 'isDictionaryForm': false},
    'v_er': <String, Object>{'name': '-er verb', 'isDictionaryForm': false},
    'v_ir': <String, Object>{'name': '-ir verb', 'isDictionaryForm': false},
    'adj': <String, Object>{'name': 'Adjective', 'isDictionaryForm': true},
    'adv': <String, Object>{'name': 'Adverb', 'isDictionaryForm': true},
  });

  const List<(String, String)> plurals = <(String, String)>[
    ('s', ''),
    ('es', ''),
    ('ões', 'ão'),
    ('ães', 'ão'),
    ('ais', 'al'),
    ('éis', 'el'),
    ('eis', 'el'),
    ('eis', 'il'),
    ('óis', 'ol'),
    ('uis', 'ul'),
    ('is', 'il'),
    ('ns', 'm'),
    ('eses', 'ês'),
    ('ases', 'ás'),
    ('oses', 'ós'),
  ];
  final _Transform plural = table.transform('plural', 'Plural form of a noun');
  for (final (String from, String to) in plurals) {
    plural.suffix(from, to, const <String>['np'], const <String>['ns']);
  }
  final _Transform pluralAdj = table.transform(
    'plural adjective',
    'Plural form of an adjective',
  );
  for (final (String from, String to) in plurals) {
    pluralAdj.suffix(from, to, _adj, _adj);
  }

  final _Transform feminine =
      table.transform('feminine adjective', 'feminine form of an adjective')
        ..suffix('a', 'o', _adj, _adj)
        ..suffix('a', '', _adj, _adj)
        ..suffix('ã', 'ão', _adj, _adj)
        ..suffix('ona', 'ão', _adj, _adj)
        ..suffix('esa', 'ês', _adj, _adj)
        ..suffix('ora', 'or', _adj, _adj)
        ..suffix('eia', 'eu', _adj, _adj);
  feminine
    ..whole('boa', 'bom', _adj, _adj)
    ..whole('má', 'mau', _adj, _adj);

  table.transform('superlative', 'Superlative form of an adjective')
    ..suffix('íssimo', 'o', _adj, _adj)
    ..suffix('íssimo', 'e', _adj, _adj)
    ..suffix('íssimo', '', _adj, _adj);

  table.transform('diminutive', 'Diminutive form of a word')
    ..suffix(
      'inho',
      'o',
      const <String>['n', 'adj'],
      const <String>['n', 'adj'],
    )
    ..suffix(
      'inha',
      'a',
      const <String>['n', 'adj'],
      const <String>['n', 'adj'],
    )
    ..suffix(
      'zinho',
      '',
      const <String>['n', 'adj'],
      const <String>['n', 'adj'],
    )
    ..suffix(
      'zinha',
      '',
      const <String>['n', 'adj'],
      const <String>['n', 'adj'],
    );

  table.transform('adverb', 'Adverb form of an adjective')
    ..suffix('amente', 'o', const <String>['adv'], _adj)
    ..suffix('mente', '', const <String>['adv'], _adj);

  table.transform('present indicative', 'Present indicative form of a verb')
    ..endings('ar', <String>['o', 'as', 'a', 'amos', 'ais', 'am'], 'v_ar')
    ..endings('er', <String>['o', 'es', 'e', 'emos', 'eis', 'em'], 'v_er')
    ..endings('ir', <String>['o', 'es', 'e', 'imos', 'is', 'em'], 'v_ir')
    // Spelling changes before -o / -a.
    ..endings('cer', <String>['ço'], 'v_er')
    ..endings('cir', <String>['ço'], 'v_ir')
    ..endings('ger', <String>['jo'], 'v_er')
    ..endings('gir', <String>['jo'], 'v_ir')
    ..endings('guer', <String>['go'], 'v_er')
    ..endings('guir', <String>['go'], 'v_ir')
    // -ear: passeio, passeias, passeia, passeiam.
    ..endings('ear', <String>['eio', 'eias', 'eia', 'eiam'], 'v_ar')
    // -uir: possui.
    ..endings('uir', <String>['ui'], 'v_ir')
    // Stem-changing -ir verbs: sinto, sigo, sirvo, prefiro, durmo, cubro,
    // sobe, foge, visto, repito.
    ..endings('entir', <String>['into'], 'v_ir')
    ..endings('eguir', <String>['igo'], 'v_ir')
    ..endings('ervir', <String>['irvo'], 'v_ir')
    ..endings('erir', <String>['iro'], 'v_ir')
    ..endings('estir', <String>['isto'], 'v_ir')
    ..endings('etir', <String>['ito'], 'v_ir')
    ..endings('ormir', <String>['urmo'], 'v_ir')
    ..endings('obrir', <String>['ubro'], 'v_ir')
    ..endings('ubir', <String>['obes', 'obe', 'obem'], 'v_ir')
    ..endings('ugir', <String>['ujo', 'oges', 'oge', 'ogem'], 'v_ir')
    ..endings('edir', <String>['eço'], 'v_ir')
    ..endings('erder', <String>['erco'], 'v_er')
    ..endings('aler', <String>['alho'], 'v_er')
    ..endings('air', <String>[
      'aio',
      'ais',
      'ai',
      'aímos',
      'aís',
      'aem',
    ], 'v_ir');

  table.transform('preterite', 'Preterite (past) form of a verb')
    ..endings('ar', <String>[
      'ei',
      'aste',
      'ou',
      'amos',
      'ámos',
      'astes',
      'aram',
    ], 'v_ar')
    ..endings('er', <String>[
      'i',
      'este',
      'eu',
      'emos',
      'estes',
      'eram',
    ], 'v_er')
    ..endings('ir', <String>[
      'i',
      'iste',
      'iu',
      'imos',
      'istes',
      'iram',
    ], 'v_ir')
    ..endings('car', <String>['quei'], 'v_ar')
    ..endings('gar', <String>['guei'], 'v_ar')
    ..endings('çar', <String>['cei'], 'v_ar')
    ..endings('air', <String>[
      'aí',
      'aíste',
      'aiu',
      'aímos',
      'aístes',
      'aíram',
    ], 'v_ir');

  table.transform('imperfect', 'Imperfect form of a verb')
    ..endings('ar', <String>['ava', 'avas', 'ávamos', 'áveis', 'avam'], 'v_ar')
    ..endings('er', <String>['ia', 'ias', 'íamos', 'íeis', 'iam'], 'v_er')
    ..endings('ir', <String>['ia', 'ias', 'íamos', 'íeis', 'iam'], 'v_ir')
    ..endings('air', <String>[
      'aía',
      'aías',
      'aíamos',
      'aíeis',
      'aíam',
    ], 'v_ir');

  table.transform('pluperfect', 'Pluperfect form of a verb')
    ..endings('ar', <String>['ara', 'aras', 'áramos', 'áreis', 'aram'], 'v_ar')
    ..endings('er', <String>['era', 'eras', 'êramos', 'êreis', 'eram'], 'v_er')
    ..endings('ir', <String>['ira', 'iras', 'íramos', 'íreis', 'iram'], 'v_ir');

  final _Transform future = table.transform('future', 'Future form of a verb');
  final _Transform conditional = table.transform(
    'conditional',
    'Conditional form of a verb',
  );
  for (final (String inf, String cond) in const <(String, String)>[
    ('ar', 'v_ar'),
    ('er', 'v_er'),
    ('ir', 'v_ir'),
  ]) {
    future.endings(inf, <String>[
      for (final String e in <String>['ei', 'ás', 'á', 'emos', 'eis', 'ão'])
        '$inf$e',
    ], cond);
    conditional.endings(inf, <String>[
      for (final String e in <String>['ia', 'ias', 'íamos', 'íeis', 'iam'])
        '$inf$e',
    ], cond);
  }

  table.transform('present subjunctive', 'Present subjunctive form of a verb')
    ..endings('ar', <String>['e', 'es', 'emos', 'eis', 'em'], 'v_ar')
    ..endings('er', <String>['a', 'as', 'amos', 'ais', 'am'], 'v_er')
    ..endings('ir', <String>['a', 'as', 'amos', 'ais', 'am'], 'v_ir')
    ..endings('car', <String>['que', 'ques', 'quemos', 'queis', 'quem'], 'v_ar')
    ..endings('gar', <String>['gue', 'gues', 'guemos', 'gueis', 'guem'], 'v_ar')
    ..endings('çar', <String>['ce', 'ces', 'cemos', 'ceis', 'cem'], 'v_ar')
    ..endings('ear', <String>['eie', 'eies', 'eiem'], 'v_ar')
    ..endings('cer', <String>['ça', 'ças', 'çamos', 'çais', 'çam'], 'v_er')
    ..endings('cir', <String>['ça', 'ças', 'çamos', 'çais', 'çam'], 'v_ir')
    ..endings('ger', <String>['ja', 'jas', 'jamos', 'jais', 'jam'], 'v_er')
    ..endings('gir', <String>['ja', 'jas', 'jamos', 'jais', 'jam'], 'v_ir')
    ..endings('guer', <String>['ga', 'gas', 'gamos', 'gais', 'gam'], 'v_er')
    ..endings('guir', <String>['ga', 'gas', 'gamos', 'gais', 'gam'], 'v_ir')
    ..endings('entir', <String>[
      'inta',
      'intas',
      'intamos',
      'intais',
      'intam',
    ], 'v_ir')
    ..endings('eguir', <String>[
      'iga',
      'igas',
      'igamos',
      'igais',
      'igam',
    ], 'v_ir')
    ..endings('ervir', <String>[
      'irva',
      'irvas',
      'irvamos',
      'irvais',
      'irvam',
    ], 'v_ir')
    ..endings('erir', <String>[
      'ira',
      'iras',
      'iramos',
      'irais',
      'iram',
    ], 'v_ir')
    ..endings('estir', <String>[
      'ista',
      'istas',
      'istamos',
      'istais',
      'istam',
    ], 'v_ir')
    ..endings('etir', <String>[
      'ita',
      'itas',
      'itamos',
      'itais',
      'itam',
    ], 'v_ir')
    ..endings('ormir', <String>[
      'urma',
      'urmas',
      'urmamos',
      'urmais',
      'urmam',
    ], 'v_ir')
    ..endings('obrir', <String>[
      'ubra',
      'ubras',
      'ubramos',
      'ubrais',
      'ubram',
    ], 'v_ir')
    ..endings('ugir', <String>[
      'uja',
      'ujas',
      'ujamos',
      'ujais',
      'ujam',
    ], 'v_ir')
    ..endings('edir', <String>[
      'eça',
      'eças',
      'eçamos',
      'eçais',
      'eçam',
    ], 'v_ir')
    ..endings('erder', <String>[
      'erca',
      'ercas',
      'ercamos',
      'ercais',
      'ercam',
    ], 'v_er')
    ..endings('aler', <String>[
      'alha',
      'alhas',
      'alhamos',
      'alhais',
      'alham',
    ], 'v_er')
    ..endings('air', <String>[
      'aia',
      'aias',
      'aiamos',
      'aiais',
      'aiam',
    ], 'v_ir');

  table.transform(
      'imperfect subjunctive',
      'Imperfect subjunctive form of a verb',
    )
    ..endings('ar', <String>[
      'asse',
      'asses',
      'ássemos',
      'ásseis',
      'assem',
    ], 'v_ar')
    ..endings('er', <String>[
      'esse',
      'esses',
      'êssemos',
      'êsseis',
      'essem',
    ], 'v_er')
    ..endings('ir', <String>[
      'isse',
      'isses',
      'íssemos',
      'ísseis',
      'issem',
    ], 'v_ir')
    ..endings('air', <String>[
      'aísse',
      'aísses',
      'aíssemos',
      'aísseis',
      'aíssem',
    ], 'v_ir');

  // The future subjunctive and the personal infinitive share their endings.
  table.transform('future subjunctive', 'Future subjunctive form of a verb')
    ..endings('ar', <String>['ares', 'armos', 'ardes', 'arem'], 'v_ar')
    ..endings('er', <String>['eres', 'ermos', 'erdes', 'erem'], 'v_er')
    ..endings('ir', <String>['ires', 'irmos', 'irdes', 'irem'], 'v_ir');

  table.transform('gerund', 'Gerund form of a verb')
    ..endings('ar', <String>['ando'], 'v_ar')
    ..endings('er', <String>['endo'], 'v_er')
    ..endings('ir', <String>['indo'], 'v_ir')
    ..endings('air', <String>['aindo'], 'v_ir')
    ..whole('pondo', 'pôr', _v, _v)
    ..suffix('pondo', 'por', _v, _v);

  final _Transform participle =
      table.transform('participle', 'Participle form of a verb')
        ..suffix('ado', 'ar', _adj, const <String>['v_ar'])
        ..suffix('ido', 'er', _adj, const <String>['v_er'])
        ..suffix('ido', 'ir', _adj, const <String>['v_ir'])
        ..suffix('aído', 'air', _adj, const <String>['v_ir']);
  for (final (String form, String lemma) in const <(String, String)>[
    ('feito', 'fazer'),
    ('dito', 'dizer'),
    ('visto', 'ver'),
    ('posto', 'por'),
    ('aberto', 'abrir'),
    ('escrito', 'escrever'),
    ('coberto', 'cobrir'),
    ('vindo', 'vir'),
    ('impresso', 'imprimir'),
    ('expresso', 'exprimir'),
    ('suspenso', 'suspender'),
  ]) {
    participle.suffix(form, lemma, _adj, _v);
  }
  for (final (String form, String lemma) in const <(String, String)>[
    ('posto', 'pôr'),
    ('ganho', 'ganhar'),
    ('gasto', 'gastar'),
    ('pago', 'pagar'),
    ('morto', 'morrer'),
    ('morto', 'matar'),
    ('entregue', 'entregar'),
    ('aceito', 'aceitar'),
    ('aceite', 'aceitar'),
    ('eleito', 'eleger'),
    ('preso', 'prender'),
    ('aceso', 'acender'),
    ('solto', 'soltar'),
    ('frito', 'fritar'),
    ('salvo', 'salvar'),
  ]) {
    participle.whole(form, lemma, _adj, _v);
  }

  // Hyphenated object and reflexive pronouns (disse-me, chama-se, fazê-lo).
  final _Transform clitic = table.transform(
    'attached pronoun',
    'Verb with an attached object or reflexive pronoun',
  );
  for (final String p in const <String>[
    'me', 'te', 'se', 'nos', 'vos', 'lhe', 'lhes', 'o', 'a', 'os', 'as', //
    'no', 'na', 'nas', 'lho', 'lha', 'lhos', 'lhas', 'mo', 'ma', 'to', 'ta',
  ]) {
    clitic.suffix('-$p', '', const <String>[], _v);
  }
  for (final String p in const <String>['lo', 'la', 'los', 'las']) {
    clitic
      ..suffix('á-$p', 'ar', const <String>[], const <String>['v_ar'])
      ..suffix('ê-$p', 'er', const <String>[], const <String>['v_er'])
      ..suffix('i-$p', 'ir', const <String>[], const <String>['v_ir'])
      ..suffix('ô-$p', 'or', const <String>[], _v)
      ..suffix('ô-$p', 'ôr', const <String>[], _v);
  }

  _portugueseIrregulars(
    table.transform('irregular', 'Irregular form of a verb'),
  );
  return table;
}

void _portugueseIrregulars(_Transform t) {
  t
    ..irregular('ser', <String>[
      'sou', 'és', 'é', 'somos', 'sois', 'são', //
      'fui', 'foste', 'foi', 'fomos', 'fostes', 'foram',
      'era', 'eras', 'éramos', 'éreis', 'eram',
      'fora', 'foras', 'fôramos', 'fôreis',
      'seja', 'sejas', 'sejamos', 'sejais', 'sejam',
      'fosse', 'fosses', 'fôssemos', 'fôsseis', 'fossem',
      'for', 'fores', 'formos', 'fordes', 'forem',
    ])
    ..irregular('estar', <String>[
      'estou', 'estás', 'está', 'estão', //
      'estive', 'estiveste', 'esteve', 'estivemos', 'estivestes', 'estiveram',
      'estivera', 'estiveras', 'estivéramos', 'estivéreis',
      'esteja', 'estejas', 'estejamos', 'estejais', 'estejam',
      'estivesse', 'estivesses', 'estivéssemos', 'estivésseis', 'estivessem',
      'estiver', 'estiveres', 'estivermos', 'estiverdes', 'estiverem',
      'tá', 'tô', 'tava', 'tavas', 'tavam',
    ])
    ..irregular('ter', <String>['tem', 'têm'])
    ..irregular('ter', <String>[
      'tenho', 'tens', 'tendes', //
      'tive', 'tiveste', 'teve', 'tivemos', 'tivestes', 'tiveram',
      'tinha', 'tinhas', 'tínhamos', 'tínheis', 'tinham',
      'tivera', 'tiveras', 'tivéramos', 'tivéreis',
      'tenha', 'tenhas', 'tenhamos', 'tenhais', 'tenham',
      'tivesse', 'tivesses', 'tivéssemos', 'tivésseis', 'tivessem',
      'tiver', 'tiveres', 'tivermos', 'tiverdes', 'tiverem',
    ], asSuffix: true)
    ..irregular('haver', <String>[
      'hei', 'hás', 'há', 'hemos', 'heis', 'hão', //
      'houve', 'houveste', 'houvemos', 'houvestes', 'houveram',
      'houvera', 'houveras', 'houvéramos', 'houvéreis',
      'haja', 'hajas', 'hajamos', 'hajais', 'hajam',
      'houvesse', 'houvesses', 'houvéssemos', 'houvésseis', 'houvessem',
      'houver', 'houveres', 'houvermos', 'houverdes', 'houverem',
    ])
    ..irregular('ir', <String>[
      'vou', 'vais', 'vai', 'vamos', 'ides', 'vão', //
      'fui', 'foste', 'foi', 'fomos', 'fostes', 'foram',
      'vá', 'vás', 'vades',
      'fosse', 'fosses', 'fôssemos', 'fôsseis', 'fossem',
      'for', 'fores', 'formos', 'fordes', 'forem',
    ])
    ..irregular('fazer', <String>['faz', 'fiz', 'fez'])
    ..irregular('fazer', <String>[
      'faço', 'fazes', 'fazemos', 'fazeis', 'fazem', //
      'fizeste', 'fizemos', 'fizestes', 'fizeram',
      'fizera', 'fizeras', 'fizéramos', 'fizéreis',
      'faça', 'faças', 'façamos', 'façais', 'façam',
      'fizesse', 'fizesses', 'fizéssemos', 'fizésseis', 'fizessem',
      'fizer', 'fizeres', 'fizermos', 'fizerdes', 'fizerem',
      'farei', 'farás', 'fará', 'faremos', 'fareis', 'farão',
      'faria', 'farias', 'faríamos', 'faríeis', 'fariam',
    ], asSuffix: true)
    ..irregular('dizer', <String>['diz'])
    ..irregular('dizer', <String>[
      'digo', 'dizes', 'dizemos', 'dizeis', 'dizem', //
      'disse', 'disseste', 'dissemos', 'dissestes', 'disseram',
      'dissera', 'disseras', 'disséramos', 'disséreis',
      'diga', 'digas', 'digamos', 'digais', 'digam',
      'dissesse', 'dissesses', 'disséssemos', 'dissésseis', 'dissessem',
      'disser', 'disseres', 'dissermos', 'disserdes', 'disserem',
      'direi', 'dirás', 'dirá', 'diremos', 'direis', 'dirão',
      'diria', 'dirias', 'diríamos', 'diríeis', 'diriam',
    ], asSuffix: true)
    ..irregular('poder', <String>[
      'posso', 'pude', 'pudeste', 'pôde', 'pudemos', 'pudestes', 'puderam', //
      'pudera', 'puderas', 'pudéramos', 'pudéreis',
      'possa', 'possas', 'possamos', 'possais', 'possam',
      'pudesse', 'pudesses', 'pudéssemos', 'pudésseis', 'pudessem',
      'puder', 'puderes', 'pudermos', 'puderdes', 'puderem',
    ])
    ..irregular('querer', <String>[
      'quer', 'quis', 'quiseste', 'quisemos', 'quisestes', 'quiseram', //
      'quisera', 'quiseras', 'quiséramos', 'quiséreis',
      'queira', 'queiras', 'queiramos', 'queirais', 'queiram',
      'quisesse', 'quisesses', 'quiséssemos', 'quisésseis', 'quisessem',
      'quiser', 'quiseres', 'quisermos', 'quiserdes', 'quiserem',
    ])
    ..irregular('saber', <String>[
      'sei', 'soube', 'soubeste', 'soubemos', 'soubestes', 'souberam', //
      'soubera', 'souberas', 'soubéramos', 'soubéreis',
      'saiba', 'saibas', 'saibamos', 'saibais', 'saibam',
      'soubesse', 'soubesses', 'soubéssemos', 'soubésseis', 'soubessem',
      'souber', 'souberes', 'soubermos', 'souberdes', 'souberem',
    ])
    ..irregular('ver', <String>[
      'vês', 'vê', 'vedes', 'veem', 'vêem', 'vi', 'viu', //
    ])
    ..irregular('ver', <String>[
      'vejo', 'viste', 'vimos', 'vistes', 'viram', //
      'víamos', 'víeis',
      'vira', 'viras', 'víramos', 'víreis',
      'veja', 'vejas', 'vejamos', 'vejais', 'vejam',
      'visse', 'visses', 'víssemos', 'vísseis', 'vissem',
      'vires', 'virmos', 'virdes', 'virem',
    ], asSuffix: true)
    ..irregular('vir', <String>['vem', 'vêm', 'vim', 'veio'])
    ..irregular('vir', <String>[
      'venho', 'vens', 'vindes', //
      'vieste', 'viemos', 'viestes', 'vieram',
      'vinha', 'vinhas', 'vínhamos', 'vínheis', 'vinham',
      'viera', 'vieras', 'viéramos', 'viéreis',
      'venha', 'venhas', 'venhamos', 'venhais', 'venham',
      'viesse', 'viesses', 'viéssemos', 'viésseis', 'viessem',
      'vier', 'vieres', 'viermos', 'vierdes', 'vierem',
    ], asSuffix: true)
    ..irregular('dar', <String>[
      'dou', 'dás', 'dá', 'damos', 'dais', 'dão', //
      'dei', 'deste', 'deu', 'demos', 'destes', 'deram',
      'dera', 'deras', 'déramos', 'déreis',
      'dê', 'dês', 'deis', 'deem', 'dêem',
      'desse', 'desses', 'déssemos', 'désseis', 'dessem',
      'der', 'deres', 'dermos', 'derdes', 'derem',
    ]);

  // pôr keeps its accent; its compounds (compor, propor, supor) do not.
  const List<String> porForms = <String>[
    'ponho', 'pões', 'põe', 'pomos', 'pondes', 'põem', //
    'pus', 'puseste', 'pôs', 'pusemos', 'pusestes', 'puseram',
    'punha', 'punhas', 'púnhamos', 'púnheis', 'punham',
    'pusera', 'puseras', 'puséramos', 'puséreis',
    'ponha', 'ponhas', 'ponhamos', 'ponhais', 'ponham',
    'pusesse', 'pusesses', 'puséssemos', 'pusésseis', 'pusessem',
    'puser', 'puseres', 'pusermos', 'puserdes', 'puserem',
    'porei', 'porás', 'porá', 'poremos', 'poreis', 'porão',
    'poria', 'porias', 'poríamos', 'poríeis', 'poriam',
  ];
  t
    ..irregular('pôr', porForms)
    ..irregular('por', porForms, asSuffix: true)
    ..irregular('trazer', <String>['traz'])
    ..irregular('trazer', <String>[
      'trago', 'trazes', 'trazemos', 'trazeis', 'trazem', //
      'trouxe', 'trouxeste', 'trouxemos', 'trouxestes', 'trouxeram',
      'trouxera', 'trouxeras', 'trouxéramos', 'trouxéreis',
      'traga', 'tragas', 'tragamos', 'tragais', 'tragam',
      'trouxesse', 'trouxesses', 'trouxéssemos', 'trouxésseis', 'trouxessem',
      'trouxer', 'trouxeres', 'trouxermos', 'trouxerdes', 'trouxerem',
      'trarei', 'trarás', 'trará', 'traremos', 'trareis', 'trarão',
      'traria', 'trarias', 'traríamos', 'traríeis', 'trariam',
    ], asSuffix: true)
    ..irregular('ler', <String>[
      'leio', 'lês', 'lê', 'ledes', 'leem', 'lêem', 'li', 'leu', //
      'leia', 'leias', 'leiamos', 'leiais', 'leiam',
    ])
    ..irregular('crer', <String>[
      'creio', 'crês', 'crê', 'credes', 'creem', 'crêem', //
      'creia', 'creias', 'creiamos', 'creiais', 'creiam',
    ])
    ..irregular('ouvir', <String>[
      'ouço', 'oiço', 'ouça', 'ouças', 'ouçamos', 'ouçais', 'ouçam', //
    ])
    ..irregular('caber', <String>[
      'caibo', 'caiba', 'caibas', 'caibamos', 'caibais', 'caibam', //
      'coube', 'coubeste', 'coubemos', 'coubestes', 'couberam',
      'coubesse', 'coubesses', 'coubéssemos', 'coubésseis', 'coubessem',
      'couber', 'couberes', 'coubermos', 'couberdes', 'couberem',
    ]);
}

// ---------------------------------------------------------------------------
// Italian
// ---------------------------------------------------------------------------

const List<String> _italianClitics = <String>[
  'mi', 'ti', 'si', 'ci', 'vi', 'lo', 'la', 'li', 'le', 'gli', 'ne', //
  'melo', 'mela', 'meli', 'mele', 'mene',
  'telo', 'tela', 'teli', 'tele', 'tene',
  'selo', 'sela', 'seli', 'sele', 'sene',
  'celo', 'cela', 'celi', 'cele', 'cene',
  'velo', 'vela', 'veli', 'vele', 'vene',
  'glielo', 'gliela', 'glieli', 'gliele', 'gliene',
];

TransformTable italian() {
  final TransformTable table = TransformTable('it', <String, Object>{
    'n': <String, Object>{
      'name': 'Noun',
      'isDictionaryForm': true,
      'subConditions': <String>['ns', 'np'],
    },
    'ns': <String, Object>{'name': 'Noun singular', 'isDictionaryForm': false},
    'np': <String, Object>{'name': 'Noun plural', 'isDictionaryForm': false},
    'v': <String, Object>{
      'name': 'Verb',
      'isDictionaryForm': true,
      'subConditions': <String>['v_are', 'v_ere', 'v_ire'],
    },
    'v_are': <String, Object>{'name': '-are verb', 'isDictionaryForm': false},
    'v_ere': <String, Object>{'name': '-ere verb', 'isDictionaryForm': false},
    'v_ire': <String, Object>{'name': '-ire verb', 'isDictionaryForm': false},
    'adj': <String, Object>{'name': 'Adjective', 'isDictionaryForm': true},
    'adv': <String, Object>{'name': 'Adverb', 'isDictionaryForm': true},
  });

  // l'uomo, dell'anno, un'amica, quest'anno, c'è.
  final _Transform elision = table.transform(
    'elision',
    'Elided article or preposition before a word',
  );
  for (final String p in const <String>[
    "l'", "un'", "dell'", "all'", "dall'", "nell'", "sull'", "coll'", //
    "pell'", "quest'", "quell'", "bell'", "sant'", "d'", "c'", "m'", "t'",
    "s'", "v'", "n'", "gl'",
  ]) {
    elision.prefix(p, '', const <String>[], const <String>[
      'n',
      'adj',
      'adv',
      'v',
    ]);
  }

  final _Transform plural = table.transform('plural', 'Plural form of a noun');
  for (final (String from, String to) in const <(String, String)>[
    ('i', 'o'),
    ('i', 'e'),
    ('i', 'a'),
    ('i', 'io'),
    ('e', 'a'),
    ('a', 'o'),
    ('chi', 'co'),
    ('ghi', 'go'),
    ('ci', 'co'),
    ('gi', 'go'),
    ('che', 'ca'),
    ('ghe', 'ga'),
    ('ie', 'ia'),
    ('ce', 'cia'),
    ('ge', 'gia'),
  ]) {
    plural.suffix(from, to, const <String>['np'], const <String>['ns']);
  }
  plural
    ..whole('uomini', 'uomo', const <String>['np'], const <String>['ns'])
    ..whole('dei', 'dio', const <String>['np'], const <String>['ns']);

  final _Transform pluralAdj = table.transform(
    'plural adjective',
    'Plural form of an adjective',
  );
  for (final (String from, String to) in const <(String, String)>[
    ('i', 'o'),
    ('i', 'e'),
    ('e', 'o'),
    ('e', 'a'),
    ('chi', 'co'),
    ('ghi', 'go'),
    ('ci', 'co'),
    ('che', 'ca'),
    ('ghe', 'ga'),
  ]) {
    pluralAdj.suffix(from, to, _adj, _adj);
  }

  table
      .transform('feminine adjective', 'feminine form of an adjective')
      .suffix('a', 'o', _adj, _adj);

  table.transform('superlative', 'Superlative form of an adjective')
    ..suffix('issimo', 'o', _adj, _adj)
    ..suffix('issimo', 'e', _adj, _adj);

  table.transform('adverb', 'Adverb form of an adjective')
    ..suffix('amente', 'o', const <String>['adv'], _adj)
    ..suffix('emente', 'e', const <String>['adv'], _adj)
    ..suffix('lmente', 'le', const <String>['adv'], _adj)
    ..suffix('rmente', 're', const <String>['adv'], _adj);

  table.transform('present indicative', 'Present indicative form of a verb')
    ..endings('are', <String>['o', 'i', 'a', 'iamo', 'ate', 'ano'], 'v_are')
    ..endings('ere', <String>['o', 'i', 'e', 'iamo', 'ete', 'ono'], 'v_ere')
    ..endings('ire', <String>['o', 'i', 'e', 'iamo', 'ite', 'ono'], 'v_ire')
    ..endings('ire', <String>['isco', 'isci', 'isce', 'iscono'], 'v_ire')
    ..endings('care', <String>['chi', 'chiamo'], 'v_are')
    ..endings('gare', <String>['ghi', 'ghiamo'], 'v_are')
    ..endings('ciare', <String>['ci'], 'v_are')
    ..endings('giare', <String>['gi'], 'v_are')
    ..endings('iare', <String>['i', 'iamo'], 'v_are');

  table.transform('imperfect', 'Imperfect form of a verb')
    ..endings('are', <String>[
      'avo',
      'avi',
      'ava',
      'avamo',
      'avate',
      'avano',
    ], 'v_are')
    ..endings('ere', <String>[
      'evo',
      'evi',
      'eva',
      'evamo',
      'evate',
      'evano',
    ], 'v_ere')
    ..endings('ire', <String>[
      'ivo',
      'ivi',
      'iva',
      'ivamo',
      'ivate',
      'ivano',
    ], 'v_ire');

  table.transform('preterite', 'Preterite (past) form of a verb')
    ..endings('are', <String>[
      'ai',
      'asti',
      'ò',
      'ammo',
      'aste',
      'arono',
    ], 'v_are')
    ..endings('ere', <String>[
      'ei', 'etti', 'esti', 'é', 'è', 'ette', 'emmo', 'este', 'erono', //
      'ettero',
    ], 'v_ere')
    ..endings('ire', <String>[
      'ii',
      'isti',
      'ì',
      'immo',
      'iste',
      'irono',
    ], 'v_ire');

  final _Transform future = table.transform('future', 'Future form of a verb');
  final _Transform conditional = table.transform(
    'conditional',
    'Conditional form of a verb',
  );
  const List<String> futureEndings = <String>[
    'ò', 'ai', 'à', 'emo', 'ete', 'anno', //
  ];
  const List<String> conditionalEndings = <String>[
    'ei', 'esti', 'ebbe', 'emmo', 'este', 'ebbero', //
  ];
  for (final (String stem, String inf, String cond)
      in const <(String, String, String)>[
        ('er', 'are', 'v_are'),
        ('er', 'ere', 'v_ere'),
        ('ir', 'ire', 'v_ire'),
        ('cher', 'care', 'v_are'),
        ('gher', 'gare', 'v_are'),
        ('cer', 'ciare', 'v_are'),
        ('ger', 'giare', 'v_are'),
      ]) {
    future.endings(inf, <String>[
      for (final String e in futureEndings) '$stem$e',
    ], cond);
    conditional.endings(inf, <String>[
      for (final String e in conditionalEndings) '$stem$e',
    ], cond);
  }

  table.transform('present subjunctive', 'Present subjunctive form of a verb')
    ..endings('are', <String>['i', 'iamo', 'iate', 'ino'], 'v_are')
    ..endings('ere', <String>['a', 'iamo', 'iate', 'ano'], 'v_ere')
    ..endings('ire', <String>['a', 'iamo', 'iate', 'ano'], 'v_ire')
    ..endings('ire', <String>['isca', 'iscano'], 'v_ire')
    ..endings('care', <String>['chi', 'chino'], 'v_are')
    ..endings('gare', <String>['ghi', 'ghino'], 'v_are');

  table.transform(
      'imperfect subjunctive',
      'Imperfect subjunctive form of a verb',
    )
    ..endings('are', <String>[
      'assi',
      'asse',
      'assimo',
      'aste',
      'assero',
    ], 'v_are')
    ..endings('ere', <String>[
      'essi',
      'esse',
      'essimo',
      'este',
      'essero',
    ], 'v_ere')
    ..endings('ire', <String>[
      'issi',
      'isse',
      'issimo',
      'iste',
      'issero',
    ], 'v_ire');

  table.transform('gerund', 'Gerund form of a verb')
    ..endings('are', <String>['ando'], 'v_are')
    ..endings('ere', <String>['endo'], 'v_ere')
    ..endings('ire', <String>['endo'], 'v_ire');

  table.transform('present participle', 'Present participle form of a verb')
    ..suffix('ante', 'are', _adj, const <String>['v_are'])
    ..suffix('ente', 'ere', _adj, const <String>['v_ere'])
    ..suffix('ente', 'ire', _adj, const <String>['v_ire']);

  final _Transform participle =
      table.transform('participle', 'Participle form of a verb')
        ..suffix('ato', 'are', _adj, const <String>['v_are'])
        ..suffix('uto', 'ere', _adj, const <String>['v_ere'])
        ..suffix('ito', 'ire', _adj, const <String>['v_ire']);
  for (final (String form, String lemma) in const <(String, String)>[
    ('fatto', 'fare'),
    ('detto', 'dire'),
    ('stato', 'essere'),
    ('stato', 'stare'),
    ('venuto', 'venire'),
    ('visto', 'vedere'),
    ('preso', 'prendere'),
    ('messo', 'mettere'),
    ('chiesto', 'chiedere'),
    ('sposto', 'spondere'),
    ('scritto', 'scrivere'),
    ('letto', 'leggere'),
    ('vissuto', 'vivere'),
    ('corso', 'correre'),
    ('ciso', 'cidere'),
    ('chiuso', 'chiudere'),
    ('cluso', 'cludere'),
    ('perso', 'perdere'),
    ('perto', 'prire'),
    ('fferto', 'ffrire'),
    ('scelto', 'scegliere'),
    ('olto', 'ogliere'),
    ('vinto', 'vincere'),
    ('mosso', 'muovere'),
    ('riso', 'ridere'),
    ('rotto', 'rompere'),
    ('acceso', 'accendere'),
    ('speso', 'spendere'),
    ('successo', 'succedere'),
    ('giunto', 'giungere'),
    ('volto', 'volgere'),
    ('cusso', 'cutere'),
    ('presso', 'primere'),
    ('posto', 'porre'),
    ('dotto', 'durre'),
    ('tratto', 'trarre'),
    ('rimasto', 'rimanere'),
    ('nato', 'nascere'),
    ('morto', 'morire'),
    ('bevuto', 'bere'),
  ]) {
    participle.suffix(form, lemma, _adj, _v);
  }

  // Shortened infinitives (andar via, aver fatto, esser).
  table.transform('shortened infinitive', 'Shortened infinitive of a verb')
    ..endings('are', <String>['ar'], 'v_are')
    ..endings('ere', <String>['er'], 'v_ere')
    ..endings('ire', <String>['ir'], 'v_ire')
    ..suffix('or', 'orre', _v, _v)
    ..suffix('ur', 'urre', _v, _v);

  // Pronouns written onto the verb: infinitive (parlarmi, dirglielo),
  // gerund (parlandogli), imperative (guardalo, prendili, facciamolo) and the
  // doubled monosyllabic imperatives (dimmi, fallo, dammi).
  final _Transform clitic = table.transform(
    'attached pronoun',
    'Verb with an attached object or reflexive pronoun',
  );
  for (final String p in _italianClitics) {
    clitic
      ..suffix('ar$p', 'are', const <String>[], const <String>['v_are'])
      ..suffix('er$p', 'ere', const <String>[], const <String>['v_ere'])
      ..suffix('ir$p', 'ire', const <String>[], const <String>['v_ire'])
      ..suffix('or$p', 'orre', const <String>[], _v)
      ..suffix('ur$p', 'urre', const <String>[], _v)
      ..suffix('ar$p', 'arre', const <String>[], _v);
    for (final String ending in const <String>[
      'ando', 'endo', 'a', 'i', 'ate', 'ete', 'ite', 'iamo', //
    ]) {
      clitic.suffix('$ending$p', ending, const <String>[], _v);
    }
  }
  for (final (String stem, String lemma) in const <(String, String)>[
    ('da', 'dare'),
    ('di', 'dire'),
    ('fa', 'fare'),
    ('sta', 'stare'),
    ('va', 'andare'),
  ]) {
    for (final String p in _italianClitics) {
      // dammi, dallo, dagli: the consonant doubles except before gli.
      final String doubled = p == 'gli' || p.startsWith('glie')
          ? '$stem$p'
          : '$stem${p[0]}$p';
      clitic.whole(doubled, lemma, const <String>[], _v);
    }
  }

  _italianIrregulars(table.transform('irregular', 'Irregular form of a verb'));
  return table;
}

void _italianIrregulars(_Transform t) {
  t
    ..irregular('essere', <String>[
      'sono', 'sei', 'è', 'siamo', 'siete', //
      'ero', 'eri', 'era', 'eravamo', 'eravate', 'erano',
      'fui', 'fosti', 'fu', 'fummo', 'foste', 'furono',
      'sarò', 'sarai', 'sarà', 'saremo', 'sarete', 'saranno',
      'sarei', 'saresti', 'sarebbe', 'saremmo', 'sareste', 'sarebbero',
      'sia', 'siate', 'siano',
      'fossi', 'fosse', 'fossimo', 'fossero',
      'essendo', 'esser',
    ])
    ..irregular('avere', <String>[
      'ho', 'hai', 'ha', 'abbiamo', 'hanno', //
      'ebbi', 'ebbe', 'ebbero',
      'avrò', 'avrai', 'avrà', 'avremo', 'avrete', 'avranno',
      'avrei', 'avresti', 'avrebbe', 'avremmo', 'avreste', 'avrebbero',
      'abbia', 'abbiate', 'abbiano',
    ])
    ..irregular('fare', <String>['fa', 'fai', 'fate', 'fanno', 'fo'])
    ..irregular('fare', <String>[
      'faccio', 'facciamo', //
      'facevo', 'facevi', 'faceva', 'facevamo', 'facevate', 'facevano',
      'feci', 'facesti', 'fece', 'facemmo', 'faceste', 'fecero',
      'farò', 'farai', 'farà', 'faremo', 'farete', 'faranno',
      'farei', 'faresti', 'farebbe', 'faremmo', 'fareste', 'farebbero',
      'faccia', 'facciate', 'facciano',
      'facessi', 'facesse', 'facessimo', 'facessero',
      'facendo',
    ], asSuffix: true)
    ..irregular('andare', <String>[
      'vado', 'vai', 'va', 'vanno', //
      'andrò', 'andrai', 'andrà', 'andremo', 'andrete', 'andranno',
      'andrei', 'andresti', 'andrebbe', 'andremmo', 'andreste', 'andrebbero',
      'vada', 'vadano',
    ])
    ..irregular('dire', <String>['dici', 'dice', 'dite', 'dica'])
    ..irregular('dire', <String>[
      'dico', 'diciamo', 'dicono', //
      'dicevo', 'dicevi', 'diceva', 'dicevamo', 'dicevate', 'dicevano',
      'dissi', 'dicesti', 'disse', 'dicemmo', 'diceste', 'dissero',
      'diciate', 'dicano',
      'dicessi', 'dicesse', 'dicessimo', 'dicessero',
      'dicendo',
    ], asSuffix: true)
    ..irregular('stare', <String>[
      'sto', 'stai', 'sta', 'stiamo', 'state', 'stanno', //
      'stetti', 'stesti', 'stette', 'stemmo', 'steste', 'stettero',
      'starò', 'starai', 'starà', 'staremo', 'starete', 'staranno',
      'starei', 'staresti', 'starebbe', 'staremmo', 'stareste', 'starebbero',
      'stia', 'stiate', 'stiano',
      'stessi', 'stesse', 'stessimo', 'steste', 'stessero',
    ])
    ..irregular('dare', <String>[
      'do', 'dai', 'dà', 'diamo', 'date', 'danno', //
      'diedi', 'detti', 'desti', 'diede', 'dette', 'demmo', 'deste',
      'diedero', 'dettero',
      'darò', 'darai', 'darà', 'daremo', 'darete', 'daranno',
      'darei', 'daresti', 'darebbe', 'daremmo', 'dareste', 'darebbero',
      'dia', 'diate', 'diano',
      'dessi', 'desse', 'dessimo', 'dessero',
    ])
    ..irregular('potere', <String>[
      'posso', 'puoi', 'può', 'possiamo', 'possono', //
      'potrò', 'potrai', 'potrà', 'potremo', 'potrete', 'potranno',
      'potrei', 'potresti', 'potrebbe', 'potremmo', 'potreste', 'potrebbero',
      'possa', 'possiate', 'possano',
    ])
    ..irregular('volere', <String>[
      'voglio', 'vuoi', 'vuole', 'vogliamo', 'vogliono', //
      'volli', 'volle', 'vollero',
      'vorrò', 'vorrai', 'vorrà', 'vorremo', 'vorrete', 'vorranno',
      'vorrei', 'vorresti', 'vorrebbe', 'vorremmo', 'vorreste', 'vorrebbero',
      'voglia', 'vogliate', 'vogliano',
    ])
    ..irregular('dovere', <String>[
      'devo', 'debbo', 'devi', 'deve', 'dobbiamo', 'devono', 'debbono', //
      'dovrò', 'dovrai', 'dovrà', 'dovremo', 'dovrete', 'dovranno',
      'dovrei', 'dovresti', 'dovrebbe', 'dovremmo', 'dovreste', 'dovrebbero',
      'debba', 'deva', 'dobbiate', 'debbano',
    ])
    ..irregular('sapere', <String>[
      'so', 'sai', 'sa', 'sappiamo', 'sanno', //
      'seppi', 'seppe', 'seppero',
      'saprò', 'saprai', 'saprà', 'sapremo', 'saprete', 'sapranno',
      'saprei', 'sapresti', 'saprebbe', 'sapremmo', 'sapreste', 'saprebbero',
      'sappia', 'sappiate', 'sappiano',
    ])
    ..irregular('venire', <String>[
      'vengo', 'vieni', 'viene', 'vengono', //
      'venni', 'venne', 'vennero',
      'verrò', 'verrai', 'verrà', 'verremo', 'verrete', 'verranno',
      'verrei', 'verresti', 'verrebbe', 'verremmo', 'verreste', 'verrebbero',
      'venga', 'vengano',
    ], asSuffix: true)
    ..irregular('tenere', <String>[
      'tengo', 'tieni', 'tiene', 'tengono', //
      'tenni', 'tenne', 'tennero',
      'terrò', 'terrai', 'terrà', 'terremo', 'terrete', 'terranno',
      'terrei', 'terresti', 'terrebbe', 'terremmo', 'terreste', 'terrebbero',
      'tenga', 'tengano',
    ], asSuffix: true)
    ..irregular('uscire', <String>[
      'esco', 'esci', 'esce', 'escono', 'esca', 'escano', //
    ])
    ..irregular('vedere', <String>[
      'vidi', 'vide', 'videro', //
      'vedrò', 'vedrai', 'vedrà', 'vedremo', 'vedrete', 'vedranno',
      'vedrei', 'vedresti', 'vedrebbe', 'vedremmo', 'vedreste', 'vedrebbero',
    ], asSuffix: true)
    ..irregular('bere', <String>[
      'bevo', 'bevi', 'beve', 'beviamo', 'bevete', 'bevono', //
      'bevevo', 'bevevi', 'beveva', 'bevevamo', 'bevevate', 'bevevano',
      'bevvi', 'bevve', 'bevvero',
      'berrò', 'berrai', 'berrà', 'berremo', 'berrete', 'berranno',
      'berrei', 'berresti', 'berrebbe', 'berremmo', 'berreste', 'berrebbero',
      'beva', 'bevano', 'bevessi', 'bevesse', 'bevessimo', 'bevessero',
      'bevendo',
    ])
    ..irregular('rimanere', <String>[
      'rimango', 'rimangono', 'rimasi', 'rimase', 'rimasero', //
      'rimarrò', 'rimarrai', 'rimarrà', 'rimarremo', 'rimarrete', 'rimarranno',
      'rimarrei', 'rimarresti', 'rimarrebbe', 'rimarremmo', 'rimarreste',
      'rimarrebbero', 'rimanga', 'rimangano',
    ])
    ..irregular('porre', <String>[
      'pongo', 'poni', 'pone', 'poniamo', 'ponete', 'pongono', //
      'ponevo', 'ponevi', 'poneva', 'ponevamo', 'ponevate', 'ponevano',
      'posi', 'ponesti', 'pose', 'ponemmo', 'poneste', 'posero',
      'porrò', 'porrai', 'porrà', 'porremo', 'porrete', 'porranno',
      'porrei', 'porresti', 'porrebbe', 'porremmo', 'porreste', 'porrebbero',
      'ponga', 'poniate', 'pongano',
      'ponessi', 'ponesse', 'ponessimo', 'ponessero', 'ponendo',
    ], asSuffix: true)
    ..irregular('durre', <String>[
      'duco', 'duci', 'duce', 'duciamo', 'ducete', 'ducono', //
      'ducevo', 'ducevi', 'duceva', 'ducevamo', 'ducevate', 'ducevano',
      'dussi', 'ducesti', 'dusse', 'ducemmo', 'duceste', 'dussero',
      'durrò', 'durrai', 'durrà', 'durremo', 'durrete', 'durranno',
      'durrei', 'durresti', 'durrebbe', 'durremmo', 'durreste', 'durrebbero',
      'duca', 'duciate', 'ducano',
      'ducessi', 'ducesse', 'ducessimo', 'ducessero', 'ducendo',
    ], asSuffix: true)
    ..irregular('trarre', <String>[
      'traggo', 'trai', 'trae', 'traiamo', 'traete', 'traggono', //
      'traevo', 'traevi', 'traeva', 'traevamo', 'traevate', 'traevano',
      'trassi', 'traesti', 'trasse', 'traemmo', 'traeste', 'trassero',
      'trarrò', 'trarrai', 'trarrà', 'trarremo', 'trarrete', 'trarranno',
      'trarrei', 'trarresti', 'trarrebbe', 'trarremmo', 'trarreste',
      'trarrebbero', 'tragga', 'traiate', 'traggano',
      'traessi', 'traesse', 'traessimo', 'traessero', 'traendo',
    ], asSuffix: true)
    ..irregular('piacere', <String>[
      'piaccio', 'piacciamo', 'piacciono', 'piacqui', 'piacque', //
      'piacquero', 'piaccia', 'piacciano',
    ], asSuffix: true)
    ..irregular('morire', <String>[
      'muoio', 'muori', 'muore', 'muoiono', 'muoia', 'muoiano', //
    ])
    ..irregular('nascere', <String>['nacqui', 'nacque', 'nacquero'])
    ..irregular('cadere', <String>[
      'caddi', 'cadde', 'caddero', //
      'cadrò', 'cadrai', 'cadrà', 'cadremo', 'cadrete', 'cadranno',
      'cadrei', 'cadresti', 'cadrebbe', 'cadremmo', 'cadreste', 'cadrebbero',
    ], asSuffix: true)
    ..irregular('sedere', <String>[
      'siedo', 'siedi', 'siede', 'siedono', 'sieda', 'siedano', //
    ], asSuffix: true);

  // Strong past stems: the 1sg, 3sg and 3pl of the passato remoto share a
  // stem that is not the infinitive's (presi, prese, presero -> prendere).
  for (final (String stem, String lemma) in const <(String, String)>[
    ('pres', 'prendere'),
    ('mis', 'mettere'),
    ('chies', 'chiedere'),
    ('rispos', 'rispondere'),
    ('scriss', 'scrivere'),
    ('less', 'leggere'),
    ('viss', 'vivere'),
    ('cors', 'correre'),
    ('cis', 'cidere'),
    ('chius', 'chiudere'),
    ('clus', 'cludere'),
    ('pers', 'perdere'),
    ('scels', 'scegliere'),
    ('tols', 'togliere'),
    ('conobb', 'conoscere'),
    ('vins', 'vincere'),
    ('moss', 'muovere'),
    ('ris', 'ridere'),
    ('rupp', 'rompere'),
    ('acces', 'accendere'),
    ('spes', 'spendere'),
    ('giuns', 'giungere'),
    ('vols', 'volgere'),
    ('discuss', 'discutere'),
    ('press', 'primere'),
  ]) {
    t.irregular(lemma, <String>[
      '${stem}i',
      '${stem}e',
      '${stem}ero',
    ], asSuffix: true);
  }
  t
    ..irregular('scegliere', <String>[
      'scelgo',
      'scelgono',
      'scelga',
      'scelgano',
    ], asSuffix: true)
    ..irregular('togliere', <String>[
      'tolgo',
      'tolgono',
      'tolga',
      'tolgano',
    ], asSuffix: true);
}

void main() {
  final Directory dir = Directory('assets/transforms');
  if (!dir.existsSync()) {
    stderr.writeln('Run from fushi/: assets/transforms not found.');
    exitCode = 2;
    return;
  }
  for (final TransformTable table in <TransformTable>[
    portuguese(),
    italian(),
  ]) {
    File(
      '${dir.path}/${table.language}.json',
    ).writeAsStringSync('${table.encode()}\n');
  }
}
