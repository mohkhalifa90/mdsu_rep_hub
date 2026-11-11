import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Web: the browser downloads the file.
Future<String?> saveBytes(String fileName, List<int> bytes) async {
  await FilePicker.platform.saveFile(fileName: fileName, bytes: Uint8List.fromList(bytes));
  return fileName;
}
