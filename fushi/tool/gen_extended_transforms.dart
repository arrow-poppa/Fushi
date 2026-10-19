// Generates the deinflection tables that extend the thin Yomitan ports for
// German, Latin and Modern Greek (de_extended.json, la_extended.json,
// el_extended.json) and the Russian table (ru.json).
//
// Yomitan was the reference for the shape of every table: the descriptor
// format, the condition names of the ported de / la / el tables, and the
// spelling variants its text preprocessors handle (ß ↔ ss, æ ↔ ae, ё ↔ е,
// implemented in the engine's text processor). Yomitan's own German, Latin and
// Greek tables are what de.json / la.json / el.json already are, and it has no
// Russian transforms at all, so the rules here are written from the
// conjugation and declension paradigms.
//
// An extension file keeps its language name, so the engine treats it as more
// rules of the same language (like en_irregular): it repeats the base file's
// conditions, read from that file, and may add its own.
//
// Usage (from fushi/): dart run tool/gen_extended_transforms.dart
import 'dart:convert';
import 'dart:io';

import 'gen_romance_transforms.dart' show TransformRules, TransformTable;

const String _kTransformsDir = 'assets/transforms';

/// The base table's conditions followed by [extra]; an entry of [extra] with a
/// base name replaces the base definition (to add sub-conditions to it).
Map<String, Object> _conditionsExtending(
  String baseFile,
  Map<String, Object> extra,
) {
  final Map<String, Object?> base =
      (jsonDecode(File('$_kTransformsDir/$baseFile.json').readAsStringSync())
              as Map<String, Object?>)['conditions']!
          as Map<String, Object?>;
  return <String, Object>{
    for (final MapEntry<String, Object?> e in base.entries) e.key: e.value!,
    ...extra,
  };
}

Map<String, Object> _cond(String name, {List<String>? sub, bool dict = true}) =>
    <String, Object>{
      'name': name,
      'isDictionaryForm': dict,
      if (sub != null) 'subConditions': sub,
    };

/// Every ending in [forms] maps to [lemmaEnding].
void _map(
  TransformRules t,
  List<String> forms,
  String lemmaEnding,
  List<String> into,
  List<String> out,
) {
  for (final String f in forms) {
    t.suffix(f, lemmaEnding, into, out);
  }
}

List<String> _words(String spaceSeparated) => spaceSeparated
    .split(RegExp(r'\s+'))
    .where((String w) => w.isNotEmpty)
    .toList();

// ---------------------------------------------------------------------------
// German
// ---------------------------------------------------------------------------

const List<String> _germanUmlautClusters = <String>[
  'b', 'ch', 'ck', 'd', 'f', 'ff', 'ft', 'g', 'gt', 'h', 'hl', 'hn', 'hr', //
  'k', 'l', 'ld', 'll', 'lt', 'lz', 'm', 'mm', 'mpf', 'n', 'nd', 'ng', 'nk',
  'nn', 'nst', 'nt', 'nz', 'p', 'pf', 'r', 'rd', 'rf', 'rg', 'rk', 'rm', 'rn',
  'rs', 'rst', 'rt', 'rz', 's', 'sch', 'ss', 'st', 't', 'tt', 'tz', 'x', 'z',
  'ß', 'cht', 'chs',
];

const List<(String, String)> _germanUmlauts = <(String, String)>[
  ('äu', 'au'),
  ('ä', 'a'),
  ('ö', 'o'),
  ('ü', 'u'),
];

/// Separable verb prefixes: the participle puts ge between prefix and stem
/// (aufgemacht -> aufmachen).
const List<String> _germanSeparablePrefixes = <String>[
  'ab', 'an', 'auf', 'aus', 'bei', 'dar', 'durch', 'ein', 'fest', 'fort', //
  'her', 'heraus', 'herein', 'hin', 'hinaus', 'los', 'mit', 'nach', 'vor',
  'voran', 'vorbei', 'weg', 'weiter', 'wieder', 'zu', 'zurück', 'zusammen',
  'um', 'über', 'unter',
];

/// Strong and irregular verbs: infinitive, then every form that is not the
/// infinitive stem plus a regular ending. Suffix rules, so verbs with a
/// prefix share them (verstand -> verstehen, anfing -> anfangen).
const Map<String, String> _germanStrongVerbs = <String, String>{
  'sein':
      'bin bist ist sind seid war warst waren wart gewesen wäre wärst '
      'wären wärt sei seist seien seiet',
  'haben':
      'hast hat hatte hattest hatten hattet gehabt hätte hättest hätten '
      'hättet',
  'werden':
      'wirst wird wurde wurdest wurden wurdet ward geworden worden würde '
      'würdest würden würdet',
  'gehen': 'ging gingst gingen gingt gegangen ginge',
  'kommen': 'kam kamst kamen kamt gekommen käme kämen',
  'sehen': 'siehst sieht sah sahst sahen saht gesehen sähe sähen sieh',
  'geben': 'gibst gibt gab gabst gaben gabt gegeben gäbe gäben gib',
  'nehmen': 'nimmst nimmt nahm nahmst nahmen nahmt genommen nähme nimm',
  'sprechen':
      'sprichst spricht sprach sprachst sprachen spracht gesprochen '
      'spräche sprich',
  'lesen': 'liest las lasen last gelesen läse lies',
  'essen': 'isst aß aßen aßt gegessen äße iss',
  'fahren': 'fährst fährt fuhr fuhrst fuhren fuhrt gefahren führe',
  'laufen': 'läufst läuft lief liefst liefen lieft gelaufen',
  'schlafen': 'schläfst schläft schlief schliefen geschlafen',
  'finden': 'fand fandst fanden fandet gefunden fände',
  'trinken': 'trank trankst tranken trankt getrunken tränke',
  'singen': 'sang sangen gesungen sänge',
  'schreiben': 'schrieb schriebst schrieben schriebt geschrieben',
  'bleiben': 'blieb bliebst blieben bliebt geblieben',
  'stehen': 'stand standst standen standet gestanden stünde stände',
  'liegen': 'lag lagst lagen lagt gelegen läge',
  'sitzen': 'saß saßen gesessen säße',
  'wissen': 'weiß weißt wusste wusstest wussten wusstet gewusst wüsste',
  'können':
      'kann kannst konnte konntest konnten konntet gekonnt könnte '
      'könntest könnten',
  'müssen':
      'muss musst musste musstest mussten musstet gemusst müsste '
      'müssten',
  'dürfen': 'darf darfst durfte durften gedurft dürfte dürften',
  'wollen': 'will willst',
  'mögen':
      'mag magst mochte mochten gemocht möchte möchtest möchten '
      'möchtet',
  'bringen': 'brachte brachtest brachten gebracht brächte',
  'denken': 'dachte dachtest dachten gedacht dächte',
  'kennen': 'kannte kanntest kannten gekannt',
  'nennen': 'nannte nannten genannt',
  'rennen': 'rannte rannten gerannt',
  'tun': 'tue tust tut tat tatst taten tatet getan täte',
  'halten': 'hältst hält hielt hielten gehalten',
  'fallen': 'fällst fällt fiel fielen gefallen',
  'lassen': 'lässt ließ ließen gelassen',
  'tragen': 'trägst trägt trug trugen getragen trüge',
  'ziehen': 'zog zogst zogen gezogen zöge',
  'rufen': 'rief riefen gerufen',
  'heißen': 'hieß hießen geheißen',
  'helfen': 'hilfst hilft half halfen geholfen hilf',
  'sterben': 'stirbst stirbt starb starben gestorben',
  'werfen': 'wirfst wirft warf warfen geworfen',
  'treffen': 'triffst trifft traf trafen getroffen',
  'vergessen': 'vergisst vergaß vergaßen',
  'verlieren': 'verlor verloren',
  'beginnen': 'begann begannen begonnen',
  'gewinnen': 'gewann gewannen gewonnen',
  'schwimmen': 'schwamm schwammen geschwommen',
  'fliegen': 'flog flogen geflogen',
  'bitten': 'bat baten gebeten',
  'fangen': 'fängst fängt fing fingen gefangen',
  'waschen': 'wäschst wäscht wusch wuschen gewaschen',
  'wachsen': 'wächst wuchs wuchsen gewachsen',
  'schließen': 'schloss schlossen geschlossen',
  'greifen': 'griff griffen gegriffen',
  'steigen': 'stieg stiegen gestiegen',
  'scheinen': 'schien schienen geschienen',
  'schweigen': 'schwieg schwiegen geschwiegen',
  'leiden': 'litt litten gelitten',
  'schneiden': 'schnitt schnitten geschnitten',
  'streiten': 'stritt stritten gestritten',
  'reiten': 'ritt ritten geritten',
  'fließen': 'floss flossen geflossen',
  'frieren': 'fror froren gefroren',
  'riechen': 'roch rochen gerochen',
  'schieben': 'schob schoben geschoben',
  'lügen': 'log logen gelogen',
  'brechen': 'brichst bricht brach brachen gebrochen',
  'stehlen': 'stiehlst stiehlt stahl stahlen gestohlen',
  'empfehlen': 'empfiehlst empfiehlt empfahl empfahlen empfohlen',
  'gleichen': 'glich glichen geglichen',
  'schreien': 'schrie schrien geschrien',
  'gelten': 'giltst gilt galt galten gegolten',
  'laden': 'lädst lädt lud luden geladen',
  'raten': 'rätst rät riet rieten geraten',
  'schlagen': 'schlägst schlägt schlug schlugen geschlagen',
  'stoßen': 'stößt stieß stießen gestoßen',
  'springen': 'sprang sprangen gesprungen',
  'zwingen': 'zwang zwangen gezwungen',
  'binden': 'band banden gebunden',
  'sinken': 'sank sanken gesunken',
  'senden': 'sandte sandten gesandt',
  'wenden': 'wandte wandten gewandt',
  'biegen': 'bog bogen gebogen',
  'bieten': 'bot boten geboten',
  'genießen': 'genoss genossen',
  'schießen': 'schoss schossen geschossen',
  'leihen': 'lieh liehen geliehen',
  'meiden': 'mied mieden gemieden',
  'weisen': 'wies wiesen gewiesen',
  'treiben': 'trieb trieben getrieben',
};

TransformTable german() {
  final TransformTable table = TransformTable(
    'de',
    _conditionsExtending('de', <String, Object>{
      'np': _cond('Noun plural', dict: false),
      'vpp': _cond('Past participle stem', dict: false),
    }),
    fileName: 'de_extended',
  );
  const List<String> v = <String>['v'];
  const List<String> adj = <String>['adj'];
  const List<String> n = <String>['n'];

  final TransformRules present = table.transform(
    'present',
    'Present tense form of a verb',
  );
  _map(present, _words('e st t est et'), 'en', v, v);
  _map(present, _words('le elst elt'), 'eln', v, v);
  _map(present, _words('re erst ert'), 'ern', v, v);

  final TransformRules preterite = table.transform(
    'preterite',
    'Preterite (simple past) form of a verb',
  );
  _map(preterite, _words('te test ten tet ete etest eten etet'), 'en', v, v);
  _map(preterite, _words('elte eltest elten eltet'), 'eln', v, v);
  _map(preterite, _words('erte ertest erten ertet'), 'ern', v, v);

  final TransformRules participle = table.transform(
    'participle',
    'Participle form of a verb',
  )..prefix('ge', '', adj, const <String>['vpp']);
  for (final String p in _germanSeparablePrefixes) {
    participle.prefix('${p}ge', p, adj, const <String>['vpp']);
  }
  participle
    ..suffix('t', 'en', const <String>['vpp'], const <String>['vw'])
    ..suffix('et', 'en', const <String>['vpp'], const <String>['vw'])
    ..suffix('elt', 'eln', const <String>['vpp'], const <String>['vw'])
    ..suffix('ert', 'ern', const <String>['vpp'], const <String>['vw'])
    ..suffix('iert', 'ieren', adj, const <String>['vw']);

  final TransformRules irregular = table.transform(
    'irregular',
    'Irregular form of a verb',
  );
  for (final MapEntry<String, String> verb in _germanStrongVerbs.entries) {
    for (final String form in _words(verb.value)) {
      irregular.suffix(form, verb.key, v, const <String>['vs']);
    }
  }

  final TransformRules plural = table.transform(
    'plural',
    'Plural form of a noun',
  );
  const List<String> np = <String>['np'];
  _map(plural, _words('e en n er s nen'), '', np, n);
  plural.suffix('sse', 's', np, n);
  for (final (String umlaut, String plain) in _germanUmlauts) {
    for (final String c in _germanUmlautClusters) {
      // Hand -> Hände, Haus -> Häuser.
      plural
        ..suffix('$umlaut${c}e', '$plain$c', np, n)
        ..suffix('$umlaut${c}er', '$plain$c', np, n);
      // Mutter -> Mütter, Vogel -> Vögel, Garten -> Gärten.
      for (final String tail in const <String>['er', 'el', 'en']) {
        plural.suffix('$umlaut$c$tail', '$plain$c$tail', np, n);
      }
    }
  }
  table
      .transform('dative plural', 'Dative plural form of a noun')
      .suffix('n', '', n, np);
  final TransformRules genitive = table.transform(
    'genitive',
    'Genitive form of a noun',
  );
  _map(genitive, _words('s es'), '', n, n);

  final TransformRules declension = table.transform(
    'adjective ending',
    'Inflected form of an adjective',
  );
  _map(declension, _words('e en em er es'), '', adj, adj);
  _map(declension, _words('le len lem ler les'), 'el', adj, adj);
  _map(declension, _words('re ren rem rer res'), 'er', adj, adj);

  final TransformRules comparative = table.transform(
    'comparative',
    'Comparative form of an adjective',
  )..suffix('er', '', adj, adj);
  final TransformRules superlative = table.transform(
    'superlative',
    'Superlative form of an adjective',
  );
  _map(superlative, _words('st est'), '', adj, adj);
  for (final (String umlaut, String plain) in _germanUmlauts) {
    for (final String c in _germanUmlautClusters) {
      comparative.suffix('$umlaut${c}er', '$plain$c', adj, adj);
      superlative
        ..suffix('$umlaut${c}st', '$plain$c', adj, adj)
        ..suffix('$umlaut${c}est', '$plain$c', adj, adj);
    }
  }
  for (final (String form, String lemma) in const <(String, String)>[
    ('besser', 'gut'),
    ('mehr', 'viel'),
    ('lieber', 'gern'),
    ('höher', 'hoch'),
    ('näher', 'nah'),
  ]) {
    comparative.whole(form, lemma, adj, adj);
  }
  for (final (String form, String lemma) in const <(String, String)>[
    ('best', 'gut'),
    ('meist', 'viel'),
    ('liebst', 'gern'),
    ('höchst', 'hoch'),
    ('nächst', 'nah'),
  ]) {
    superlative.whole(form, lemma, adj, adj);
  }
  return table;
}

// ---------------------------------------------------------------------------
// Latin (dictionary form of a verb: 1st person singular present, amo)
// ---------------------------------------------------------------------------

/// Personal endings, appended to a tense marker.
const List<String> _laActive = <String>['m', 's', 't', 'mus', 'tis', 'nt'];
const List<String> _laPassive = <String>[
  'r', 'ris', 'tur', 'mur', 'mini', 'ntur', //
];

List<String> _laTense(String marker) => <String>[
  for (final String e in _laActive) '$marker$e',
];

List<String> _laTensePassive(String marker) => <String>[
  for (final String e in _laPassive) '$marker$e',
];

/// Perfect-system forms for a perfect stem ending ([stem] is the part that
/// replaces the lemma ending: av for amo -> amavi).
List<String> _laPerfect(String stem) => <String>[
  for (final String e in _words(
    'i isti it imus istis erunt ere isse ero eris erit erimus eritis erint '
    'erim',
  ))
    '$stem$e',
  ..._laTense('${stem}era'),
  ..._laTense('${stem}isse'),
];

TransformTable latin() {
  final TransformTable table = TransformTable(
    'la',
    _conditionsExtending('la', <String, Object>{
      // An inflected noun form. Declension rules go from nf to the dictionary
      // form and never back, so they cannot loop (-is -> -e -> -is).
      'n': _cond('Noun', sub: <String>['ns', 'np', 'nf']),
      'nf': _cond('Noun, inflected form', dict: false),
    }),
    fileName: 'la_extended',
  );
  const List<String> v = <String>['v'];
  final TransformRules verb = table.transform(
    'conjugation',
    'Conjugated form of a verb',
  );

  // 1st conjugation: amo, amare.
  _map(
    verb,
    <String>[
      ..._words('as at amus atis ant are a ate ari'),
      ..._laTense('aba'),
      ..._words('abo abis abit abimus abitis abunt'),
      ..._words('em es et emus etis ent'),
      ..._laTense('are'),
      ..._words('or aris atur amur amini antur'),
      ..._laTensePassive('aba'),
      ..._words('abor aberis abitur abimur abimini abuntur'),
      ..._words('er eris etur emur emini entur'),
      ..._laTensePassive('are'),
      ..._laPerfect('av'),
      ..._words('ans antis antem anti ante antes antium antibus'),
      ..._words('andum andi ando andus anda'),
    ],
    'o',
    v,
    v,
  );

  // 2nd conjugation: moneo, monere.
  _map(
    verb,
    <String>[
      ..._words('es et emus etis ent ere e ete eri'),
      ..._laTense('eba'),
      ..._words('ebo ebis ebit ebimus ebitis ebunt'),
      ..._words('eam eas eat eamus eatis eant'),
      ..._laTense('ere'),
      ..._words('eor eris etur emur emini entur'),
      ..._laTensePassive('eba'),
      ..._words('ebor eberis ebitur ebimur ebimini ebuntur'),
      ..._words('ear earis eatur eamur eamini eantur'),
      ..._laTensePassive('ere'),
      ..._laPerfect('u'),
      ..._words('ens entis entem enti ente entes entium entibus'),
      ..._words('endum endi endo endus enda'),
    ],
    'eo',
    v,
    v,
  );

  // 3rd conjugation: rego, regere.
  _map(
    verb,
    <String>[
      ..._words('is it imus itis unt ere e ite i'),
      ..._laTense('eba'),
      ..._words('am es et emus etis ent'),
      ..._words('as at amus atis ant'),
      ..._laTense('ere'),
      ..._words('or eris itur imur imini untur'),
      ..._laTensePassive('eba'),
      ..._words('ar etur emur emini entur aris atur amur amini antur'),
      ..._laTensePassive('ere'),
      ..._words('ens entis entem enti ente entes entium entibus'),
      ..._words('endum endi endo endus enda'),
    ],
    'o',
    v,
    v,
  );

  // 3rd -io and 4th conjugation: capio, audio.
  _map(
    verb,
    <String>[
      ..._words('is it imus itis iunt ire i ite iri ere'),
      ..._laTense('ieba'),
      ..._words('iam ies iet iemus ietis ient ias iat iamus iatis iant'),
      ..._laTense('ire'),
      ..._laTense('ere'),
      ..._words('ior iris itur imur imini iuntur'),
      ..._laTensePassive('ieba'),
      ..._words('iar ieris ietur iemur iemini ientur'),
      ..._laTensePassive('ire'),
      ..._laPerfect('iv'),
      ..._words('iens ientis ientem ienti iente ientes ientium ientibus'),
      ..._words('iendum iendi iendo iendus ienda'),
    ],
    'io',
    v,
    v,
  );

  // Perfect passive participle (amatus, monitus, auditus), declined through
  // the adjective rules below.
  final TransformRules ppp = table.transform(
    'perfect participle',
    'Participle form of a verb',
  );
  ppp
    ..suffix('atus', 'o', const <String>['adj12'], v)
    ..suffix('aturus', 'o', const <String>['adj12'], v)
    ..suffix('itus', 'eo', const <String>['adj12'], v)
    ..suffix('itus', 'io', const <String>['adj12'], v)
    ..suffix('iturus', 'io', const <String>['adj12'], v);

  final TransformRules irregular = table.transform(
    'irregular',
    'Irregular form of a verb',
  );
  void forms(String lemma, String list, {bool asSuffix = false}) {
    for (final String f in _words(list)) {
      if (asSuffix) {
        irregular.suffix(f, lemma, v, v);
      } else {
        irregular.whole(f, lemma, v, v);
      }
    }
  }

  forms(
    'sum',
    'es est sumus estis sunt eram eras erat eramus eratis erant ero eris erit '
        'erimus eritis erunt sim sis sit simus sitis sint essem esses esset '
        'essemus essetis essent esse fui fuisti fuit fuimus fuistis fuerunt '
        'fueram fueras fuerat fueramus fueratis fuerant fuero fueris fuerit '
        'fuerimus fueritis fuerint fuissem fuisses fuisset fuissemus fuissetis '
        'fuissent fuisse futurus esto este',
  );
  forms(
    'possum',
    'potes potest possumus potestis possunt poteram poteras poterat '
        'poteramus poteratis poterant potero poteris poterit poterimus '
        'poteritis poterunt possim possis possit possimus possitis possint '
        'possem posses posset possemus possetis possent posse potui potuisti '
        'potuit potuimus potuistis potuerunt potueram potuero potuissem '
        'potuisse',
  );
  forms('eo', 'is it imus itis i ite ire ii iit');
  forms(
    'eo',
    'eunt ibam ibas ibat ibamus ibatis ibant ibo ibis ibit ibimus ibitis '
        'ibunt eam eas eat eamus eatis eant irem ires iret iremus iretis '
        'irent ivi ivisti ivit ivimus ivistis iverunt isti ierunt iens euntis '
        'eundum',
    asSuffix: true,
  );
  forms(
    'fero',
    'fers fert ferimus fertis ferunt ferebam ferebas ferebat ferebamus '
        'ferebatis ferebant feram feres feret feremus feretis ferent ferrem '
        'ferres ferret ferremus ferretis ferrent ferre fer ferte tuli tulisti '
        'tulit tulimus tulistis tulerunt tuleram tulero tulissem tulisse latus '
        'ferens ferentis',
    asSuffix: true,
  );
  forms(
    'volo',
    'vis vult volumus vultis volunt volebam volebas volebat volebamus '
        'volebatis volebant volam voles volet volemus voletis volent velim '
        'velis velit velimus velitis velint vellem velles vellet vellemus '
        'velletis vellent velle volui voluisti voluit voluimus voluistis '
        'voluerunt volens volentis',
  );
  forms(
    'nolo',
    'nolumus nolunt nolebam nolam nolim nolis nolit nollem nolle noli nolite '
        'nolui',
  );
  forms(
    'malo',
    'mavis mavult malumus mavultis malunt malebam malam malim mallem malle '
        'malui',
  );
  forms(
    'fio',
    'fis fit fimus fitis fiunt fiebam fiebas fiebat fiebamus fiebatis '
        'fiebant fiam fies fiet fiemus fietis fient fierem fieres fieret '
        'fieremus fieretis fierent fieri',
  );

  // Nouns: every case to the nominative singular.
  const List<String> n = <String>['nf'];
  const List<String> ns = <String>['ns'];
  final TransformRules noun = table.transform(
    'declension',
    'Declined form of a noun',
  );
  _map(noun, _words('ae am arum is as'), 'a', n, ns);
  _map(noun, _words('i o um e orum is os'), 'us', n, ns);
  _map(noun, _words('ri ro rum rorum ris ros'), 'er', n, ns);
  _map(noun, _words('eri ero erum erorum eris eros'), 'er', n, ns);
  _map(noun, _words('i o a orum is'), 'um', n, ns);
  for (final (String nominative, String stem) in const <(String, String)>[
    ('tio', 'tion'),
    ('tas', 'tat'),
    ('tus', 'tut'),
    ('or', 'or'),
    ('x', 'c'),
    ('x', 'g'),
    ('men', 'min'),
    ('us', 'or'),
    ('us', 'er'),
    ('o', 'on'),
    ('o', 'in'),
    ('do', 'din'),
    ('go', 'gin'),
    ('ns', 'nt'),
    ('rs', 'rt'),
    ('l', 'l'),
    ('ter', 'tr'),
    ('al', 'al'),
    ('ar', 'ar'),
    ('is', ''),
    ('es', ''),
    ('e', ''),
  ]) {
    _map(
      noun,
      <String>[
        for (final String e in _words('is i em e es um ium ibus a ia'))
          '$stem$e',
      ],
      nominative,
      n,
      ns,
    );
  }
  _map(noun, _words('us ui um u uum ibus'), 'us', n, ns);
  _map(noun, _words('ua uum ibus'), 'u', n, ns);
  _map(noun, _words('ei em e erum ebus'), 'es', n, ns);

  // Adjectives.
  const List<String> adj12 = <String>['adj12'];
  const List<String> adj3 = <String>['adj3'];
  final TransformRules adjective = table.transform(
    'adjective declension',
    'Inflected form of an adjective',
  );
  _map(
    adjective,
    _words('a um i o ae am os as orum arum is e'),
    'us',
    adj12,
    adj12,
  );
  _map(
    adjective,
    _words('ra rum ri ro rae ram ros ras rorum rarum ris'),
    'er',
    adj12,
    adj12,
  );
  _map(adjective, _words('e em i ium ibus es ia'), 'is', adj3, adj3);
  _map(
    adjective,
    _words('ntis nti ntem nte ntes ntia ntium ntibus'),
    'ns',
    adj3,
    adj3,
  );
  final TransformRules comparative = table.transform(
    'comparative',
    'Comparative form of an adjective',
  );
  final List<String> comparativeForms = _words(
    'ior ius ioris iori iorem iore iores iora iorum ioribus',
  );
  _map(comparative, comparativeForms, 'us', adj3, adj12);
  _map(comparative, comparativeForms, 'is', adj3, adj3);
  final TransformRules superlative =
      table.transform('superlative', 'Superlative form of an adjective')
        ..suffix('issimus', 'us', adj12, adj12)
        ..suffix('issimus', 'is', adj12, adj3)
        ..suffix('errimus', 'er', adj12, adj12)
        ..suffix('illimus', 'ilis', adj12, adj3);
  for (final (String form, String lemma) in const <(String, String)>[
    ('melior', 'bonus'),
    ('optimus', 'bonus'),
    ('peior', 'malus'),
    ('pessimus', 'malus'),
    ('maior', 'magnus'),
    ('maximus', 'magnus'),
    ('minor', 'parvus'),
    ('minimus', 'parvus'),
    ('plus', 'multus'),
    ('plurimus', 'multus'),
  ]) {
    superlative.whole(form, lemma, adj12, adj12);
  }
  final TransformRules adverb =
      table.transform('adverb', 'Adverb form of an adjective')
        ..suffix('e', 'us', const <String>['adv'], adj12)
        ..suffix('iter', 'is', const <String>['adv'], adj3)
        ..suffix('nter', 'ns', const <String>['adv'], adj3);
  adverb.suffix('ius', 'us', const <String>['adv'], adj12);
  return table;
}

// ---------------------------------------------------------------------------
// Modern Greek (dictionary form of a verb: 1st person singular present)
// ---------------------------------------------------------------------------

TransformTable greek() {
  final TransformTable table = TransformTable(
    'el',
    _conditionsExtending('el', <String, Object>{
      // Inflected and dictionary forms are separate conditions, so declension
      // rules cannot loop (-α -> -ας -> -α).
      'n': _cond('Noun', sub: <String>['nd', 'nf']),
      'nd': _cond('Noun, dictionary form'),
      'nf': _cond('Noun, inflected form', dict: false),
      'adj': _cond('Adjective', sub: <String>['adjd', 'adjf']),
      'adjd': _cond('Adjective, dictionary form'),
      'adjf': _cond('Adjective, inflected form', dict: false),
    }),
    fileName: 'el_extended',
  );
  const List<String> v = <String>['v'];
  const List<String> nf = <String>['nf'];
  const List<String> nd = <String>['nd'];
  const List<String> adjf = <String>['adjf'];
  const List<String> adjd = <String>['adjd'];

  final TransformRules present = table.transform(
    'present',
    'Present tense form of a verb',
  );
  _map(present, _words('εις ει ουμε ετε ουν ουνε'), 'ω', v, v);
  _map(present, _words('άς άει άμε άτε άνε ούν ούνε άω'), 'ώ', v, v);
  _map(present, _words('είς εί ούμε είτε'), 'ώ', v, v);
  _map(present, _words('εσαι εται όμαστε εστε όσαστε ονται'), 'ομαι', v, v);
  _map(present, _words('ιέσαι ιέται ιόμαστε ιέστε ιούνται'), 'ιέμαι', v, v);
  _map(present, _words('άσαι άται άστε'), 'άμαι', v, v);
  _map(present, _words('είσαι είται ούμαστε είστε ούνται'), 'ούμαι', v, v);

  final TransformRules imperfect = table.transform(
    'imperfect',
    'Imperfect form of a verb',
  );
  _map(
    imperfect,
    _words('ούσα ούσες ούσε ούσαμε ούσατε ούσαν ούσανε'),
    'ώ',
    v,
    v,
  );
  _map(
    imperfect,
    _words('όμουν όμουνα όσουν όσουνα όταν όμασταν όσασταν όντουσαν ονταν'),
    'ομαι',
    v,
    v,
  );

  // Aorist subjunctive / future (θα γυρίσω) and the aorist plural, where the
  // accent stays on the syllable it has in the dictionary form.
  final TransformRules aorist = table.transform(
    'aorist',
    'Aorist (simple past) form of a verb',
  );
  for (final (String stem, String lemma) in const <(String, String)>[
    ('ίσ', 'ίζω'),
    ('ώσ', 'ώνω'),
    ('ήσ', 'ώ'),
    ('έψ', 'εύω'),
    ('άσ', 'άζω'),
    ('έσ', 'ώ'),
  ]) {
    _map(
      aorist,
      <String>[
        for (final String e in _words('ω εις ει ουμε ετε ουν αμε ατε ε τε'))
          '$stem$e',
      ],
      lemma,
      v,
      v,
    );
  }
  final TransformRules participle = table.transform(
    'participle',
    'Participle form of a verb',
  );
  for (final (String form, String lemma) in const <(String, String)>[
    ('ισμένος', 'ίζω'),
    ('ωμένος', 'ώνω'),
    ('ημένος', 'ώ'),
    ('ασμένος', 'άζω'),
    ('οντας', 'ω'),
    ('ώντας', 'ώ'),
  ]) {
    participle.suffix(form, lemma, adjd, v);
  }

  final TransformRules irregular = table.transform(
    'irregular',
    'Irregular form of a verb',
  );
  for (final MapEntry<String, String> verb in const <String, String>{
    'είμαι':
        'είσαι είναι είμαστε είστε είσαστε ήμουν ήμουνα ήσουν ήσουνα '
        'ήταν ήτανε ήμασταν ήσασταν ήσαστε',
    'έχω': 'είχα είχες είχε είχαμε είχατε είχαν είχανε',
    'λέω':
        'λες λέει λέμε λέτε λένε είπα είπες είπε είπαμε είπατε είπαν πω '
        'πεις πει πούμε πείτε πουν πες πείτε έλεγα έλεγες έλεγε λέγαμε λέγατε '
        'έλεγαν',
    'πηγαίνω':
        'πάω πας πάει πάμε πάτε πάνε πήγα πήγες πήγε πήγαμε πήγατε '
        'πήγαν πήγανε',
    'κάνω': 'έκανα έκανες έκανε κάναμε κάνατε έκαναν κάνε κάντε',
    'βλέπω':
        'είδα είδες είδε είδαμε είδατε είδαν δω δεις δει δούμε δείτε '
        'δουν έβλεπα έβλεπες έβλεπε βλέπαμε βλέπατε έβλεπαν δες',
    'τρώω':
        'τρως τρώει τρώμε τρώτε τρώνε έφαγα έφαγες έφαγε φάγαμε φάγατε '
        'έφαγαν φάω φας φάει φάμε φάτε φάνε',
    'έρχομαι':
        'ήρθα ήρθες ήρθε ήρθαμε ήρθατε ήρθαν ήρθανε έρθω έρθεις έρθει '
        'έρθουμε έρθετε έρθουν έλα ελάτε ερχόμουν ερχόταν',
    'ξέρω': 'ήξερα ήξερες ήξερε ξέραμε ξέρατε ήξεραν',
    'θέλω': 'ήθελα ήθελες ήθελε θέλαμε θέλατε ήθελαν',
    'δίνω':
        'έδωσα έδωσες έδωσε δώσαμε δώσατε έδωσαν δώσω δώσεις δώσει '
        'δώσουμε δώσετε δώσουν δώσε',
    'παίρνω':
        'πήρα πήρες πήρε πήραμε πήρατε πήραν πάρω πάρεις πάρει πάρουμε '
        'πάρετε πάρουν πάρε',
    'βρίσκω':
        'βρήκα βρήκες βρήκε βρήκαμε βρήκατε βρήκαν βρω βρεις βρει '
        'βρούμε βρείτε βρουν',
    'μένω':
        'έμεινα έμεινες έμεινε μείναμε μείνατε έμειναν μείνω μείνεις '
        'μείνει',
    'φεύγω':
        'έφυγα έφυγες έφυγε φύγαμε φύγατε έφυγαν φύγω φύγεις φύγει '
        'φύγουμε φύγετε φύγουν',
    'βγαίνω': 'βγήκα βγήκες βγήκε βγήκαμε βγήκατε βγήκαν βγω βγεις βγει',
    'μπαίνω': 'μπήκα μπήκες μπήκε μπήκαμε μπήκατε μπήκαν μπω μπεις μπει',
    'πίνω':
        'ήπια ήπιες ήπιε ήπιαμε ήπιατε ήπιαν πιω πιεις πιει πιούμε '
        'πιείτε πιουν',
    'ακούω':
        'ακούς ακούει ακούμε ακούτε ακούνε άκουσα άκουσες άκουσε '
        'ακούσαμε ακούσατε άκουσαν ακούσω ακούσεις ακούσει',
    'μπορώ':
        'μπόρεσα μπόρεσες μπόρεσε μπορέσαμε μπορέσατε μπόρεσαν μπορέσω '
        'μπορέσεις μπορέσει',
  }.entries) {
    for (final String f in _words(verb.value)) {
      irregular.whole(f, verb.key, v, v);
    }
  }

  final TransformRules noun = table.transform(
    'declension',
    'Declined form of a noun',
  );
  _map(noun, _words('ου ο ε οι ων ους'), 'ος', nf, nd);
  _map(noun, _words('α ες ων'), 'ας', nf, nd);
  _map(noun, _words('η ες ων'), 'ης', nf, nd);
  _map(noun, _words('άδες άδων'), 'άς', nf, nd);
  _map(noun, _words('ήδες ήδων'), 'ής', nf, nd);
  _map(noun, _words('ας ες ων'), 'α', nf, nd);
  _map(noun, _words('ης ες εις ων'), 'η', nf, nd);
  _map(noun, _words('σεις σεων'), 'ση', nf, nd);
  _map(noun, _words('ξεις ξεων'), 'ξη', nf, nd);
  _map(noun, _words('ψεις ψεων'), 'ψη', nf, nd);
  _map(noun, _words('ου α ων'), 'ο', nf, nd);
  _map(noun, _words('ιού ια ιών'), 'ι', nf, nd);
  _map(noun, _words('ματος ματα μάτων ματα'), 'μα', nf, nd);
  _map(noun, _words('ους η ων'), 'ος', nf, nd);
  // End-stressed paradigms keep the accent on the ending.
  _map(noun, _words('ού ό έ οί ών ούς'), 'ός', nf, nd);
  _map(noun, _words('άς ές ών'), 'ά', nf, nd);
  _map(noun, _words('ής ές ών'), 'ή', nf, nd);
  _map(noun, _words('ού ά ών'), 'ό', nf, nd);
  _map(noun, _words('ιού ιά ιών'), 'ί', nf, nd);

  final TransformRules adjective = table.transform(
    'adjective declension',
    'Inflected form of an adjective',
  );
  _map(adjective, _words('η ης ες α ας ο ου οι ων ους ε'), 'ος', adjf, adjd);
  _map(adjective, _words('ή ής ές ά άς ό ού οί ών ούς έ'), 'ός', adjf, adjd);
  _map(adjective, _words('ούς ή είς ών'), 'ής', adjf, adjd);
  _map(adjective, _words('ιά ιάς ιές ιοί ιών ιούς'), 'ύς', adjf, adjd);
  return table;
}

// ---------------------------------------------------------------------------
// Russian (infinitive / nominative singular)
// ---------------------------------------------------------------------------

/// Verb classes: infinitive ending and the endings replacing it.
const Map<String, String> _ruVerbClasses = <String, String>{
  'ать':
      'аю аешь ает аем аете ают ай айте ал ала ало али ая ав авши ающий '
      'авший анный ан ана ано аны',
  'ять':
      'яю яешь яет яем яете яют яй яйте ял яла яло яли яя яв явши яющий '
      'явший янный',
  'еть':
      'ею еешь еет еем еете еют ей ейте ел ела ело ели ея ев евши еющий '
      'евший ю ишь ит им ите ят и',
  'ить':
      'ю у ишь ит им ите ят ат и ил ила ило или я ив ивши ящий ащий ивший '
      'енный ённый ен ена ено ены',
  'овать':
      'ую уешь ует уем уете уют уй уйте овал овала овало овали уя овав '
      'ующий овавший ованный',
  'евать':
      'юю юешь юет юем юете юют юй юйте евал евала евало евали юя '
      'евав',
  'нуть':
      'ну нешь нет нем нете нут ни ните нул нула нуло нули нув нувший '
      'нутый',
  'сать': 'шу шешь шет шем шете шут ши шите',
  'зать': 'жу жешь жет жем жете жут жи жите',
  'кать': 'чу чешь чет чем чете чут чи чите',
  'тать': 'чу чешь чет чем чете чут чи чите',
  'ыть': 'ою оешь оет оем оете оют ой ойте',
  'дить': 'жу',
  'зить': 'жу',
  'деть': 'жу',
  'тить': 'чу щу',
  'стить': 'щу',
  'сить': 'шу',
  'бить': 'блю',
  'пить': 'плю',
  'вить': 'влю',
  'мить': 'млю',
};

const Map<String, String> _ruIrregularVerbs = <String, String>{
  'быть':
      'буду будешь будет будем будете будут был была было были будь '
      'будьте',
  'идти':
      'иду идёшь идёт идём идёте идут иди идите шёл шла шло шли идя '
      'идущий шедший',
  'йти': 'йду йдёшь йдёт йдём йдёте йдут йди йдите шёл шла шло шли йдя',
  'прийти': 'приду придёшь придёт придём придёте придут приди придите',
  'ехать': 'еду едешь едет едем едете едут ехал ехала ехало ехали',
  'есть': 'ем ешь ест едим едите едят ел ела ело ели',
  'хотеть': 'хочу хочешь хочет хотим хотите хотят',
  'мочь': 'могу можешь может можем можете могут мог могла могло могли',
  'дать': 'дам дашь даст дадим дадите дадут дал дала дало дали дай дайте',
  'давать': 'даю даёшь даёт даём даёте дают давай давайте',
  'жить': 'живу живёшь живёт живём живёте живут жил жила жило жили живи',
  'брать': 'беру берёшь берёт берём берёте берут бери берите',
  'взять':
      'возьму возьмёшь возьмёт возьмём возьмёте возьмут взял взяла '
      'взяло взяли возьми',
  'пить': 'пью пьёшь пьёт пьём пьёте пьют пей пейте',
  'бить': 'бью бьёшь бьёт бьём бьёте бьют бей',
  'лить': 'лью льёшь льёт льём льёте льют лей',
  'петь': 'пою поёшь поёт поём поёте поют пой',
  'спать': 'сплю спишь спит спим спите спят спи',
  'стать': 'стану станешь станет станем станете станут стань',
  'сесть': 'сяду сядешь сядет сядем сядете сядут сел села село сели сядь',
  'лечь': 'лягу ляжешь ляжет ляжем ляжете лягут лёг легла легло легли ляг',
  'начать':
      'начну начнёшь начнёт начнём начнёте начнут начал начала начало '
      'начали начни',
  'понять':
      'пойму поймёшь поймёт поймём поймёте поймут понял поняла поняло '
      'поняли пойми',
  'принять':
      'приму примешь примет примем примете примут принял приняла '
      'приняли прими',
  'снять': 'сниму снимешь снимет снимем снимете снимут снял сняла сняли',
  'умереть': 'умру умрёшь умрёт умрём умрёте умрут умер умерла умерли',
  'расти': 'расту растёшь растёт растём растёте растут рос росла росли',
  'нести': 'несу несёшь несёт несём несёте несут нёс несла несли неси',
  'вести': 'веду ведёшь ведёт ведём ведёте ведут вёл вела вели веди',
  'везти': 'везу везёшь везёт везём везёте везут вёз везла везли',
  'помочь':
      'помогу поможешь поможет поможем поможете помогут помог помогла '
      'помогли помоги',
};

const Map<String, String> _ruIrregularAdjectives = <String, String>{
  'большой': 'больше',
  'хороший': 'лучше',
  'плохой': 'хуже',
  'маленький': 'меньше',
  'высокий': 'выше',
  'низкий': 'ниже',
  'далёкий': 'дальше',
  'дорогой': 'дороже',
  'молодой': 'моложе',
  'старый': 'старше',
  'простой': 'проще',
  'лёгкий': 'легче',
  'тихий': 'тише',
  'громкий': 'громче',
  'поздний': 'позже',
  'ранний': 'раньше',
};

/// A form that ends in a vowel takes -сь as the reflexive ending, any other
/// -ся.
String _ruReflexive(String form) =>
    RegExp(r'[аеёиоуыэюя]$').hasMatch(form) ? '$formсь' : '$formся';

TransformTable russian() {
  final TransformTable table = TransformTable('ru', <String, Object>{
    'v': _cond('Verb'),
    // Inflected and dictionary forms are separate conditions, so declension
    // rules cannot loop (-я -> -ь -> -я).
    'n': _cond('Noun', sub: <String>['nd', 'nf']),
    'nd': _cond('Noun, dictionary form'),
    'nf': _cond('Noun, inflected form', dict: false),
    'adj': _cond('Adjective', sub: <String>['adjd', 'adjf']),
    'adjd': _cond('Adjective, dictionary form'),
    'adjf': _cond('Adjective, inflected form', dict: false),
    'adv': _cond('Adverb'),
  });
  const List<String> v = <String>['v'];
  const List<String> n = <String>['nf'];
  const List<String> nd = <String>['nd'];
  const List<String> adj = <String>['adjf'];
  const List<String> adjd = <String>['adjd'];

  final TransformRules noun = table.transform(
    'declension',
    'Declined form of a noun',
  );
  _map(noun, _words('а у ом е ы ов ам ами ах ей и'), '', n, nd);
  _map(noun, _words('я ю ем ём е и ей ям ями ях'), 'ь', n, nd);
  _map(noun, _words('я ю ем ём е и ев ёв ям ями ях'), 'й', n, nd);
  _map(noun, _words('ы и е у ой ою ам ами ах'), 'а', n, nd);
  _map(noun, _words('и е ю ей ёй ею ям ями ях ь'), 'я', n, nd);
  _map(noun, _words('ии ию ией ий иям иями иях'), 'ия', n, nd);
  _map(noun, _words('и ью ей ям ями ях'), 'ь', n, nd);
  _map(noun, _words('а у ом е ам ами ах'), 'о', n, nd);
  _map(noun, _words('я ю ем ей ям ями ях'), 'е', n, nd);
  _map(noun, _words('ия ию ием ии ий иям иями иях'), 'ие', n, nd);
  _map(noun, _words('мени менем мена мён менам менами менах'), 'мя', n, nd);

  final TransformRules adjective = table.transform(
    'adjective declension',
    'Inflected form of an adjective',
  );
  final List<String> adjectiveEndings = _words(
    'ая ое ые ого ому ым ом ой ую ых ыми ее яя юю ие его ему им ем ей их ими',
  );
  for (final String lemma in const <String>['ый', 'ий', 'ой']) {
    _map(adjective, adjectiveEndings, lemma, adj, adjd);
  }
  final TransformRules shortForm = table.transform(
    'short form',
    'Short form of an adjective',
  );
  _map(shortForm, _words('а о ы'), 'ый', adj, adjd);
  final TransformRules comparative = table.transform(
    'comparative',
    'Comparative form of an adjective',
  );
  _map(comparative, _words('ее ей'), 'ый', adj, adjd);
  for (final MapEntry<String, String> e in _ruIrregularAdjectives.entries) {
    comparative.whole(e.value, e.key, adj, adjd);
  }
  final TransformRules superlative = table.transform(
    'superlative',
    'Superlative form of an adjective',
  );
  _map(superlative, _words('ейший айший'), 'ый', adjd, adjd);

  final TransformRules verb = table.transform(
    'conjugation',
    'Conjugated form of a verb',
  );
  final TransformRules reflexive = table.transform(
    'reflexive',
    'Reflexive form of a verb',
  );
  for (final MapEntry<String, String> cls in _ruVerbClasses.entries) {
    for (final String form in _words(cls.value)) {
      // Participles decline like adjectives: the adjective rules hand them
      // over in their dictionary form.
      final List<String> into = form.endsWith('ий') || form.endsWith('ый')
          ? adjd
          : v;
      verb.suffix(form, cls.key, into, v);
      if (into == v) {
        reflexive.suffix(_ruReflexive(form), '${cls.key}ся', v, v);
      }
    }
  }
  final TransformRules irregular = table.transform(
    'irregular',
    'Irregular form of a verb',
  );
  for (final MapEntry<String, String> e in _ruIrregularVerbs.entries) {
    for (final String form in _words(e.value)) {
      // Suffix rules carry the prefixed verbs (поехать, отдать, собрать);
      // the bare short forms of быть / есть stay whole words.
      if (form.length <= 2) {
        irregular.whole(form, e.key, v, v);
      } else {
        irregular.suffix(form, e.key, v, v);
      }
    }
  }
  return table;
}

void main() {
  if (!Directory(_kTransformsDir).existsSync()) {
    stderr.writeln('Run from fushi/: assets/transforms not found.');
    exitCode = 2;
    return;
  }
  for (final TransformTable table in <TransformTable>[
    german(),
    latin(),
    greek(),
    russian(),
  ]) {
    File(
      '$_kTransformsDir/${table.fileName}.json',
    ).writeAsStringSync('${table.encode()}\n');
  }
}
