import 'package:lambe/lambe.dart';

void main() {
  final data = {
    'users': [
      {'name': 'Alice', 'age': 25, 'active': true},
      {'name': 'Bob', 'age': 35, 'active': true},
      {'name': 'Carol', 'age': 45, 'active': false},
    ],
  };

  // Simple field access
  print(query('.users', data));

  // Chained property access + indexing
  print(query('.users[0].name', data)); // Alice

  // Pipeline: filter and map
  print(query('.users | filter(.age > 30) | map(.name)', data)); // [Bob, Carol]

  // Compound predicate
  print(
    query('.users | filter(.age > 30 && .active) | map(.name)', data),
  ); // [Bob]

  // Aggregation
  print(query('.users | length', data)); // 3

  // Parse JSON string directly
  print(queryJson('.version', '{"version": "1.0.0"}')); // 1.0.0

  // Format conversion: query result as YAML
  final result = query('.users[0]', data);
  print(formatOutput(result, OutputFormat.yaml));

  // Schema inference
  print(inferSchema(data));
}
