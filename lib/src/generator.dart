import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:linq/linq.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:source_gen/source_gen.dart';
import 'package:code_builder/code_builder.dart' as code;
import 'package:dart_style/dart_style.dart';

bool _isSupportedType(DartType type) {
  return type.isDartCoreString || type.isDartCoreInt || type.isDartCoreDouble || type.isDartCoreBool || type.getDisplayString(withNullability: false) == "DateTime" || type.getDisplayString(withNullability: false) == "List<int>";
}

String _generateDefaultValue(DartType type) {
  if (type.nullabilitySuffix == NullabilitySuffix.question) {
    return "null";
  }
  if (type.isDartCoreString) {
    return "''";
  } else if (type.isDartCoreInt) {
    return "0";
  } else if (type.isDartCoreDouble) {
    return "0.0";
  } else if (type.isDartCoreBool) {
    return "false";
  } else if (type.getDisplayString(withNullability: false) == "DateTime") {
    return "DateTime.now()";
  } else if (type.getDisplayString(withNullability: false) == "List<int>") {
    return "[]";
  }
  throw "Unsupported type ${type.getDisplayString(withNullability: true)}";
}

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

class _Colum {
  const _Colum({
    required this.name,
    required this.field,
    required this.dbType,
    this.codecFactory,
    this.isPrimaryKey = false,
  });
  final String name;
  final FieldElement field;
  final DartType dbType;
  final String? codecFactory;
  final bool isPrimaryKey;
}

class LinqContextGenerator extends GeneratorForAnnotation<LinqContextObject> {
  @override
  generateForAnnotatedElement(Element element, ConstantReader annotation, BuildStep buildStep) {
    final entitys = annotation.peek("entitys")?.listValue ?? [];
    final modelExtension = code.Mixin(
      (builder) {
        builder.name = "_${element.name!}Mixin";
        builder.on = refer("LinqContext");
        for (var element in entitys) {
          builder.methods.add(
            code.Method(
              (field) {
                final typeName = element.toTypeValue()!.getDisplayString(withNullability: false);
                field
                  ..name = "${typeName.substring(0, 1).toLowerCase()}${typeName.substring(1)}"
                  ..type = MethodType.getter
                  ..returns = refer("LinqSet<$typeName>")
                  ..body = refer("entitySet<$typeName>()").code;
              },
            ),
          );
        }
        builder.methods.add(
          code.Method(
            (method) {
              method
                ..name = "modelEntity<T extends LinqModel>"
                ..returns = refer("LinqEntity<T>")
                ..lambda = true
                ..annotations.add(refer("override"))
                ..body = code.Code("""
switch (T) {
${entitys.map((e) => "${e.toTypeValue()!.getDisplayString(withNullability: false)} => ${e.toTypeValue()!.getDisplayString(withNullability: false)}Entity() as LinqEntity<T>,").join("\n")}
_ => throw Exception('Unknown entity type: \$T'),
}
""");
            },
          ),
        );
      },
    );
    var genLibrary = code.Library(
      (builder) {
        builder.body.add(modelExtension);
      },
    );
    return DartFormatter(pageWidth: 10000, languageVersion: Version(3, 10, 0)).format(genLibrary.accept(code.DartEmitter(useNullSafetySyntax: true)).toString());
  }
}

class LinqGenerator extends GeneratorForAnnotation<Linq> {
  @override
  generateForAnnotatedElement(Element element, ConstantReader annotation, BuildStep buildStep) {
    if (element is! ClassElement) throw "Linq only for class ";
    final tableName = annotation.peek("tableName")?.stringValue ?? element.name;
    final convertCamelToUnderscore = annotation.peek("convertCamelToUnderscore")?.boolValue ?? false;
    final modelName = element.name!;
    List<_Colum> colums = [];
    final fields = element.allSupertypes.fold(
      element.fields,
      (previousValue, element) {
        List<FieldElement> fields = List.of(previousValue);
        final annotations = TypeChecker.typeNamed(LinqMember, inPackage: 'linq').annotationsOf(element.element);

        if (annotations.isNotEmpty) {
          for (var item in element.element.fields) {
            if (!previousValue.any((e) => e.displayName == item.displayName)) {
              fields.add(item);
            }
          }
        }
        return fields;
      },
    );
    fields.removeWhere((e) => e.getter == null || e.setter == null);
    for (var item in fields) {
      final columReader = ConstantReader(TypeChecker.typeNamed(LinqColum, inPackage: 'linq').firstAnnotationOf(item));
      final ignore = columReader.peek("ignore")?.boolValue ?? false;
      if (item.isStatic) continue;
      if (ignore) continue;

      var columName = columReader.peek("colum")?.stringValue ?? item.name!;
      if (convertCamelToUnderscore) {
        final buffer = StringBuffer();
        for (var i = 0; i < columName.length; i++) {
          final current = columName[i];
          if (current.toUpperCase() == current) {
            buffer.write("_");
          }
          buffer.write(current.toLowerCase());
        }
        columName = buffer.toString();
      }
      final dbType = columReader.peek("dbType")?.typeValue ?? item.type;
      if (!_isSupportedType(dbType)) {
        throw "Unsupported type ${item.type.getDisplayString(withNullability: true)}";
      }
      final codec = columReader.peek("codec");
      String? codecFactory;
      if (codec != null) {
        codecFactory = _revive(codec.revive()).accept(DartEmitter()).toString();
      }
      final colum = _Colum(
        name: columName,
        field: item,
        dbType: dbType,
        codecFactory: codecFactory,
        isPrimaryKey: columReader.peek("primaryKey")?.boolValue == true,
      );
      colums.add(colum);
    }
    if (!colums.any((element) => element.isPrimaryKey)) {
      throw "Primary key not found";
    }

    final wherePseudoClassExtension = code.Extension(
      (builder) {
        builder.name = "LinqWherePseudoClass${modelName}Extension<T>";
        builder.on = refer("LinqWherePseudoClass<$modelName, T>");
        for (var item in colums) {
          builder.methods.add(
            code.Method(
              (method) {
                method
                  ..name = item.field.name
                  ..type = MethodType.getter
                  ..lambda = true
                  ..returns = refer("LinqWherePropertyField<T, ${item.field.type.getDisplayString(withNullability: true)}>")
                  ..body = code.Code("whereField<${item.field.type.getDisplayString(withNullability: true)}>('${item.field.name}')");
              },
            ),
          );
        }
      },
    );
    final pseudoClassExtension = code.Extension(
      (builder) {
        builder.name = "LinqPseudoClass${modelName}Extension<T>";
        builder.on = refer("LinqPseudoClass<$modelName, T>");
        for (var item in colums) {
          builder.methods.add(
            code.Method(
              (method) {
                method
                  ..name = item.field.name
                  ..type = MethodType.getter
                  ..lambda = true
                  ..returns = refer(item.field.type.getDisplayString(withNullability: true))
                  ..body = code.Code("""
get<${item.field.type.getDisplayString(withNullability: true)}>("${item.field.name}") """
// if(model != null) {
//   return model!.${item.field.name};
// }
// ${() {
//                       if (item.codecFactory != null) {
//                         return "return ${item.codecFactory}.defaultValue;";
//                       }
//                       return "return ${_generateDefaultValue(item.dbType)};";
//                     }()}
// """,
                      );
              },
            ),
          );
          builder.methods.add(
            code.Method(
              (method) {
                method
                  ..name = item.field.name
                  ..type = MethodType.setter
                  ..requiredParameters.add(
                    code.Parameter(
                      (param) {
                        param
                          ..name = "value"
                          ..type = refer(item.field.type.getDisplayString(withNullability: true));
                      },
                    ),
                  )
                  ..body = code.Code("set<${item.field.type.getDisplayString(withNullability: true)}>(\"${item.field.name}\", value);");
              },
            ),
          );
        }
        builder.methods.add(
          code.Method(
            (method) {
              method
                ..name = "select"
                ..returns = refer(modelName);
              final buffer = StringBuffer();
              buffer.write("return $modelName()");
              for (var element in fields) {
                buffer.write("..${element.name} = ${element.name}");
              }
              buffer.write(";");
              method.body = code.Code(buffer.toString());
            },
          ),
        );
      },
    );
    final joinOnPseudoClassExtension = code.Extension(
      (builder) {
        builder.name = "LinqJoinOnPseudoClass${modelName}Extension<T>";
        builder.on = refer("LinqJoinOnPseudoClass<$modelName, T>");
        for (var item in colums) {
          builder.methods.add(
            code.Method(
              (method) {
                method
                  ..name = item.field.name
                  ..type = MethodType.getter
                  ..lambda = true
                  ..returns = refer("JoinOnItem<T, ${item.field.type.getDisplayString(withNullability: true)}>")
                  ..body = code.Code("joinField<${item.field.type.getDisplayString(withNullability: true)}>('${item.field.name}')");
              },
            ),
          );
        }
      },
    );
    final entityClass = code.Class(
      (builder) {
        builder.name = "${modelName}Entity";
        builder.extend = refer("LinqEntity<$modelName>");
//         builder.methods.add(
//           code.Method(
//             (method) {
//               method
//                 ..name = "modelFromResult"
//                 ..returns = refer(modelName)
//                 ..annotations.add(refer("override"))
//                 ..requiredParameters.add(
//                   code.Parameter(
//                     (param) {
//                       param
//                         ..name = "result"
//                         ..type = refer("Map<String, dynamic>");
//                     },
//                   ),
//                 );
//               final buffer = StringBuffer();
//               buffer.write("final model = $modelName(");
//               List<_Colum> remainingFields = List.of(colums);
//               for (ParameterElement item in element.unnamedConstructor?.parameters ?? []) {
//                 final colum = colums.firstWhereOrNull((e) => e.field.name == item.name);
//                 if (colum != null) {
//                   buffer.write(
//                     """
// ${item.name}:
// ${() {
//                       if (colum.codecFactory != null) {
//                         return "${colum.codecFactory}.decode(result['${colum.name}'])";
//                       }
//                       return "result['${colum.name}']${item.type.nullabilitySuffix == NullabilitySuffix.none ? "!" : ""}";
//                     }()}
// ,
// """,
//                   );
//                   remainingFields.remove(colum);
//                 } else if (item.isRequired) {
//                   throw "Colum not found for ${item.name}";
//                 }
//               }
//               buffer.write(");");
//               for (var colum in remainingFields) {
//                 buffer.write("model.${colum.field.name} = result['${colum.name}']${colum.field.type.nullabilitySuffix == NullabilitySuffix.none ? "!" : ""};");
//               }
//               buffer.write("return model;");
//               method.body = code.Code(buffer.toString());
//             },
//           ),
//         );
//         builder.methods.add(
//           code.Method(
//             (method) {
//               method
//                 ..name = "toDbDataMap"
//                 ..returns = refer("Map<String, dynamic>")
//                 ..annotations.add(refer("override"))
//                 ..requiredParameters.add(
//                   code.Parameter(
//                     (param) {
//                       param
//                         ..name = "model"
//                         ..type = refer(modelName);
//                     },
//                   ),
//                 )
//                 ..body = code.Code("return {${colums.map((e) => """
// '${e.name}':
// ${() {
//                       if (e.codecFactory != null) {
//                         return "${e.codecFactory}.encode(model.${e.field.name})";
//                       }
//                       return "model.${e.field.name}";
//                     }()}
// """).join(",")}};");
//             },
//           ),
//         );
        builder.methods.add(
          code.Method(
            (method) {
              method
                ..name = "create"
                ..returns = refer(modelName)
                ..annotations.add(refer("override"))
                ..lambda = true
                ..body = code.Code(
                  "$modelName()",
                );
            },
          ),
        );
        builder.methods.add(
          code.Method(
            (method) {
              method
                ..name = "fields"
                ..returns = refer("List<QueryModelFieldDescriptor>")
                ..annotations.add(refer("override"))
                ..lambda = true
                ..body = code.Code(
                  """[${colums.map((e) => """QueryModelFieldDescriptor<$modelName, ${e.field.type.getDisplayString(withNullability: true)}>(
                      name:"${e.field.name}",
                      dbName: "${e.name}",
                      defaultValue: ${() {
                        if (e.codecFactory != null) {
                          return "${e.codecFactory}.defaultValue";
                        }
                        return _generateDefaultValue(e.dbType);
                      }()},
                      isPrimaryKey: ${e.isPrimaryKey ? 'true' : 'false'},
                      get: (model) => model.${e.field.name},
                      set: (model, value) => model.${e.field.name} = value,
                      codec: ${e.codecFactory != null ? "${e.codecFactory}" : "null"}
                    )""").join(",")}]""",
                );
            },
          ),
        );
        builder.methods.add(
          code.Method(
            (method) {
              method
                ..name = "tableName"
                ..annotations.add(refer("override"))
                ..returns = refer("String")
                ..lambda = true
                ..body = code.Code("'$tableName'");
            },
          ),
        );
      },
    );
    // final modelExtension = code.Extension(
    //   (builder) {
    //     builder.name = "Linq${modelName}Extension";
    //     builder.on = refer(modelName);
    //     builder.methods.add(
    //       code.Method(
    //         (method) {
    //           method
    //             ..name = "update"
    //             ..returns = refer("void")
    //             ..requiredParameters.add(
    //               code.Parameter(
    //                 (param) {
    //                   param
    //                     ..name = "block"
    //                     ..type = refer("void Function(LinqPseudoClass<$modelName> model)");
    //                 },
    //               ),
    //             )
    //             ..lambda = true
    //             ..body = code.Code("LinqContext.update<$modelName>(this, block)");
    //         },
    //       ),
    //     );
    //   },
    // );
    final modelExtension = code.Extension(
      (builder) {
        builder.name = "Linq${modelName}Extension<T>";
        builder.on = refer(modelName);
        builder.methods.add(
          code.Method(
            (method) {
              method
                ..name = "update"
                ..returns = refer("void")
                ..requiredParameters.add(
                  code.Parameter(
                    (param) {
                      param
                        ..name = "block"
                        ..type = refer("void Function(LinqPseudoClass<$modelName, $modelName> model)");
                    },
                  ),
                )
                ..lambda = true
                ..body = code.Code("(linqObject as LinqObject<$modelName>).update(block)");
            },
          ),
        );
      },
    );
    var library = code.Library(
      (builder) {
        // builder.body.add(pseudoClass);
        builder.body.add(modelExtension);
        builder.body.add(joinOnPseudoClassExtension);
        builder.body.add(entityClass);
        builder.body.add(pseudoClassExtension);
        builder.body.add(wherePseudoClassExtension);
      },
    );
    return DartFormatter(pageWidth: 10000, languageVersion: Version(3, 10, 0)).format(library.accept(code.DartEmitter(useNullSafetySyntax: true)).toString());
  }
}
