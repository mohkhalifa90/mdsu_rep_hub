import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Desktop & mobile: ask where to save, then write the file.
Future<String?> saveBytes(String fileName, List<int> bytes, {String extension = 'xlsx', String title = 'Save file'}) async {
  final data = Uint8List.fromList(bytes);
  final path = await FilePicker.platform.saveFile(
    dialogTitle: title,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [extension],
    bytes: data, // used on Android / iOS
  );
  if (path == null) return null;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    final target = path.toLowerCase().endsWith('.$extension') ? path : '$path.$extension';
    await File(target).writeAsBytes(data, flush: true);
    return target;
  }
  return path;
}
