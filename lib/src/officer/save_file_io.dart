import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Desktop & mobile: ask where to save, then write the file.
Future<String?> saveBytes(String fileName, List<int> bytes) async {
  final data = Uint8List.fromList(bytes);
  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Save payroll file',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
    bytes: data, // used on Android / iOS
  );
  if (path == null) return null;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    final target = path.toLowerCase().endsWith('.xlsx') ? path : '$path.xlsx';
    await File(target).writeAsBytes(data, flush: true);
    return target;
  }
  return path;
}
