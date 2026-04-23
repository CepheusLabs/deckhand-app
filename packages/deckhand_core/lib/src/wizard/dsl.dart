/// Tiny expression DSL evaluator for profile.yaml `when:` / `default_rules`
/// blocks. Spec lives in deckhand-builds/AUTHORING.md.
///
/// Grammar (recursive descent):
///   expr   := and ( 'OR' and )*
///   and    := not ( 'AND' not )*
///   not    := 'NOT' not | atom
///   atom   := '(' expr ')' | predicate
///   predicate := IDENT '(' ( arg (',' arg)* )? ')'
///   arg    := string | number | bool | bareword | list
///   list   := '[' ( arg (',' arg)* )? ']'
///
/// Predicates are registered by the Deckhand runtime, not by profiles.
class DslEvaluator {
  DslEvaluator(this.predicates);

  final Map<String, DslPredicate> predicates;

  bool evaluate(String source, DslEnv env) {
    final tokens = _tokenize(source);
    final parser = _Parser(tokens);
    final node = parser.parseExpr();
    if (!parser.isAtEnd) {
      throw DslException(
        'unexpected tokens after expression: ${parser.peek()}',
      );
    }
    return _eval(node, env);
  }

  bool _eval(_Node n, DslEnv env) {
    switch (n) {
      case _NotNode(:final inner):
        return !_eval(inner, env);
      case _AndNode(:final left, :final right):
        return _eval(left, env) && _eval(right, env);
      case _OrNode(:final left, :final right):
        return _eval(left, env) || _eval(right, env);
      case _PredicateNode(:final name, :final args):
        final fn = predicates[name];
        if (fn == null) {
          throw DslException('unknown predicate: $name');
        }
        return fn(args, env);
    }
  }
}

typedef DslPredicate = bool Function(List<Object?> args, DslEnv env);

/// Evaluation context - wizard decisions so far, plus callbacks for
/// predicates that need to run side-effectful probes.
class DslEnv {
  DslEnv({required this.decisions, required this.profile, this.probes});

  final Map<String, Object?> decisions;
  final Map<String, dynamic> profile; // the raw profile.yaml map
  final DslProbes? probes;

  Object? getDecision(String path) => decisions[path];
  Object? getProfileField(String path) {
    final parts = path.split('.');
    Object? cur = profile;
    for (final p in parts) {
      if (cur is Map) {
        cur = cur[p];
      } else {
        return null;
      }
    }
    return cur;
  }
}

abstract class DslProbes {
  Future<bool> remoteFileExists(String path);
  Future<bool> remoteServiceActive(String unit);
  Future<bool> remoteProcessRunning(String pattern);
  // Note: `os_python_below` used to live here as an async probe, but
  // we now evaluate it synchronously against `profile.os.stock.python`
  // (see defaultPredicates). An async probe against the live printer
  // can still be added later if a profile needs it.
}

class DslException implements Exception {
  DslException(this.message);
  final String message;
  @override
  String toString() => 'DslException: $message';
}

/// Default predicates shipped with Deckhand. Registered by the runtime
/// before evaluating profile expressions.
Map<String, DslPredicate> defaultPredicates() => {
  'equals': (args, env) {
    _expect(args, 2, 'equals');
    final v = env.getDecision(args[0] as String);
    return v == args[1];
  },
  'in_set': (args, env) {
    _expect(args, 2, 'in_set');
    final v = env.getDecision(args[0] as String);
    final list = (args[1] as List?) ?? const [];
    return list.contains(v);
  },
  'selected': (args, env) {
    _expect(args, 2, 'selected');
    final stepId = args[0] as String;
    final optionId = args[1] as String;
    final decision = env.getDecision(stepId);
    return decision == optionId;
  },
  'profile_field_equals': (args, env) {
    _expect(args, 2, 'profile_field_equals');
    return env.getProfileField(args[0] as String) == args[1];
  },
  'decision_made': (args, env) {
    _expect(args, 1, 'decision_made');
    return env.decisions.containsKey(args[0] as String);
  },
  'os_python_below': (args, env) {
    _expect(args, 1, 'os_python_below');
    final threshold = args[0];
    final threshStr = threshold is String
        ? threshold
        : threshold.toString();
    // Priority order (strongest signal first):
    //   1. Probe-cached decision (`probe.os_python_below.<thresh>`).
    //   2. Live default-python version (`probe.python_default`).
    //   3. Profile's declared `os.stock.python`.
    // Missing data is treated as "not below" so we don't run a python
    // rebuild we can't reason about.
    final cached = env.decisions['probe.os_python_below.$threshStr'];
    if (cached is bool) return cached;
    final livePy = env.decisions['probe.python_default'];
    if (livePy is String && livePy.isNotEmpty && livePy != 'unknown') {
      return _compareVersions(livePy, threshStr) < 0;
    }
    final stockRaw = env.getProfileField('os.stock.python');
    if (stockRaw is! String || stockRaw.trim().isEmpty) return false;
    return _compareVersions(stockRaw, threshStr) < 0;
  },
  // Matches the live /etc/os-release codename captured by the state
  // probe, not the profile's declared `os.stock.codename`. Use this
  // to gate steps that only apply to one specific distro snapshot -
  // e.g. `fix_apt_sources` rewriting sources.list for Buster but
  // leaving a user-upgraded Bookworm/Trixie install alone.
  'os_codename_is': (args, env) {
    _expect(args, 1, 'os_codename_is');
    final want = args[0];
    final actual = env.decisions['probe.os_codename'];
    if (actual is! String || want is! String) return false;
    return actual.toLowerCase() == want.toLowerCase();
  },
  'os_codename_in': (args, env) {
    _expect(args, 1, 'os_codename_in');
    final list = args[0];
    final actual = env.decisions['probe.os_codename'];
    if (actual is! String || list is! List) return false;
    final wanted = list.whereType<String>().map((s) => s.toLowerCase());
    return wanted.contains(actual.toLowerCase());
  },
};

/// Compare dotted version strings component-wise, numerically.
/// Non-integer components (e.g. a trailing "-rc1") are ignored.
/// Returns -1 if [a] < [b], 0 if equal, 1 if [a] > [b].
int _compareVersions(String a, String b) {
  final ap = a.split('.').map(_vpart).toList();
  final bp = b.split('.').map(_vpart).toList();
  final n = ap.length > bp.length ? ap.length : bp.length;
  for (var i = 0; i < n; i++) {
    final av = i < ap.length ? ap[i] : 0;
    final bv = i < bp.length ? bp[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return 0;
}

int _vpart(String s) {
  final m = RegExp(r'^(\d+)').firstMatch(s);
  return m == null ? 0 : int.parse(m.group(1)!);
}

void _expect(List<Object?> args, int n, String name) {
  if (args.length != n) {
    throw DslException('$name expects $n args, got ${args.length}');
  }
}

// -----------------------------------------------------------------
// Lexer

sealed class _Token {
  const _Token();
}

class _TIdent extends _Token {
  const _TIdent(this.v);
  final String v;
}

class _TString extends _Token {
  const _TString(this.v);
  final String v;
}

class _TNumber extends _Token {
  const _TNumber(this.v);
  final num v;
}

class _TBool extends _Token {
  const _TBool(this.v);
  final bool v;
}

class _TSymbol extends _Token {
  const _TSymbol(this.v);
  final String v;
}

List<_Token> _tokenize(String src) {
  final tokens = <_Token>[];
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (_isSpace(c)) {
      i++;
      continue;
    }
    if (c == '(' || c == ')' || c == ',' || c == '[' || c == ']') {
      tokens.add(_TSymbol(c));
      i++;
      continue;
    }
    if (c == '"') {
      final end = src.indexOf('"', i + 1);
      if (end < 0) throw DslException('unterminated string');
      tokens.add(_TString(src.substring(i + 1, end)));
      i = end + 1;
      continue;
    }
    if (_isDigit(c) ||
        (c == '-' && i + 1 < src.length && _isDigit(src[i + 1]))) {
      var j = i + 1;
      while (j < src.length && (_isDigit(src[j]) || src[j] == '.')) {
        j++;
      }
      tokens.add(_TNumber(num.parse(src.substring(i, j))));
      i = j;
      continue;
    }
    if (_isIdentStart(c)) {
      var j = i + 1;
      while (j < src.length && _isIdentPart(src[j])) {
        j++;
      }
      final word = src.substring(i, j);
      switch (word) {
        case 'true':
          tokens.add(const _TBool(true));
        case 'false':
          tokens.add(const _TBool(false));
        default:
          tokens.add(_TIdent(word));
      }
      i = j;
      continue;
    }
    throw DslException('unexpected char "$c" at offset $i in "$src"');
  }
  return tokens;
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
bool _isDigit(String c) => c.compareTo('0') >= 0 && c.compareTo('9') <= 0;
bool _isIdentStart(String c) =>
    (c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
    (c.compareTo('A') >= 0 && c.compareTo('Z') <= 0) ||
    c == '_';
bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c) || c == '.';

// -----------------------------------------------------------------
// Parser

sealed class _Node {}

class _NotNode extends _Node {
  _NotNode(this.inner);
  final _Node inner;
}

class _AndNode extends _Node {
  _AndNode(this.left, this.right);
  final _Node left;
  final _Node right;
}

class _OrNode extends _Node {
  _OrNode(this.left, this.right);
  final _Node left;
  final _Node right;
}

class _PredicateNode extends _Node {
  _PredicateNode(this.name, this.args);
  final String name;
  final List<Object?> args;
}

class _Parser {
  _Parser(this.tokens);
  final List<_Token> tokens;
  int i = 0;

  bool get isAtEnd => i >= tokens.length;
  _Token? peek() => isAtEnd ? null : tokens[i];
  _Token advance() => tokens[i++];

  _Node parseExpr() {
    var left = _parseAnd();
    while (_consumeIdent('OR')) {
      left = _OrNode(left, _parseAnd());
    }
    return left;
  }

  _Node _parseAnd() {
    var left = _parseNot();
    while (_consumeIdent('AND')) {
      left = _AndNode(left, _parseNot());
    }
    return left;
  }

  _Node _parseNot() {
    if (_consumeIdent('NOT')) {
      return _NotNode(_parseNot());
    }
    return _parseAtom();
  }

  _Node _parseAtom() {
    if (_consumeSymbol('(')) {
      final e = parseExpr();
      if (!_consumeSymbol(')')) {
        throw DslException('expected )');
      }
      return e;
    }
    final tok = advance();
    if (tok is _TIdent) {
      final name = tok.v;
      if (!_consumeSymbol('(')) {
        throw DslException('expected ( after predicate name $name');
      }
      final args = <Object?>[];
      if (!_consumeSymbol(')')) {
        while (true) {
          args.add(_parseArg());
          if (_consumeSymbol(')')) break;
          if (!_consumeSymbol(',')) throw DslException('expected , or )');
        }
      }
      return _PredicateNode(name, args);
    }
    throw DslException('unexpected token $tok at start of atom');
  }

  Object? _parseArg() {
    final tok = advance();
    return switch (tok) {
      _TString(:final v) => v,
      _TNumber(:final v) => v,
      _TBool(:final v) => v,
      _TIdent(:final v) => v,
      _TSymbol(v: '[') => _parseList(),
      _ => throw DslException('unexpected arg: $tok'),
    };
  }

  List<Object?> _parseList() {
    final items = <Object?>[];
    if (_consumeSymbol(']')) return items;
    while (true) {
      items.add(_parseArg());
      if (_consumeSymbol(']')) return items;
      if (!_consumeSymbol(',')) throw DslException('expected , or ] in list');
    }
  }

  bool _consumeIdent(String name) {
    final tok = peek();
    if (tok is _TIdent && tok.v == name) {
      i++;
      return true;
    }
    return false;
  }

  bool _consumeSymbol(String sym) {
    final tok = peek();
    if (tok is _TSymbol && tok.v == sym) {
      i++;
      return true;
    }
    return false;
  }
}
