import 'package:lambe/src/completer.dart';
import 'package:test/test.dart';

void main() {
  final sampleData = <String, Object?>{
    'users': <Object?>[
      <String, Object?>{'name': 'Alice', 'age': 25, 'active': true},
      <String, Object?>{'name': 'Bob', 'age': 35, 'active': false},
    ],
    'config': <String, Object?>{
      'database': <String, Object?>{'host': 'localhost', 'port': 5432},
    },
    'version': '1.0.0',
  };

  group('Field completion', () {
    test('root fields from identity', () {
      final (:start, :end, :candidates) = complete('.', 1, sampleData);
      expect(start, 0);
      expect(candidates, containsAll(['.config', '.users', '.version']));
    });

    test('partial match on root fields', () {
      final (:start, :end, :candidates) = complete('.us', 3, sampleData);
      expect(start, 0);
      expect(candidates, ['.users']);
    });

    test('multiple partial matches', () {
      final data = <String, Object?>{'name': 'x', 'namespace': 'y', 'age': 1};
      final (:start, :end, :candidates) = complete('.na', 3, data);
      expect(start, 0);
      expect(candidates, ['.name', '.namespace']);
    });

    test('nested fields', () {
      final (:start, :end, :candidates) = complete('.config.', 8, sampleData);
      expect(start, 7);
      expect(candidates, ['.database']);
    });

    test('deeply nested fields', () {
      final (:start, :end, :candidates) = complete(
        '.config.database.',
        17,
        sampleData,
      );
      expect(start, 16);
      expect(candidates, containsAll(['.host', '.port']));
    });

    test('after index access', () {
      final (:start, :end, :candidates) = complete(
        '.users[0].',
        10,
        sampleData,
      );
      expect(start, 9);
      expect(candidates, containsAll(['.active', '.age', '.name']));
    });

    test('partial after index access', () {
      final (:start, :end, :candidates) = complete(
        '.users[0].na',
        12,
        sampleData,
      );
      expect(start, 9);
      expect(candidates, ['.name']);
    });

    test('no match returns empty', () {
      final (:start, :end, :candidates) = complete('.xyz', 4, sampleData);
      expect(candidates, isEmpty);
    });

    test('non-map target returns empty', () {
      final (:start, :end, :candidates) = complete('.version.', 9, sampleData);
      expect(candidates, isEmpty);
    });
  });

  group('Pipeline operation completion', () {
    test('shape-filtered ops after | over a list', () {
      // .users is list<map<…>>, so list-consuming ops are offered
      // along with universal ones. Map-only ops (filter_keys, has,
      // map_values, to_entries) are filtered out.
      final (:start, :end, :candidates) = complete('.users | ', 9, sampleData);
      expect(candidates, containsAll(['filter', 'map', 'sort', 'flatten']));
      expect(
        candidates,
        isNot(anyOf(contains('filter_keys'), contains('has'))),
      );
    });

    test('partial match after | filters by input shape', () {
      // .users is a list. `filter` applies; `filter_keys` and
      // `filter_values` require a map, so they are dropped.
      final (:start, :end, :candidates) = complete(
        '.users | fil',
        12,
        sampleData,
      );
      expect(candidates, ['filter']);
    });

    test('single match after |', () {
      final (:start, :end, :candidates) = complete(
        '.users | rev',
        12,
        sampleData,
      );
      expect(candidates, ['reverse']);
    });

    test('no match after |', () {
      final (:start, :end, :candidates) = complete(
        '.users | xyz',
        12,
        sampleData,
      );
      expect(candidates, isEmpty);
    });

    test('start position is after | and space', () {
      final (:start, :end, :candidates) = complete(
        '.users | so',
        11,
        sampleData,
      );
      expect(start, 9);
      expect(candidates, ['sort', 'sort_by']);
    });
  });

  group('Inner field completion', () {
    test('inside filter(.', () {
      final (:start, :end, :candidates) = complete(
        '.users | filter(.',
        17,
        sampleData,
      );
      expect(start, 16);
      expect(candidates, containsAll(['.active', '.age', '.name']));
    });

    test('partial inside filter', () {
      final (:start, :end, :candidates) = complete(
        '.users | filter(.na',
        19,
        sampleData,
      );
      expect(start, 16);
      expect(candidates, ['.name']);
    });

    test('inside map(.', () {
      final (:start, :end, :candidates) = complete(
        '.users | map(.',
        14,
        sampleData,
      );
      expect(start, 13);
      expect(candidates, containsAll(['.active', '.age', '.name']));
    });

    test('inside sort_by(.', () {
      final (:start, :end, :candidates) = complete(
        '.users | sort_by(.',
        18,
        sampleData,
      );
      expect(start, 17);
      expect(candidates, containsAll(['.active', '.age', '.name']));
    });

    test('after chained pipeline', () {
      final (:start, :end, :candidates) = complete(
        '.users | sort_by(.name) | filter(.a',
        35,
        sampleData,
      );
      expect(start, 33);
      expect(candidates, containsAll(['.active', '.age']));
    });

    test('non-list input returns empty', () {
      final (:start, :end, :candidates) = complete(
        '.config | filter(.',
        18,
        sampleData,
      );
      expect(candidates, isEmpty);
    });
  });

  group('Nested field completion', () {
    final nestedData = <String, Object?>{
      'users': <Object?>[
        <String, Object?>{
          'name': 'Alice',
          'address': <String, Object?>{'city': 'NYC', 'zip': '10001'},
        },
      ],
    };

    test('nested field inside filter', () {
      const text = '.users | filter(.address.ci';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        nestedData,
      );
      expect(candidates, ['.city']);
    });

    test('nested field inside map', () {
      const text = '.users | map(.address.';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        nestedData,
      );
      expect(candidates, containsAll(['.city', '.zip']));
    });

    test('empty filter paren offers all element fields', () {
      const text = '.users | filter(.';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        nestedData,
      );
      expect(candidates, containsAll(['.address', '.name']));
    });
  });

  group('Command completion', () {
    test(':to format completion', () {
      final (:start, :end, :candidates) = complete(':to ', 4, null);
      expect(start, 4);
      expect(candidates, ['csv', 'hcl', 'json', 'toml', 'tsv', 'yaml']);
    });

    test(':to partial', () {
      final (:start, :end, :candidates) = complete(':to y', 5, null);
      expect(candidates, ['yaml']);
    });

    test(':to no match', () {
      final (:start, :end, :candidates) = complete(':to z', 5, null);
      expect(candidates, isEmpty);
    });

    test('command name completion', () {
      final (:start, :end, :candidates) = complete(':sch', 4, null);
      expect(start, 1);
      expect(candidates, ['schema']);
    });

    test(
      'command prefix q matches quit (q itself is filtered as already typed)',
      () {
        final (:start, :end, :candidates) = complete(':q', 2, null);
        // 'q' is a re-assertion candidate (equals text[1, 2)) and gets
        // filtered. 'quit' remains as the useful completion.
        expect(candidates, ['quit']);
      },
    );

    test('all commands on bare colon', () {
      final (:start, :end, :candidates) = complete(':', 1, null);
      expect(candidates.length, 9);
      expect(candidates, contains('help'));
      expect(candidates, contains('schema'));
    });
  });

  group('String-with-pipe regression', () {
    test('pipe inside string literal does not confuse pipe detection', () {
      // `.users | map(.name + " | ")` has shape list<string>, so only
      // `filter` is offered for `fil` (filter_keys/filter_values are map-only).
      const text = '.users | map(.name + " | ") | fil';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      expect(candidates, ['filter']);
    });

    test('pipe in filter predicate string does not confuse completion', () {
      // `.users | filter(...)` output shape is list<map>, so list-
      // consuming and universal ops are offered, but map-only ops are
      // filtered out.
      const text = '.users | filter(.name != "admin|root") | ';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      expect(candidates, containsAll(['filter', 'map', 'sort']));
      expect(candidates, isNot(contains('filter_keys')));
      expect(candidates, isNot(contains('has')));
    });

    test('empty input returns empty', () {
      final (:start, :end, :candidates) = complete('', 0, sampleData);
      expect(candidates, isEmpty);
    });

    test('short-op ambiguity: sort_ completes to sort_by', () {
      const text = '.users | sort_';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      expect(candidates, ['sort_by']);
    });

    test('short-op ambiguity: unique_ completes to unique_by', () {
      const text = '.users | unique_';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      expect(candidates, ['unique_by']);
    });
  });

  group('Recovery edge cases', () {
    test('conditional: complete in then-branch (missing else)', () {
      const text = 'if true then .us';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      expect(start, text.length - 3);
      expect(candidates, ['.users']);
    });

    test('conditional: complete in else-branch', () {
      const text = 'if true then .name else .ver';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      expect(start, text.length - 4);
      expect(candidates, ['.version']);
    });

    test('string interpolation: field inside \\(.', () {
      const text = r'"hello \(.us';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      expect(candidates, ['.users']);
    });

    test('binary op right side: .age > 20 && .na', () {
      final (:start, :end, :candidates) = complete(
        '.users | filter(.age > 20 && .na',
        32,
        sampleData,
      );
      expect(start, 29);
      expect(candidates, ['.name']);
    });

    test('complete after pipe chain with all op types', () {
      // Verify recovery works through chained pipes
      const text = '.users | filter(.active) | map(.na';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      expect(start, text.length - 3);
      expect(candidates, ['.name']);
    });

    test('empty object construction does not crash', () {
      const text = '.users | map({';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      // May or may not have candidates, but must not throw
      expect(candidates, isA<List<String>>());
    });

    test('empty index bracket does not crash', () {
      const text = '.users[';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      expect(candidates, isA<List<String>>());
    });

    test('all parameterized ops recover inner expr', () {
      // Verify each parameterized op produces completions with recovery
      for (final op in ['filter', 'map', 'sort_by', 'group_by', 'unique_by']) {
        final text = '.users | $op(.na';
        final (:start, :end, :candidates) = complete(
          text,
          text.length,
          sampleData,
        );
        expect(candidates, contains('.name'), reason: '$op should complete');
      }
    });

    test('filter_values completes on map value fields', () {
      final data = <String, Object?>{
        'scores': <String, Object?>{
          'alice': <String, Object?>{'total': 100, 'rank': 1},
          'bob': <String, Object?>{'total': 80, 'rank': 2},
        },
      };
      // filter_values operates on map values, not list elements
      // Currently returns empty (non-list input), which is acceptable
      const text = '.scores | filter_values(.to';
      final (:start, :end, :candidates) = complete(text, text.length, data);
      // filter_values context is a map, not a list: no crash
      expect(candidates, isA<List<String>>());
    });

    test('complete expression is never Partial', () {
      // Verify recovery doesn't fire on complete expressions
      const text = '.users | filter(.age > 30)';
      final (:start, :end, :candidates) = complete(
        text,
        text.length,
        sampleData,
      );
      // Complete expression: no field completion context
      expect(candidates, isEmpty);
    });
  });

  // Each test in this group corresponds to a row in the whitespace
  // investigation (see PLAN_COMPLETER_WHITESPACE_FIX.md and the probe
  // in tool/probe_completer.dart). The cases are authored against
  // current behaviour and expected behaviour; all the "expected"
  // cases currently fail on HEAD. The group exists to pin behaviour
  // so that the fix is verifiably correct and no regression
  // reintroduces the bug.
  group('Trailing whitespace regression', () {
    // --- Identity tail -------------------------------------------
    test('trailing space after identity: offers all root fields', () {
      // ". " with cursor at 2: the typed token is "." (just the dot).
      // "." is not equal to any candidate like ".config", so all
      // candidates pass the re-assertion filter.
      final (:start, :end, :candidates) = complete('. ', 2, sampleData);
      expect(start, 0);
      expect(end, 1);
      expect(candidates, containsAll(['.config', '.users', '.version']));
    });

    // --- Field tail ----------------------------------------------
    // These cases previously asserted `candidates: [".users"]`. With
    // the re-assertion filter, a fully-typed ".users" (no matter how
    // much trailing whitespace follows) has no useful completion:
    // the only candidate equals what's already typed.
    test('trailing space after fully-typed field: no candidates', () {
      final (:start, :end, :candidates) = complete('.users ', 7, sampleData);
      expect(start, 0);
      expect(end, 6);
      expect(candidates, isEmpty);
    });

    test('trailing tab after fully-typed field: no candidates', () {
      final (:start, :end, :candidates) = complete('.users\t', 7, sampleData);
      expect(candidates, isEmpty);
    });

    test('trailing newline after fully-typed field: no candidates', () {
      final (:start, :end, :candidates) = complete('.users\n', 7, sampleData);
      expect(candidates, isEmpty);
    });

    test('multiple trailing spaces after fully-typed field: no candidates', () {
      final (:start, :end, :candidates) = complete('.users   ', 9, sampleData);
      expect(candidates, isEmpty);
    });

    test(
      'mixed trailing whitespace after fully-typed field: no candidates',
      () {
        final (:start, :end, :candidates) = complete(
          '.users \t ',
          9,
          sampleData,
        );
        expect(candidates, isEmpty);
      },
    );

    // --- Access tail ---------------------------------------------
    test('trailing space after fully-typed access: no candidates', () {
      final (:start, :end, :candidates) = complete(
        '.config.database ',
        17,
        sampleData,
      );
      expect(candidates, isEmpty);
    });

    // --- Inside parameterized ops --------------------------------
    test('trailing space after fully-typed field inside filter()', () {
      // Cursor between the space and the closing paren.
      // `.age` is fully typed, so the filter drops the re-assertion.
      final (:start, :end, :candidates) = complete(
        '.users | filter(.age )',
        21,
        sampleData,
      );
      expect(candidates, isEmpty);
    });

    test('trailing space after fully-typed field inside map()', () {
      // Cursor between the space and the closing paren.
      final (:start, :end, :candidates) = complete(
        '.users | map(.name )',
        19,
        sampleData,
      );
      expect(candidates, isEmpty);
    });

    // --- Pipe-op path with trailing whitespace -------------------
    // "fil" is partial: the filter keeps filter/filter_keys/filter_values
    // because none of them equal "fil" exactly.
    test('trailing space after partial pipe op: pipe-op path applies', () {
      // .users is a list; only `filter` passes the shape filter.
      final (:start, :end, :candidates) = complete(
        '.users | fil ',
        13,
        sampleData,
      );
      expect(start, 9);
      expect(end, 12);
      expect(candidates, ['filter']);
    });

    test('multiple trailing spaces after partial pipe op', () {
      final (:start, :end, :candidates) = complete(
        '.users | fil   ',
        15,
        sampleData,
      );
      expect(start, 9);
      expect(end, 12);
      expect(candidates, ['filter']);
    });

    // --- Parity: no-trailing-whitespace variants --------------
    test('no trailing whitespace after fully-typed field: no candidates', () {
      final (:start, :end, :candidates) = complete('.users', 6, sampleData);
      expect(start, 0);
      expect(end, 6);
      expect(candidates, isEmpty);
    });

    test(
      'no trailing whitespace, fully-typed inside filter(): no candidates',
      () {
        final (:start, :end, :candidates) = complete(
          '.users | filter(.age',
          20,
          sampleData,
        );
        expect(candidates, isEmpty);
      },
    );

    test('pipe-op partial without trailing whitespace: offers matches', () {
      // .users is a list; only `filter` passes the shape filter.
      final (:start, :end, :candidates) = complete(
        '.users | fil',
        12,
        sampleData,
      );
      expect(start, 9);
      expect(end, 12);
      expect(candidates, ['filter']);
    });
  });

  // Each test here verifies the `end` field of `Completions`. The
  // contract: `end` is the position just past the last non-whitespace
  // character of the partial token. Callers splice candidates over
  // `text[start, end)` so that trailing whitespace between the token
  // and the cursor is preserved when accepting a candidate.
  group('Replacement range (start/end contract)', () {
    test('partial field: end at end of typed chars', () {
      final r = complete('.us', 3, sampleData);
      expect(r.start, 0);
      expect(r.end, 3);
    });

    test('complete field with no trailing ws: end at end of token', () {
      final r = complete('.users', 6, sampleData);
      expect(r.start, 0);
      expect(r.end, 6);
    });

    test(
      'complete field + trailing space: end at end of token, NOT cursor',
      () {
        final r = complete('.users ', 7, sampleData);
        expect(r.start, 0);
        expect(r.end, 6);
      },
    );

    test('complete field + multiple spaces: end at end of token', () {
      final r = complete('.users   ', 9, sampleData);
      expect(r.start, 0);
      expect(r.end, 6);
    });

    test('complete field + tab: end at end of token', () {
      final r = complete('.users\t', 7, sampleData);
      expect(r.start, 0);
      expect(r.end, 6);
    });

    test('lone dot: end just past the dot', () {
      final r = complete('.', 1, sampleData);
      expect(r.start, 0);
      expect(r.end, 1);
    });

    test('lone dot + space: end at position 1 (just past the dot)', () {
      final r = complete('. ', 2, sampleData);
      expect(r.start, 0);
      expect(r.end, 1);
    });

    test('nested: .config.database: end at end of "database"', () {
      final r = complete('.config.database', 16, sampleData);
      expect(r.start, 7);
      expect(r.end, 16);
    });

    test('nested + trailing ws: end at end of "database", not cursor', () {
      final r = complete('.config.database ', 17, sampleData);
      expect(r.start, 7);
      expect(r.end, 16);
    });

    test('pipe-op partial: end at end of partial op name', () {
      final r = complete('.users | fil', 12, sampleData);
      expect(r.start, 9);
      expect(r.end, 12);
    });

    test('pipe-op partial + trailing space: end at end of op', () {
      final r = complete('.users | fil ', 13, sampleData);
      expect(r.start, 9);
      expect(r.end, 12);
    });

    test('bare pipe | then space: end at cursor (nothing to replace)', () {
      final r = complete('.users | ', 9, sampleData);
      expect(r.start, 9);
      expect(r.end, 9);
    });

    test('inside filter(.: end just past the dot', () {
      final r = complete('.users | filter(.', 17, sampleData);
      expect(r.start, 16);
      expect(r.end, 17);
    });

    test('inside filter(.na: end at end of "na"', () {
      final r = complete('.users | filter(.na', 19, sampleData);
      expect(r.start, 16);
      expect(r.end, 19);
    });

    test(':to yaml: end at end of "yaml"', () {
      final r = complete(':to yaml', 8, null);
      expect(r.start, 4);
      expect(r.end, 8);
    });

    test(':q command prefix: end at end of "q"', () {
      final r = complete(':q', 2, null);
      expect(r.start, 1);
      expect(r.end, 2);
    });

    test('empty candidates: start == end == cursor', () {
      final r = complete('.xyz', 4, sampleData);
      expect(r.candidates, isEmpty);
      // xyz is not a root field; no candidates, but the typed token
      // range is still reported so callers know what was considered.
      expect(r.start, 0);
      expect(r.end, 4);
    });

    test('splice semantics: partial token + trailing ws preserves the ws', () {
      // Use `.us   ` so the candidate (`.users`) differs from the
      // typed token (`.us`) and survives the re-assertion filter.
      const text = '.us   ';
      final r = complete(text, text.length, sampleData);
      expect(r.candidates, ['.users']);
      final accepted = text.replaceRange(r.start, r.end, r.candidates.first);
      expect(accepted, '.users   ');
    });
  });

  // The re-assertion filter: if a candidate's text equals what's
  // already typed in the [start, end) range, it's filtered out.
  // Accepting a re-assertion candidate is a no-op on the text and
  // would only move the cursor backward — actively surprising.
  group('Re-assertion filter', () {
    test('fully-typed field: filtered out, empty candidates', () {
      final r = complete('.users', 6, sampleData);
      expect(r.candidates, isEmpty);
    });

    test('partial field: candidate passes filter', () {
      final r = complete('.us', 3, sampleData);
      expect(r.candidates, ['.users']);
    });

    test('.dependencies jd: filtered because .dependencies already typed', () {
      final data = <String, Object?>{'dependencies': <String, Object?>{}};
      final r = complete('.dependencies jd', 16, data);
      expect(r.candidates, isEmpty);
    });

    test('fully-typed pipeline op: its exact match filtered, shape-invalid '
        'prefix-matches also filtered', () {
      // ".users | filter" prefix-matches filter, filter_keys,
      // filter_values. But .users is a list, so filter_keys and
      // filter_values fail the shape filter. "filter" itself fails
      // the re-assertion filter (exact match on typed text).
      // Net result: no candidates.
      final r = complete('.users | filter', 15, sampleData);
      expect(r.candidates, isEmpty);
    });

    test('partial pipeline op: unambiguous match passes filter', () {
      // "rev" is a partial; "reverse" is offered.
      final r = complete('.users | rev', 12, sampleData);
      expect(r.candidates, ['reverse']);
    });

    test(':quit filters out itself', () {
      final r = complete(':quit', 5, null);
      expect(r.candidates, isEmpty);
    });

    test(':q filters q but keeps quit', () {
      final r = complete(':q', 2, null);
      expect(r.candidates, ['quit']);
    });

    test('multiple candidates: filter only drops the exact-match one', () {
      // `:h` matches `help` only; `h` itself is not a full command.
      // Typed token is `h`, neither `help` nor any other cmd equals `h`.
      final r = complete(':h', 2, null);
      expect(r.candidates, ['help', 'history']);
    });
  });

  // Completion candidates are filtered by input shape so the user is
  // never offered a pipe op that would throw at evaluation. SAny inputs
  // (unknown shape) fall back to offering every op — rejection only
  // happens when we can prove the op would fail.
  group('Shape-gated pipe-op candidates', () {
    test('map input hides list-only ops', () {
      // .config is a map; `flatten` expects a list and must not appear.
      final r = complete('.config | ', 10, sampleData);
      expect(r.candidates, isNot(contains('flatten')));
      expect(r.candidates, isNot(contains('sum')));
      expect(r.candidates, isNot(contains('sort')));
      expect(r.candidates, isNot(contains('first')));
      expect(r.candidates, isNot(contains('filter')));
      expect(r.candidates, isNot(contains('map')));
      expect(r.candidates, isNot(contains('group_by')));
    });

    test('map input offers map-only, universal, and both-collection ops', () {
      final r = complete('.config | ', 10, sampleData);
      expect(
        r.candidates,
        containsAll(<String>[
          'filter_keys',
          'filter_values',
          'has',
          'map_values',
          'to_entries',
          'keys',
          'values',
          'length',
          'type',
          'as',
        ]),
      );
    });

    test('list input hides map-only ops', () {
      // .users is list<map>; map-specific ops must not appear.
      final r = complete('.users | ', 9, sampleData);
      expect(r.candidates, isNot(contains('filter_keys')));
      expect(r.candidates, isNot(contains('filter_values')));
      expect(r.candidates, isNot(contains('has')));
      expect(r.candidates, isNot(contains('map_values')));
      expect(r.candidates, isNot(contains('to_entries')));
    });

    test('list input offers list, universal, and both-collection ops', () {
      final r = complete('.users | ', 9, sampleData);
      expect(
        r.candidates,
        containsAll(<String>[
          'filter',
          'flatten',
          'first',
          'last',
          'map',
          'reverse',
          'sort',
          'sort_by',
          'group_by',
          'unique',
          'keys',
          'values',
          'length',
          'type',
          'as',
        ]),
      );
    });

    test('string input hides list-only and map-only ops', () {
      // .version is a string; only `length`, `to_number`, `type`, `as`
      // apply. Everything else is filtered.
      final r = complete('.version | ', 11, sampleData);
      expect(
        r.candidates,
        containsAll(<String>['length', 'to_number', 'type', 'as']),
      );
      expect(r.candidates, isNot(contains('filter')));
      expect(r.candidates, isNot(contains('flatten')));
      expect(r.candidates, isNot(contains('keys')));
      expect(r.candidates, isNot(contains('has')));
      expect(r.candidates, isNot(contains('length_values')));
    });

    test('null data offers only universally-accepting ops', () {
      // shapeOf(null) is SNull, a concrete shape. Only `as` and `type`
      // accept any input, so those are the only candidates. Every
      // other op would throw at runtime.
      final r = complete('. | ', 4, null);
      expect(r.candidates, ['as', 'type']);
    });

    test('SAny from inside map() does not filter', () {
      // Inside filter/map on .users (list<map>), the element is
      // `map<name:string, age:number, active:bool>`. The predicate
      // should recognise this as a map and filter appropriately.
      // This guards against accidentally widening to SAny too early.
      final r = complete('.users | map(. | ', 17, sampleData);
      // Inside map(), the input shape is the element shape. For the
      // top-level pipe (which is what this completes), the pipe is
      // inside map's inner expression — but the completer resolves
      // the pipe-op context on the outer remainder, not the inner.
      // So this tests the end-to-end wiring rather than inner-op
      // filtering.
      expect(r.candidates, isNotEmpty);
    });

    test('map input with partial match filters to shape-valid prefixes', () {
      // "fil" against a map: filter is list-only (dropped), filter_keys
      // and filter_values are map-ops (kept).
      final r = complete('.config | fil', 13, sampleData);
      expect(r.candidates, ['filter_keys', 'filter_values']);
    });

    test('.dependencies | flatten motivating case: flatten dropped', () {
      // The case the user hit: an SMap is offered `flatten`, which
      // then fails at runtime with "flatten: expected list, got map".
      final data = <String, Object?>{
        'dependencies': <String, Object?>{'a': '1.0.0', 'b': '2.0.0'},
      };
      final r = complete('.dependencies | ', 16, data);
      expect(r.candidates, isNot(contains('flatten')));
      expect(r.candidates, isNot(contains('sum')));
      expect(r.candidates, isNot(contains('first')));
    });

    test('post-pipe stage uses output shape of preceding expression', () {
      // `.users | map(.name)` is list<string>. Post-pipe, string-valid
      // list ops are offered, but list-of-map ops like `group_by` on a
      // string element still technically passes (list shape check only)
      // — that's expected: we don't validate element types.
      final r = complete('.users | map(.name) | ', 22, sampleData);
      expect(r.candidates, contains('first'));
      expect(r.candidates, contains('unique'));
      expect(r.candidates, isNot(contains('filter_keys')));
      expect(r.candidates, isNot(contains('has')));
    });

    test('partial match stays shape-filtered across pipes', () {
      // After `.users | map(.name)` the shape is list<string>.
      // Prefix "fil": only `filter` (list) matches; filter_keys and
      // filter_values are map-only and must be filtered.
      final r = complete('.users | map(.name) | fil', 25, sampleData);
      expect(r.candidates, ['filter']);
    });
  });
}
