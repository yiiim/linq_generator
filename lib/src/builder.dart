import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'generator.dart';

Builder linqBuilder(BuilderOptions _) => SharedPartBuilder([LinqGenerator(), LinqContextGenerator()], 'linq_generator');
