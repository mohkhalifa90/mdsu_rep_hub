import 'package:flutter/material.dart';

/// Three buttons for how a representative attends a meeting.
class AttendancePicker extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  const AttendancePicker({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      emptySelectionAllowed: true,
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: 'offline', icon: Icon(Icons.meeting_room_outlined), label: Text('In the room')),
        ButtonSegment(value: 'online', icon: Icon(Icons.videocam_outlined), label: Text('Online')),
        ButtonSegment(value: 'absent', icon: Icon(Icons.event_busy_outlined), label: Text('Can\'t')),
      ],
      selected: value == null ? <String>{} : {value!},
      onSelectionChanged: (s) => onChanged(s.isEmpty ? null : s.first),
    );
  }
}
