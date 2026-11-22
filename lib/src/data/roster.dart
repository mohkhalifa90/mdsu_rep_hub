import 'models.dart';

/// A cohort: the students who started a programme in one term, e.g. HT 2025.
class Cohort implements Comparable<Cohort> {
  final String term; // HT | VT
  final int year;
  const Cohort(this.term, this.year);

  static Cohort? parse(String? s) {
    final m = RegExp(r'^(HT|VT)\s?(\d{4})$').firstMatch((s ?? '').trim().toUpperCase());
    return m == null ? null : Cohort(m.group(1)!, int.parse(m.group(2)!));
  }

  String get code => '$term$year';
  String get label => '$term $year';

  /// HT starts in August, VT in January
  DateTime get start => term == 'VT' ? DateTime(year, 1, 1) : DateTime(year, 8, 1);

  int _months(DateTime now) => (now.year - start.year) * 12 + now.month - start.month;

  /// 1 = first year
  int studyYear(DateTime now) => _months(now) ~/ 12 + 1;

  /// 1 = first term
  int termNumber(DateTime now) => _months(now) ~/ 6 + 1;

  Cohort previous() => term == 'HT' ? Cohort('VT', year) : Cohort('HT', year - 1);

  @override
  int compareTo(Cohort o) => start.compareTo(o.start);
  @override
  bool operator ==(Object o) => o is Cohort && o.term == term && o.year == year;
  @override
  int get hashCode => Object.hash(term, year);
}

const intakeLabels = {'HT': 'Autumn (HT)', 'VT': 'Spring (VT)', 'HT_VT': 'Every term (HT & VT)'};
const modeLabels = {'campus': 'Campus', 'distans': 'Distance'};
const cityLabels = {'ESK': 'Eskilstuna', 'VÄS': 'Västerås'};

/// The cohorts that are studying now, newest first – one seat each.
/// Intake every term: one per term of the programme (3.5 years → 7). Once a year: one per year (rounded up).
List<Cohort> activeCohorts(Council c, [DateTime? at]) {
  final now = at ?? DateTime.now();
  final len = c.lengthYears;
  if (c.intake == null || len == null) return const [];
  if (c.intake == 'HT_VT') {
    final out = <Cohort>[];
    var cur = now.month >= 8 ? Cohort('HT', now.year) : Cohort('VT', now.year);
    for (var i = 0; i < (len * 2).ceil(); i++) {
      out.add(cur);
      cur = cur.previous();
    }
    return out;
  }
  final latest = c.intake == 'VT' ? now.year : (now.month >= 8 ? now.year : now.year - 1);
  return [for (var i = 0; i < len.ceil(); i++) Cohort(c.intake!, latest - i)];
}

/// How a council's seats are filled.
class SeatPlan {
  final Council council;
  final List<Cohort> cohorts; // one seat each (programmes)
  final Map<Cohort, List<RosterEntry>> bySeat;
  final List<RosterEntry> finished; // cohort older than the programme – probably graduated
  final List<RosterEntry> unplaced; // no cohort, or a cohort that is not running
  final List<RosterEntry> all;
  final int seats;
  SeatPlan._(this.council, this.cohorts, this.bySeat, this.finished, this.unplaced, this.all, this.seats);

  factory SeatPlan(Council c, List<RosterEntry> roster, [DateTime? at]) {
    final mine = roster.where((r) => r.councilId == c.id).toList();
    final cohorts = c.isProgramme ? activeCohorts(c, at) : <Cohort>[];
    final bySeat = {for (final k in cohorts) k: <RosterEntry>[]};
    final finished = <RosterEntry>[], unplaced = <RosterEntry>[];
    final oldest = cohorts.isEmpty ? null : cohorts.last;
    for (final r in mine) {
      final k = Cohort.parse(r.cohort);
      if (k != null && bySeat.containsKey(k)) {
        bySeat[k]!.add(r);
      } else if (k != null && oldest != null && k.compareTo(oldest) < 0) {
        finished.add(r);
      } else {
        unplaced.add(r);
      }
    }
    final seats = c.seats ?? (cohorts.isNotEmpty ? cohorts.length : (c.isProgramme ? 0 : 1));
    return SeatPlan._(c, cohorts, bySeat, finished, unplaced, mine, seats);
  }

  bool get usesCohorts => cohorts.isNotEmpty;

  /// Seats with at least one representative
  int get filled {
    if (!usesCohorts) return (all.length - finished.length).clamp(0, seats);
    final byCohort = bySeat.values.where((l) => l.isNotEmpty).length;
    // reps without a cohort fill empty seats until the Head of Education places them
    return (byCohort + unplaced.length).clamp(0, seats);
  }

  int get vacant => (seats - filled).clamp(0, seats);

  /// Representatives beyond the normal number of seats (shown in red)
  int get extra => (all.length - finished.length - filled).clamp(0, 999);

  String get summary => '$filled of $seats';
}
