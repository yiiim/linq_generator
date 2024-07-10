import 'package:analyzer/dart/constant/value.dart';
import 'package:code_builder/code_builder.dart';
import 'package:source_gen/source_gen.dart';

String _escapeRune(int c) {
  if (c < 0x20 || c > 0x7E) {
    return '\\u{${c.toRadixString(16)}}';
  }
  return String.fromCharCode(c);
}

Expression _reviveString(String value) {
  final escaped = StringBuffer();
  value = value.replaceAll('\\', r'\\');
  for (var i = 0; i < value.length; i++) {
    final current = value[i];
    if (current == r'$' && (i == 0 || value[i - 1] != r'\')) {
      escaped.write(r'\$');
    } else if (current == '\n') {
      escaped.write(r'\n');
    } else {
      escaped.write(current);
    }
  }

  final withUnicode = escaped.toString();
  final withUnicodeEcaped = withUnicode.runes.map(_escapeRune).join();
  return literalString(withUnicodeEcaped);
}

Expression _reviveList(List<DartObject> list) => literalConstList(list.map((v) => _reviveAny(v)).toList());
Expression _reviveMap(Map<DartObject?, DartObject?> map) => literalConstMap(map.map((k, v) => MapEntry(_reviveAny(k), _reviveAny(v))));
Expression _reviveAny(DartObject? object) {
  final reader = ConstantReader(object);
  if (reader.isNull) {
    return literalNull;
  }
  if (reader.isList) {
    return _reviveList(reader.listValue);
  }
  if (reader.isMap) {
    return _reviveMap(reader.mapValue);
  }
  if (reader.isLiteral) {
    if (reader.isString) {
      return _reviveString(reader.stringValue);
    } else {
      return literal(reader.literalValue!);
    }
  }
  if (reader.isType) {
    throw 'Reviving Types is not supported but tried to revive $object';
  }
  final revive = reader.revive();
  return _revive(revive);
}

Expression _revive(Revivable invocation) {
  if (invocation.source.fragment.isNotEmpty) {
    final name = invocation.source.fragment;
    final positionalArgs = invocation.positionalArguments.map((a) => _reviveAny(a)).toList();
    final namedArgs = invocation.namedArguments.map((name, a) => MapEntry(name, _reviveAny(a)));
    final clazz = refer(name);
    if (invocation.accessor.isNotEmpty) {
      return clazz.constInstanceNamed(
        invocation.accessor,
        positionalArgs,
        namedArgs,
      );
    }
    return clazz.constInstance(positionalArgs, namedArgs);
  }
  final name = invocation.accessor;
  return refer(name);
}
