import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

const _smsChannel = MethodChannel('tripsplit/sms');

void main() => runApp(const TripSplitApp());

const kBlue = Color(0xFF2F6FED);
const kOrange = Color(0xFFFF8A3D);
const kGreen = Color(0xFF00796B);
const kRed = Color(0xFFD32F2F);
const kGroupColors = <Color>[
  Color(0xFF7C4DFF),
  Color(0xFF00A98F),
  Color(0xFFFF8A3D),
  Color(0xFFE91E8C),
  Color(0xFF2F6FED),
];

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

// ---------------------------------------------------------------- helpers

String money(double v) {
  final a = v.abs();
  final r = a.roundToDouble();
  final s = (a - r).abs() < 0.005 ? r.toStringAsFixed(0) : a.toStringAsFixed(2);
  return '₹$s';
}

String fmtNum(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

double r2(double v) => (v * 100).round() / 100;

int _idc = 0;
String newId() => '${DateTime.now().microsecondsSinceEpoch}_${_idc++}';

String fmtDate(DateTime d) => '${d.day} ${_months[d.month - 1]}';

String phoneKey(String s) {
  final d = s.replaceAll(RegExp(r'[^0-9]'), '');
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

void snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

class Cat {
  final IconData icon;
  final Color color;
  const Cat(this.icon, this.color);
}

Cat catOf(String t) {
  final s = t.toLowerCase();
  bool has(List<String> k) => k.any(s.contains);
  if (has(['food', 'dinner', 'lunch', 'breakfast', 'snack', 'tea', 'coffee',
      'biryani', 'restaurant'])) {
    return const Cat(Icons.restaurant, kOrange);
  }
  if (has(['cab', 'taxi', 'fuel', 'petrol', 'diesel', 'bus', 'train', 'car',
      'flight', 'auto'])) {
    return const Cat(Icons.directions_car, kBlue);
  }
  if (has(['hotel', 'room', 'stay', 'resort', 'rent'])) {
    return const Cat(Icons.hotel, Color(0xFF7C4DFF));
  }
  if (has(['ticket', 'entry', 'ride', 'movie'])) {
    return const Cat(Icons.confirmation_number, Color(0xFFE91E8C));
  }
  if (has(['grocer', 'shop', 'market'])) {
    return const Cat(Icons.shopping_bag, kGreen);
  }
  return const Cat(Icons.receipt_long, Color(0xFF607D8B));
}

// ----------------------------------------------------------------- models

enum SplitType { equal, exact, percent, shares }

Map<String, double> _dm(dynamic m) =>
    (m as Map).map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));

/// Turns raw split input into the amount each person owes.
/// equal / shares: input = weights. percent: input = percents. exact: amounts.
Map<String, double> computeOwed(
    double amount, SplitType type, Map<String, double> input) {
  final out = <String, double>{};
  if (input.isEmpty) return out;
  if (type == SplitType.exact) {
    for (final e in input.entries) {
      out[e.key] = r2(e.value);
    }
    return out;
  }
  var totalW = 0.0;
  for (final v in input.values) {
    totalW += v;
  }
  if (totalW <= 0) return out;
  var sum = 0.0;
  String? biggest;
  var bigV = -1.0;
  for (final e in input.entries) {
    final x = r2(amount * e.value / totalW);
    out[e.key] = x;
    sum += x;
    if (e.value > bigV) {
      bigV = e.value;
      biggest = e.key;
    }
  }
  final diff = r2(amount - sum);
  if (diff.abs() >= 0.005 && biggest != null) {
    out[biggest] = r2((out[biggest] ?? 0) + diff);
  }
  return out;
}

class Member {
  final String id;
  String name;
  String phone;
  int people;
  bool isMe;
  Member(this.id, this.name,
      {this.phone = '', this.people = 1, this.isMe = false});
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'people': people,
        'isMe': isMe,
      };
  factory Member.fromJson(Map<String, dynamic> j) => Member(
        j['id'],
        j['name'],
        phone: j['phone'] ?? '',
        people: (j['people'] ?? 1) as int,
        isMe: j['isMe'] ?? false,
      );
}

class Expense {
  final String id;
  String title;
  double amount;
  DateTime date;
  Map<String, double> paid;
  SplitType type;
  Map<String, double> input;
  Map<String, double> owed;
  Expense(this.id, this.title, this.amount, this.date, this.paid, this.type,
      this.input, this.owed);
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'amount': amount,
        'date': date.toIso8601String(),
        'paid': paid,
        'type': type.index,
        'input': input,
        'owed': owed,
      };
  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        j['id'],
        j['title'],
        (j['amount'] as num).toDouble(),
        DateTime.parse(j['date']),
        _dm(j['paid']),
        SplitType.values[(j['type'] ?? 0) as int],
        _dm(j['input']),
        _dm(j['owed']),
      );
}

class Payment {
  final String id;
  String from;
  String to;
  double amount;
  DateTime date;
  Payment(this.id, this.from, this.to, this.amount, this.date);
  Map<String, dynamic> toJson() => {
        'id': id,
        'from': from,
        'to': to,
        'amount': amount,
        'date': date.toIso8601String(),
      };
  factory Payment.fromJson(Map<String, dynamic> j) => Payment(
        j['id'],
        j['from'],
        j['to'],
        (j['amount'] as num).toDouble(),
        DateTime.parse(j['date']),
      );
}

class Transfer {
  final String from;
  final String to;
  final double amount;
  Transfer(this.from, this.to, this.amount);
}

class Group {
  final String id;
  String name;
  int color;
  List<Member> members;
  List<Expense> expenses;
  List<Payment> payments;
  Group(this.id, this.name, this.color, this.members, this.expenses,
      this.payments);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'members': members.map((e) => e.toJson()).toList(),
        'expenses': expenses.map((e) => e.toJson()).toList(),
        'payments': payments.map((e) => e.toJson()).toList(),
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        j['id'],
        j['name'],
        (j['color'] ?? 0) as int,
        (j['members'] as List)
            .map((e) => Member.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        (j['expenses'] as List)
            .map((e) => Expense.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        (j['payments'] as List)
            .map((e) => Payment.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  Member? member(String id) {
    for (final m in members) {
      if (m.id == id) return m;
    }
    return null;
  }

  Member? get me {
    for (final m in members) {
      if (m.isMe) return m;
    }
    return null;
  }

  String nameOf(String id) {
    final m = member(id);
    if (m == null) return '?';
    return m.isMe ? 'You' : m.name;
  }

  int get totalPeople => members.fold(0, (s, m) => s + m.people);

  double get total => expenses.fold(0.0, (s, e) => s + e.amount);

  Map<String, double> paidTotals() {
    final n = <String, double>{for (final m in members) m.id: 0.0};
    for (final e in expenses) {
      for (final x in e.paid.entries) {
        n[x.key] = (n[x.key] ?? 0) + x.value;
      }
    }
    return n;
  }

  Map<String, double> owedTotals() {
    final n = <String, double>{for (final m in members) m.id: 0.0};
    for (final e in expenses) {
      for (final x in e.owed.entries) {
        n[x.key] = (n[x.key] ?? 0) + x.value;
      }
    }
    return n;
  }

  Map<String, double> nets() {
    final n = <String, double>{for (final m in members) m.id: 0.0};
    for (final e in expenses) {
      for (final x in e.paid.entries) {
        n[x.key] = (n[x.key] ?? 0) + x.value;
      }
      for (final x in e.owed.entries) {
        n[x.key] = (n[x.key] ?? 0) - x.value;
      }
    }
    for (final p in payments) {
      n[p.from] = (n[p.from] ?? 0) + p.amount;
      n[p.to] = (n[p.to] ?? 0) - p.amount;
    }
    return n;
  }

  double myNet() {
    final m = me;
    if (m == null) return 0.0;
    return nets()[m.id] ?? 0.0;
  }

  bool involved(String id) {
    for (final e in expenses) {
      if (e.paid.containsKey(id) || e.owed.containsKey(id)) return true;
    }
    for (final p in payments) {
      if (p.from == id || p.to == id) return true;
    }
    return false;
  }

  List<Transfer> settlements() {
    final n = nets();
    final debtors = <MapEntry<String, double>>[];
    final creditors = <MapEntry<String, double>>[];
    for (final x in n.entries) {
      if (x.value < -0.005) debtors.add(MapEntry(x.key, -x.value));
      if (x.value > 0.005) creditors.add(MapEntry(x.key, x.value));
    }
    debtors.sort((a, b) => b.value.compareTo(a.value));
    creditors.sort((a, b) => b.value.compareTo(a.value));
    final out = <Transfer>[];
    var i = 0, j = 0;
    var dv = debtors.isEmpty ? 0.0 : debtors[0].value;
    var cv = creditors.isEmpty ? 0.0 : creditors[0].value;
    while (i < debtors.length && j < creditors.length) {
      final x = dv < cv ? dv : cv;
      if (x > 0.005) out.add(Transfer(debtors[i].key, creditors[j].key, r2(x)));
      dv -= x;
      cv -= x;
      if (dv < 0.005) {
        i++;
        if (i < debtors.length) dv = debtors[i].value;
      }
      if (cv < 0.005) {
        j++;
        if (j < creditors.length) cv = creditors[j].value;
      }
    }
    return out;
  }
}

// ------------------------------------------------------------------ store

class Store extends ChangeNotifier {
  String myName = '';
  bool setupDone = false;
  List<Group> groups = [];
  bool loaded = false;

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/trip_data.json');
  }

  Future<void> load() async {
    try {
      final f = await _file().timeout(const Duration(seconds: 5));
      if (await f.exists()) {
        try {
          applyMap(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
        } catch (_) {
          try {
            await f.copy('${f.path}.bad');
          } catch (_) {}
          _clear();
        }
      }
    } catch (_) {
      _clear();
    }
    loaded = true;
    notifyListeners();
  }

  void _clear() {
    myName = '';
    setupDone = false;
    groups = [];
  }

  Map<String, dynamic> toMap() => {
        'version': 2,
        'myName': myName,
        'setupDone': setupDone,
        'groups': groups.map((g) => g.toJson()).toList(),
      };

  void applyMap(Map<String, dynamic> j) {
    if (j.containsKey('tripName')) {
      _migrateOld(j);
      return;
    }
    final gs = (j['groups'] as List)
        .map((e) => Group.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final name = (j['myName'] ?? '').toString();
    myName = name;
    setupDone = j['setupDone'] ?? name.isNotEmpty;
    groups = gs;
  }

  // Data saved by the first version of the app (single trip).
  void _migrateOld(Map<String, dynamic> j) {
    final olds = (j['members'] as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (olds.isEmpty) {
      _clear();
      return;
    }
    final members = <Member>[];
    for (var i = 0; i < olds.length; i++) {
      final m = olds[i];
      members.add(Member(m['id'], m['name'],
          phone: m['phone'] ?? '',
          people: (m['people'] ?? 1) as int,
          isMe: i == 0));
    }
    final people = <String, int>{for (final m in members) m.id: m.people};
    final exps = <Expense>[];
    for (final e in (j['expenses'] as List)) {
      final em = Map<String, dynamic>.from(e);
      final parts = List<String>.from(em['participants']);
      final amount = (em['amount'] as num).toDouble();
      final input = <String, double>{
        for (final p in parts) p: (people[p] ?? 1).toDouble()
      };
      exps.add(Expense(
        em['id'],
        em['title'],
        amount,
        DateTime.parse(em['date']),
        <String, double>{em['paidBy'] as String: amount},
        SplitType.equal,
        input,
        computeOwed(amount, SplitType.equal, input),
      ));
    }
    final tn = (j['tripName'] ?? '').toString();
    groups = [
      Group(newId(), tn.isEmpty ? 'My trip' : tn, 0, members, exps, [])
    ];
    myName = members.first.name;
    setupDone = true;
  }

  String exportJson() => const JsonEncoder.withIndent('  ').convert(toMap());

  bool importJson(String text) {
    try {
      applyMap(jsonDecode(text) as Map<String, dynamic>);
      changed();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(toMap()));
    } catch (_) {}
  }

  void changed() {
    notifyListeners();
    _save();
  }

  Group? groupById(String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  void addGroup(Group g) {
    groups.add(g);
    changed();
  }

  void deleteGroup(String id) {
    groups.removeWhere((g) => g.id == id);
    changed();
  }

  void finishSetup(String name) {
    myName = name;
    setupDone = true;
    changed();
  }

  void setMyName(String name) {
    myName = name;
    for (final g in groups) {
      final m = g.me;
      if (m != null) m.name = name;
    }
    changed();
  }

  void resetAll() {
    _clear();
    changed();
  }

  double get totalOwedToMe {
    var s = 0.0;
    for (final g in groups) {
      final n = g.myNet();
      if (n > 0.005) s += n;
    }
    return s;
  }

  double get totalIOwe {
    var s = 0.0;
    for (final g in groups) {
      final n = g.myNet();
      if (n < -0.005) s += -n;
    }
    return s;
  }

  double get overall => totalOwedToMe - totalIOwe;
}

final store = Store();

// -------------------------------------------------------------------- app

class TripSplitApp extends StatelessWidget {
  const TripSplitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TripSplit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kBlue),
        scaffoldBackgroundColor: const Color(0xFFF6F8FC),
      ),
      home: const Root(),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    store.load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.loaded) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (!store.setupDone) return const WelcomePage();
        final pages = <Widget>[
          const GroupsTab(),
          const ActivityTab(),
          const AccountTab(),
        ];
        return Scaffold(
          body: SafeArea(child: pages[tab]),
          floatingActionButton: tab == 0
              ? FloatingActionButton.extended(
                  backgroundColor: kOrange,
                  foregroundColor: Colors.white,
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NewGroupPage()),
                  ),
                  icon: const Icon(Icons.group_add),
                  label: const Text('New group'),
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.groups_outlined),
                  selectedIcon: Icon(Icons.groups),
                  label: 'Groups'),
              NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  selectedIcon: Icon(Icons.receipt_long),
                  label: 'Activity'),
              NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: 'Account'),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------- shared widgets

class Avatar extends StatelessWidget {
  final String name;
  final Color color;
  final double size;
  const Avatar(this.name, this.color, {super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final t = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color,
      child: Text(t,
          style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.42,
              fontWeight: FontWeight.w600)),
    );
  }
}

class Panel extends StatelessWidget {
  final Widget child;
  const Panel({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class HeroCard extends StatelessWidget {
  final double net;
  final String owedLabel;
  final String oweLabel;
  final List<String> lines;
  final List<MapEntry<String, String>> stats;
  const HeroCard({
    super.key,
    required this.net,
    required this.owedLabel,
    required this.oweLabel,
    this.lines = const [],
    this.stats = const [],
  });

  @override
  Widget build(BuildContext context) {
    final owe = net < -0.005;
    final settled = net.abs() <= 0.005;
    final fg = owe ? kRed : Colors.white;
    final sub = owe ? Colors.black54 : Colors.white70;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: owe ? const Color(0xFFFDECEC) : kBlue,
          borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(settled ? 'You are all settled up' : (owe ? oweLabel : owedLabel),
              style: TextStyle(color: sub, fontSize: 13)),
          const SizedBox(height: 2),
          Text(
              settled
                  ? '₹0'
                  : (owe ? '-${money(net)}' : '+${money(net)}'),
              style: TextStyle(
                  color: fg, fontSize: 34, fontWeight: FontWeight.w600)),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(l,
                  style: TextStyle(
                      color: fg, fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                for (var i = 0; i < stats.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                          color: owe
                              ? Colors.white
                              : Colors.white.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(12)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(stats[i].key,
                              style: TextStyle(color: sub, fontSize: 11)),
                          Text(stats[i].value,
                              style: TextStyle(
                                  color: owe ? Colors.black87 : Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

Future<bool> confirmDialog(
    BuildContext context, String title, String msg, String action) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(msg),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

Future<void> textDialog(BuildContext context, String title, String initial,
    void Function(String) onSave) async {
  final c = TextEditingController(text: initial);
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final v = c.text.trim();
            if (v.isEmpty) return;
            onSave(v);
            Navigator.pop(ctx);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class MemberDraft {
  final String name;
  final String phone;
  final int people;
  MemberDraft(this.name, this.phone, this.people);
}

Future<MemberDraft?> memberEditor(BuildContext context,
    {Member? m, VoidCallback? onDelete}) {
  final name = TextEditingController(text: m?.name ?? '');
  final phone = TextEditingController(text: m?.phone ?? '');
  final people = TextEditingController(text: '${m?.people ?? 1}');
  return showDialog<MemberDraft>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(m == null ? 'Add member' : 'Edit member'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: m == null,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration:
                  const InputDecoration(labelText: 'Phone number (optional)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: people,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'People covered',
                helperText:
                    '1 = only this person. Use 3 for this person plus 2 family members.',
                helperMaxLines: 3,
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (onDelete != null)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onDelete();
            },
            child: const Text('Delete', style: TextStyle(color: kRed)),
          ),
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final n = name.text.trim();
            if (n.isEmpty) return;
            final pc = int.tryParse(people.text.trim()) ?? 1;
            Navigator.pop(
                ctx, MemberDraft(n, phone.text.trim(), pc < 1 ? 1 : pc));
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- welcome

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});
  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final name = TextEditingController();

  Future<void> start() async {
    final n = name.text.trim();
    if (n.isEmpty) {
      snack(context, 'Enter your name');
      return;
    }
    try {
      await FlutterContacts.requestPermission(readonly: true);
    } catch (_) {}
    store.finishSetup(n);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 40),
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                  color: kBlue, borderRadius: BorderRadius.circular(22)),
              child: const Icon(Icons.groups, color: Colors.white, size: 40),
            ),
            const SizedBox(height: 20),
            const Text('Welcome to TripSplit',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
                'Create groups, add friends and split trip expenses. Contacts access is only used to add people quickly.',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 28),
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Your name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50)),
              onPressed: start,
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- reminders

String waNumber(String phone) {
  var d = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length == 11 && d.startsWith('0')) d = d.substring(1);
  if (d.length == 10) d = '91$d';
  return d;
}

Future<void> sendReminder(BuildContext context, Group g, Transfer t) async {
  final debtor = g.member(t.from);
  if (debtor == null) return;
  if (debtor.phone.trim().isEmpty) {
    snack(context, 'Add ${debtor.name}\'s phone number in Members first');
    return;
  }
  final creditor = g.nameOf(t.to) == 'You' ? store.myName : g.nameOf(t.to);
  final msg =
      'Hi ${debtor.name}, reminder from TripSplit: in "${g.name}" you owe ${money(t.amount)} to $creditor. Please pay when you can.';
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Send reminder to ${debtor.name}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(msg,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.send_to_mobile, color: kBlue),
            title: const Text('Send SMS now'),
            subtitle: const Text('Sent in the background, no app opens'),
            onTap: () => Navigator.pop(ctx, 'direct'),
          ),
          ListTile(
            leading: const Icon(Icons.chat_outlined),
            title: const Text('WhatsApp'),
            subtitle: const Text('Opens WhatsApp, you press send'),
            onTap: () => Navigator.pop(ctx, 'wa'),
          ),
          ListTile(
            leading: const Icon(Icons.sms_outlined),
            title: const Text('SMS app'),
            subtitle: const Text('Opens Messages, you press send'),
            onTap: () => Navigator.pop(ctx, 'sms'),
          ),
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('Copy message'),
            onTap: () => Navigator.pop(ctx, 'copy'),
          ),
        ],
      ),
    ),
  );
  if (choice == null) return;
  final text = Uri.encodeComponent(msg);
  var ok = false;
  try {
    if (choice == 'direct') {
      final n = debtor.phone.replaceAll(RegExp(r'[^0-9+]'), '');
      final sent = await _smsChannel.invokeMethod<bool>(
          'send', {'to': n, 'msg': msg.replaceAll('₹', 'Rs.')});
      if (context.mounted) {
        snack(
            context,
            sent == true
                ? 'SMS sent to ${debtor.name}'
                : 'Could not send. Allow the SMS permission and try again.');
      }
      return;
    } else if (choice == 'wa') {
      ok = await launchUrl(
          Uri.parse('https://wa.me/${waNumber(debtor.phone)}?text=$text'),
          mode: LaunchMode.externalApplication);
    } else if (choice == 'sms') {
      final n = debtor.phone.replaceAll(RegExp(r'[^0-9+]'), '');
      ok = await launchUrl(Uri.parse('sms:$n?body=$text'),
          mode: LaunchMode.externalApplication);
    } else {
      await Clipboard.setData(ClipboardData(text: msg));
      ok = true;
      if (context.mounted) snack(context, 'Message copied');
    }
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) snack(context, 'Could not open the app');
}

// ----------------------------------------------------------- groups tab

class GroupsTab extends StatelessWidget {
  const GroupsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final gs = store.groups;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            const Text('Groups',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
            Text('Hi ${store.myName}',
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 14),
            if (gs.isNotEmpty)
              HeroCard(
                net: store.overall,
                owedLabel: 'Overall, you are owed',
                oweLabel: 'Overall, you owe',
                stats: [
                  MapEntry('You are owed', money(store.totalOwedToMe)),
                  MapEntry('You owe', money(store.totalIOwe)),
                ],
              ),
            if (gs.isNotEmpty) const SizedBox(height: 18),
            if (gs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 60),
                child: Column(
                  children: const [
                    Icon(Icons.card_travel_outlined, size: 56, color: Colors.black38),
                    SizedBox(height: 12),
                    Text('Create your first group',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                    SizedBox(height: 6),
                    Text('Add a trip, add people, split expenses.',
                        style: TextStyle(color: Colors.black54)),
                  ],
                ),
              ),
            for (final g in gs) groupTile(context, g),
          ],
        );
      },
    );
  }
}

Widget groupTile(BuildContext context, Group g) {
  final color = kGroupColors[g.color % kGroupColors.length];
  final net = g.myNet();
  final owe = net < -0.005;
  final settled = net.abs() <= 0.005;
  final shown = g.members.length < 5 ? g.members.length : 5;
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: color.withOpacity(0.35)),
    ),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => GroupPage(g.id))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                    color: color.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(14)),
                child: Icon(Icons.card_travel, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                        '${g.members.length} members · ${g.totalPeople} people · ${money(g.total)} spent',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54)),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 24,
                      width: shown * 16.0 + 10,
                      child: Stack(
                        children: [
                          for (var i = 0; i < shown; i++)
                            Positioned(
                              left: i * 16.0,
                              child: Container(
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 2)),
                                child: Avatar(g.members[i].name, color,
                                    size: 24),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                      settled
                          ? 'settled up'
                          : (owe ? 'you owe' : 'you are owed'),
                      style: TextStyle(
                          fontSize: 11,
                          color: settled
                              ? Colors.black45
                              : (owe ? kRed : kGreen))),
                  if (!settled)
                    Text(money(net),
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: owe ? kRed : kGreen)),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------- new group page

class NewGroupPage extends StatefulWidget {
  const NewGroupPage({super.key});
  @override
  State<NewGroupPage> createState() => _NewGroupPageState();
}

class _NewGroupPageState extends State<NewGroupPage> {
  final name = TextEditingController();
  late List<Member> members;

  @override
  void initState() {
    super.initState();
    members = [Member(newId(), store.myName, isMe: true)];
  }

  Future<void> _add() async {
    final d = await memberEditor(context);
    if (d != null) {
      setState(() => members
          .add(Member(newId(), d.name, phone: d.phone, people: d.people)));
    }
  }

  Future<void> _edit(Member m) async {
    final d = await memberEditor(
      context,
      m: m,
      onDelete: m.isMe ? null : () => setState(() => members.remove(m)),
    );
    if (d != null) {
      setState(() {
        m.name = d.name;
        m.phone = d.phone;
        m.people = d.people;
      });
    }
  }

  Future<void> _contacts() async {
    final res = await pickContacts(context, members);
    if (res != null && res.isNotEmpty) setState(() => members.addAll(res));
  }

  void _create() {
    final n = name.text.trim();
    if (n.isEmpty) {
      snack(context, 'Enter a group name');
      return;
    }
    final g = Group(newId(), n, store.groups.length % kGroupColors.length,
        members, [], []);
    store.addGroup(g);
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => GroupPage(g.id)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'Group name',
                hintText: 'Goa trip',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 18),
          Text('Members (${members.length})',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Panel(
            child: Column(
              children: [
                for (final m in members)
                  ListTile(
                    leading: Avatar(m.name, kBlue, size: 36),
                    title: Text(
                        '${m.isMe ? '${m.name} (you)' : m.name}${m.people > 1 ? ' × ${m.people}' : ''}'),
                    subtitle: m.phone.isEmpty ? null : Text(m.phone),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _edit(m),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _add,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add member'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _contacts,
                  icon: const Icon(Icons.contacts_outlined),
                  label: const Text('Contacts'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
              'Tip: set People covered to 3 on a member who pays for 3 people. Equal splits then count 3 shares for them.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 18),
          FilledButton(
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: _create,
            child: const Text('Create group'),
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- group page

class GroupPage extends StatelessWidget {
  final String gid;
  const GroupPage(this.gid, {super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final g = store.groupById(gid);
          if (g == null) return const Scaffold(body: SizedBox.shrink());
          final color = kGroupColors[g.color % kGroupColors.length];
          return Scaffold(
            appBar: AppBar(
              title: Text(g.name),
              actions: [
                IconButton(
                  tooltip: 'Record a payment',
                  icon: const Icon(Icons.payments_outlined),
                  onPressed: () => settleDialog(context, g),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'rename') {
                      await textDialog(context, 'Rename group', g.name, (n) {
                        g.name = n;
                        store.changed();
                      });
                    } else if (v == 'delete') {
                      final ok = await confirmDialog(
                          context,
                          'Delete group',
                          'Delete "${g.name}" with all its expenses?',
                          'Delete');
                      if (ok && context.mounted) {
                        Navigator.pop(context);
                        store.deleteGroup(g.id);
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename group')),
                    PopupMenuItem(value: 'delete', child: Text('Delete group')),
                  ],
                ),
              ],
              bottom: TabBar(
                indicatorColor: color,
                tabs: const [
                  Tab(text: 'Expenses'),
                  Tab(text: 'Balances'),
                  Tab(text: 'Members'),
                ],
              ),
            ),
            floatingActionButton: FloatingActionButton.extended(
              backgroundColor: kOrange,
              foregroundColor: Colors.white,
              onPressed: () {
                if (g.members.length < 2) {
                  snack(context, 'Add at least 2 members first');
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => AddExpensePage(gid: g.id)),
                );
              },
              icon: const Icon(Icons.add),
              label: const Text('Add expense'),
            ),
            body: TabBarView(
              children: [
                ExpensesView(g),
                BalancesView(g),
                MembersView(g),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Entry {
  final DateTime date;
  final Expense? e;
  final Payment? p;
  _Entry(this.date, this.e, this.p);
}

Widget lentLabel(Group g, Expense e) {
  final me = g.me;
  if (me == null) return const SizedBox.shrink();
  final involved = e.paid.containsKey(me.id) || e.owed.containsKey(me.id);
  if (!involved) {
    return const Text('not involved',
        style: TextStyle(fontSize: 12, color: Colors.black45));
  }
  final lent = (e.paid[me.id] ?? 0) - (e.owed[me.id] ?? 0);
  if (lent.abs() < 0.005) {
    return const Text('settled',
        style: TextStyle(fontSize: 12, color: Colors.black45));
  }
  final c = lent > 0 ? kGreen : kRed;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Text(lent > 0 ? 'you lent' : 'you borrowed',
          style: TextStyle(fontSize: 11, color: c)),
      Text(money(lent),
          style:
              TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c)),
    ],
  );
}

Widget expenseTile(BuildContext context, Group g, Expense e,
    {bool showGroup = false}) {
  final cat = catOf(e.title);
  final payer = e.paid.length == 1
      ? '${g.nameOf(e.paid.keys.first)} paid'
      : '${e.paid.length} people paid';
  final sub =
      '${showGroup ? '${g.name} · ' : ''}${fmtDate(e.date)} · $payer ${money(e.amount)}';
  return ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    leading: Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
          color: cat.color.withOpacity(0.14),
          borderRadius: BorderRadius.circular(12)),
      child: Icon(cat.icon, color: cat.color),
    ),
    title: Text(e.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: lentLabel(g, e),
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddExpensePage(gid: g.id, edit: e)),
    ),
    onLongPress: () async {
      final ok = await confirmDialog(
          context, 'Delete expense', 'Delete "${e.title}"?', 'Delete');
      if (ok) {
        g.expenses.remove(e);
        store.changed();
      }
    },
  );
}

Widget paymentTile(BuildContext context, Group g, Payment p,
    {bool showGroup = false}) {
  return ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    leading: Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
          color: kGreen.withOpacity(0.14),
          borderRadius: BorderRadius.circular(12)),
      child: const Icon(Icons.payments_outlined, color: kGreen),
    ),
    title: Text('${g.nameOf(p.from)} paid ${g.nameOf(p.to)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: Text('${showGroup ? '${g.name} · ' : ''}${fmtDate(p.date)} · Payment'),
    trailing: Text(money(p.amount),
        style: const TextStyle(
            fontSize: 15, fontWeight: FontWeight.w600, color: kGreen)),
    onTap: () async {
      final ok = await confirmDialog(context, 'Delete payment',
          'Remove this payment of ${money(p.amount)}?', 'Delete');
      if (ok) {
        g.payments.remove(p);
        store.changed();
      }
    },
  );
}

class ExpensesView extends StatelessWidget {
  final Group g;
  const ExpensesView(this.g, {super.key});

  @override
  Widget build(BuildContext context) {
    final me = g.me;
    final lines = <String>[];
    if (me != null) {
      for (final t in g.settlements()) {
        if (t.from == me.id) {
          lines.add('Give ${money(t.amount)} to ${g.nameOf(t.to)}');
        } else if (t.to == me.id) {
          lines.add('Get ${money(t.amount)} from ${g.nameOf(t.from)}');
        }
      }
    }
    final entries = <_Entry>[
      for (final e in g.expenses) _Entry(e.date, e, null),
      for (final p in g.payments) _Entry(p.date, null, p),
    ];
    entries.sort((a, b) => b.date.compareTo(a.date));
    final per = g.totalPeople == 0 ? 0.0 : g.total / g.totalPeople;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        HeroCard(
          net: g.myNet(),
          owedLabel: 'You are owed',
          oweLabel: 'You owe',
          lines: lines,
          stats: [
            MapEntry('Total spent', money(g.total)),
            MapEntry('Per person', money(per)),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Text('Expenses',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('${g.expenses.length} items',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
        const SizedBox(height: 8),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: Center(
                child: Text('No expenses yet. Tap Add expense.',
                    style: TextStyle(color: Colors.black54))),
          )
        else
          Panel(
            child: Column(
              children: [
                for (var i = 0; i < entries.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 66),
                  if (entries[i].e != null)
                    expenseTile(context, g, entries[i].e!)
                  else
                    paymentTile(context, g, entries[i].p!),
                ],
              ],
            ),
          ),
        const SizedBox(height: 8),
        const Text('Tap an expense to edit it. Long press to delete.',
            style: TextStyle(fontSize: 12, color: Colors.black45)),
      ],
    );
  }
}

class BalancesView extends StatelessWidget {
  final Group g;
  const BalancesView(this.g, {super.key});

  @override
  Widget build(BuildContext context) {
    final transfers = g.settlements();
    final nets = g.nets();
    final paid = g.paidTotals();
    final owed = g.owedTotals();
    final color = kGroupColors[g.color % kGroupColors.length];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        const Text('Settle up',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (transfers.isEmpty)
          const Panel(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Everyone is settled up.',
                  style: TextStyle(color: Colors.black54)),
            ),
          ),
        for (final t in transfers)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Panel(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${g.nameOf(t.from)} ${g.nameOf(t.from) == 'You' ? 'pay' : 'pays'} ${g.nameOf(t.to)}',
                            maxLines: 2,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        Text(money(t.amount),
                            style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                                color: kBlue)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (g.me != null && t.to == g.me!.id)
                          TextButton.icon(
                            onPressed: () => sendReminder(context, g, t),
                            icon: const Icon(Icons.send, size: 16),
                            label: const Text('Remind'),
                          ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => settleDialog(context, g,
                              from: t.from, to: t.to, amount: t.amount),
                          child: const Text('Settle'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 14),
        const Text('Member balances',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Panel(
          child: Column(
            children: [
              for (final m in g.members)
                Builder(builder: (_) {
                  final n = nets[m.id] ?? 0.0;
                  final up = n > 0.005;
                  final down = n < -0.005;
                  return ListTile(
                    leading: Avatar(m.name, color, size: 38),
                    title: Text(
                        '${m.isMe ? 'You' : m.name}${m.people > 1 ? ' × ${m.people}' : ''}'),
                    subtitle: Text(
                        'Paid ${money(paid[m.id] ?? 0)} · Share ${money(owed[m.id] ?? 0)}'),
                    trailing: Text(
                      up ? '+${money(n)}' : (down ? '-${money(n)}' : '₹0'),
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: up ? kGreen : (down ? kRed : Colors.black54)),
                    ),
                  );
                }),
            ],
          ),
        ),
      ],
    );
  }
}

class MembersView extends StatelessWidget {
  final Group g;
  const MembersView(this.g, {super.key});

  Future<void> _edit(BuildContext context, Member m) async {
    final d = await memberEditor(
      context,
      m: m,
      onDelete: m.isMe
          ? null
          : () {
              if (g.involved(m.id)) {
                snack(context,
                    'This member is part of expenses, so it cannot be deleted.');
              } else {
                g.members.remove(m);
                store.changed();
              }
            },
    );
    if (d != null) {
      m.name = d.name;
      m.phone = d.phone;
      m.people = d.people;
      store.changed();
    }
  }

  Future<void> _add(BuildContext context) async {
    final d = await memberEditor(context);
    if (d != null) {
      g.members.add(Member(newId(), d.name, phone: d.phone, people: d.people));
      store.changed();
    }
  }

  Future<void> _contacts(BuildContext context) async {
    final res = await pickContacts(context, g.members);
    if (res != null && res.isNotEmpty) {
      g.members.addAll(res);
      store.changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = kGroupColors[g.color % kGroupColors.length];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        Row(
          children: [
            const Text('Members',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('${g.members.length} members · ${g.totalPeople} people',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
        const SizedBox(height: 8),
        Panel(
          child: Column(
            children: [
              for (final m in g.members)
                ListTile(
                  leading: Avatar(m.name, color, size: 38),
                  title: Text(
                      '${m.name}${m.people > 1 ? ' × ${m.people}' : ''}'),
                  subtitle: Text(m.phone.isEmpty
                      ? (m.people > 1 ? 'Covers ${m.people} people' : '')
                      : (m.people > 1
                          ? '${m.phone} · covers ${m.people} people'
                          : m.phone)),
                  trailing: m.isMe
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                              color: kBlue.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(10)),
                          child: const Text('You',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: kBlue,
                                  fontWeight: FontWeight.w600)),
                        )
                      : const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _edit(context, m),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => _add(context),
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Add member'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _contacts(context),
                icon: const Icon(Icons.contacts_outlined),
                label: const Text('Contacts'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
            'People covered changes how Equal splits are shared. Past expenses keep their old amounts.',
            style: TextStyle(fontSize: 12, color: Colors.black45)),
      ],
    );
  }
}

Future<void> settleDialog(BuildContext context, Group g,
    {String? from, String? to, double? amount}) async {
  String f = from ?? (g.me?.id ?? g.members.first.id);
  String t = to ??
      g.members
          .firstWhere((m) => m.id != f, orElse: () => g.members.first)
          .id;
  final c = TextEditingController(text: amount == null ? '' : fmtNum(amount));
  String? err;
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('Record a payment'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: f,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Who paid'),
                items: [
                  for (final m in g.members)
                    DropdownMenuItem(
                        value: m.id, child: Text(m.isMe ? 'You' : m.name)),
                ],
                onChanged: (v) => setS(() => f = v ?? f),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: t,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Paid to'),
                items: [
                  for (final m in g.members)
                    DropdownMenuItem(
                        value: m.id, child: Text(m.isMe ? 'You' : m.name)),
                ],
                onChanged: (v) => setS(() => t = v ?? t),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    prefixText: '₹ ', labelText: 'Amount'),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(err!, style: const TextStyle(color: kRed)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final a = r2(double.tryParse(c.text.trim()) ?? 0);
              if (f == t) {
                setS(() => err = 'Choose two different people');
                return;
              }
              if (a <= 0) {
                setS(() => err = 'Enter an amount');
                return;
              }
              g.payments.add(Payment(newId(), f, t, a, DateTime.now()));
              store.changed();
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------ add expense

class AddExpensePage extends StatefulWidget {
  final String gid;
  final Expense? edit;
  const AddExpensePage({super.key, required this.gid, this.edit});
  @override
  State<AddExpensePage> createState() => _AddExpensePageState();
}

class _AddExpensePageState extends State<AddExpensePage> {
  late Group g;
  final title = TextEditingController();
  final amount = TextEditingController();
  DateTime date = DateTime.now();
  bool multi = false;
  String? payer;
  final Map<String, TextEditingController> paidC = {};
  final Map<String, TextEditingController> valC = {};
  SplitType type = SplitType.equal;
  final Set<String> sel = {};

  TextEditingController pc(String id) =>
      paidC.putIfAbsent(id, () => TextEditingController());
  TextEditingController vc(String id) =>
      valC.putIfAbsent(id, () => TextEditingController());

  @override
  void initState() {
    super.initState();
    g = store.groupById(widget.gid)!;
    payer = g.me?.id ?? g.members.first.id;
    sel.addAll(g.members.map((m) => m.id));
    final e = widget.edit;
    if (e != null) {
      title.text = e.title;
      amount.text = fmtNum(e.amount);
      date = e.date;
      type = e.type;
      sel.clear();
      sel.addAll(e.input.keys.where((id) => g.member(id) != null));
      if (e.paid.length > 1) {
        multi = true;
        for (final x in e.paid.entries) {
          pc(x.key).text = fmtNum(x.value);
        }
      } else if (e.paid.length == 1 && g.member(e.paid.keys.first) != null) {
        payer = e.paid.keys.first;
      }
      if (type != SplitType.equal) {
        for (final x in e.input.entries) {
          vc(x.key).text = fmtNum(x.value);
        }
      }
    }
  }

  @override
  void dispose() {
    title.dispose();
    amount.dispose();
    for (final c in paidC.values) {
      c.dispose();
    }
    for (final c in valC.values) {
      c.dispose();
    }
    super.dispose();
  }

  double get amt => r2(double.tryParse(amount.text.trim()) ?? 0);

  void _prefill() {
    final ids = g.members.where((m) => sel.contains(m.id)).toList();
    if (ids.isEmpty) return;
    final w = <String, double>{for (final m in ids) m.id: m.people.toDouble()};
    if (type == SplitType.shares) {
      for (final m in ids) {
        vc(m.id).text = '${m.people}';
      }
    } else if (type == SplitType.percent) {
      final o = computeOwed(100, SplitType.shares, w);
      for (final m in ids) {
        vc(m.id).text = fmtNum(o[m.id] ?? 0);
      }
    } else if (type == SplitType.exact) {
      final o = computeOwed(amt, SplitType.shares, w);
      for (final m in ids) {
        vc(m.id).text = fmtNum(o[m.id] ?? 0);
      }
    }
  }

  Map<String, double> _input() {
    final out = <String, double>{};
    for (final m in g.members) {
      if (!sel.contains(m.id)) continue;
      out[m.id] = type == SplitType.equal
          ? m.people.toDouble()
          : (double.tryParse(vc(m.id).text.trim()) ?? 0);
    }
    return out;
  }

  Map<String, double> _paid() {
    final out = <String, double>{};
    if (!multi) {
      if (payer != null) out[payer!] = amt;
      return out;
    }
    for (final m in g.members) {
      final v = r2(double.tryParse(pc(m.id).text.trim()) ?? 0);
      if (v > 0) out[m.id] = v;
    }
    return out;
  }

  double _sum(Iterable<double> v) {
    var s = 0.0;
    for (final x in v) {
      s += x;
    }
    return s;
  }

  String? _splitIssue(Map<String, double> input) {
    if (input.isEmpty) return 'Choose at least one person to split with';
    final sum = _sum(input.values);
    if (type == SplitType.exact) {
      final d = r2(amt - sum);
      if (d.abs() > 0.01) {
        return d > 0
            ? '${money(d)} left to assign'
            : '${money(d)} over the total';
      }
      return null;
    }
    if (type == SplitType.percent) {
      final d = 100 - sum;
      if (d.abs() > 0.1) {
        return d > 0
            ? '${fmtNum(r2(d))}% left to assign'
            : '${fmtNum(r2(-d))}% over 100';
      }
      return null;
    }
    if (sum <= 0) return 'Shares must be more than 0';
    return null;
  }

  void save() {
    final input = _input();
    final paid = _paid();
    final paidSum = _sum(paid.values);
    String? err;
    if (amt <= 0) {
      err = 'Enter an amount';
    } else if (paid.isEmpty) {
      err = 'Choose who paid';
    } else if ((paidSum - amt).abs() > 0.01) {
      err = 'Paid amounts add up to ${money(paidSum)}, not ${money(amt)}';
    } else {
      err = _splitIssue(input);
    }
    if (err != null) {
      snack(context, err);
      return;
    }
    final t = title.text.trim().isEmpty ? 'Expense' : title.text.trim();
    final owed = computeOwed(amt, type, input);
    final now = DateTime.now();
    final when = DateTime(
        date.year, date.month, date.day, now.hour, now.minute, now.second);
    final e = widget.edit;
    if (e == null) {
      g.expenses.add(Expense(newId(), t, amt, when, paid, type, input, owed));
    } else {
      e.title = t;
      e.amount = amt;
      e.paid = paid;
      e.type = type;
      e.input = input;
      e.owed = owed;
      final sameDay = date.year == e.date.year &&
          date.month == e.date.month &&
          date.day == e.date.day;
      if (!sameDay) e.date = when;
    }
    store.changed();
    Navigator.pop(context);
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => date = d);
  }

  Widget _memberRow(Member m, Map<String, double> owed) {
    final on = sel.contains(m.id);
    final label =
        '${m.isMe ? 'You' : m.name}${type == SplitType.equal && m.people > 1 ? ' × ${m.people}' : ''}';
    Widget trailing;
    if (!on) {
      trailing = const Align(
          alignment: Alignment.centerRight,
          child: Text('—', style: TextStyle(color: Colors.black38)));
    } else if (type == SplitType.equal) {
      trailing = Align(
        alignment: Alignment.centerRight,
        child: Text(money(owed[m.id] ?? 0),
            style: const TextStyle(fontWeight: FontWeight.w600)),
      );
    } else {
      trailing = TextField(
        controller: vc(m.id),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          isDense: true,
          prefixText: type == SplitType.exact ? '₹ ' : null,
          suffixText: type == SplitType.percent ? '%' : null,
          hintText: type == SplitType.shares ? 'shares' : null,
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Checkbox(
            value: on,
            onChanged: (v) => setState(() {
              if (v == true) {
                sel.add(m.id);
              } else {
                sel.remove(m.id);
              }
            }),
          ),
          Avatar(m.name, kBlue, size: 30),
          const SizedBox(width: 10),
          Expanded(
              child:
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          SizedBox(width: 104, child: trailing),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final input = _input();
    final owed = computeOwed(amt, type, input);
    final issue = _splitIssue(input);
    final paidSum = _sum(_paid().values);
    final hint = type == SplitType.equal
        ? 'Split equally. A member who covers more people gets more shares.'
        : (type == SplitType.exact
            ? 'Enter exactly what each person owes.'
            : (type == SplitType.percent
                ? 'Enter each person\'s percentage.'
                : 'Enter shares, for example 2 for double.'));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.edit == null ? 'Add expense' : 'Edit expense'),
        actions: [
          if (widget.edit != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final ok = await confirmDialog(context, 'Delete expense',
                    'Delete "${widget.edit!.title}"?', 'Delete');
                if (ok && context.mounted) {
                  g.expenses.remove(widget.edit);
                  store.changed();
                  Navigator.pop(context);
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
                prefixText: '₹ ',
                labelText: 'Amount',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                labelText: 'What for (dinner, cab...)',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Date', style: TextStyle(color: Colors.black54)),
              const Spacer(),
              TextButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text('${fmtDate(date)} ${date.year}'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            value: multi ? '__multi' : payer,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Paid by', border: OutlineInputBorder()),
            items: [
              for (final m in g.members)
                DropdownMenuItem(
                    value: m.id, child: Text(m.isMe ? 'You' : m.name)),
              const DropdownMenuItem(
                  value: '__multi', child: Text('Multiple people')),
            ],
            onChanged: (v) => setState(() {
              if (v == '__multi') {
                multi = true;
              } else {
                multi = false;
                payer = v;
              }
            }),
          ),
          if (multi) ...[
            const SizedBox(height: 10),
            for (final m in g.members)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Avatar(m.name, kBlue, size: 28),
                    const SizedBox(width: 10),
                    Expanded(child: Text(m.isMe ? 'You' : m.name)),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: pc(m.id),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        textAlign: TextAlign.right,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixText: '₹ ',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Paid ${money(paidSum)} of ${money(amt)}',
                style: TextStyle(
                    fontSize: 12,
                    color: (paidSum - amt).abs() <= 0.01 ? kGreen : kRed),
              ),
            ),
          ],
          const SizedBox(height: 18),
          const Text('Split', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<SplitType>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: SplitType.equal, label: Text('Equal')),
              ButtonSegment(value: SplitType.exact, label: Text('Exact')),
              ButtonSegment(value: SplitType.percent, label: Text('%')),
              ButtonSegment(value: SplitType.shares, label: Text('Shares')),
            ],
            selected: {type},
            onSelectionChanged: (s) => setState(() {
              type = s.first;
              if (type != SplitType.equal) _prefill();
            }),
          ),
          const SizedBox(height: 8),
          Text(hint,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          for (final m in g.members) _memberRow(m, owed),
          if (type != SplitType.equal)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(_prefill),
                child: const Text('Reset to equal'),
              ),
            ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: (issue == null ? kBlue : kRed).withOpacity(0.08),
                borderRadius: BorderRadius.circular(14)),
            child: issue != null
                ? Text(issue,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: kRed))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${input.length} people share ${money(amt)}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, color: kBlue)),
                      const SizedBox(height: 6),
                      for (final m in g.members.where((m) => sel.contains(m.id)))
                        Text(
                            '${m.isMe ? 'You' : m.name}: ${money(owed[m.id] ?? 0)}'),
                    ],
                  ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: save,
            child: Text(widget.edit == null ? 'Save expense' : 'Save changes'),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------- contact picker

Future<List<Member>?> pickContacts(
    BuildContext context, List<Member> current) {
  final existing = current
      .map((m) => phoneKey(m.phone))
      .where((d) => d.isNotEmpty)
      .toSet();
  return Navigator.push<List<Member>>(
    context,
    MaterialPageRoute(builder: (_) => ContactPickerPage(existing: existing)),
  );
}

class ContactPickerPage extends StatefulWidget {
  final Set<String> existing;
  const ContactPickerPage({super.key, required this.existing});
  @override
  State<ContactPickerPage> createState() => _ContactPickerPageState();
}

class _ContactPickerPageState extends State<ContactPickerPage> {
  List<Contact> all = [];
  final Set<String> picked = {};
  String query = '';
  String? error;
  bool busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ok = await FlutterContacts.requestPermission(readonly: true);
      if (!ok) {
        setState(() {
          error =
              'Contacts permission denied. Allow it in phone Settings, Apps, TripSplit, Permissions.';
          busy = false;
        });
        return;
      }
      final list = await FlutterContacts.getContacts(withProperties: true);
      list.sort((a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      setState(() {
        all = list.where((c) => c.phones.isNotEmpty).toList();
        busy = false;
      });
    } catch (_) {
      setState(() {
        error = 'Could not read contacts.';
        busy = false;
      });
    }
  }

  void addPicked() {
    final seen = Set<String>.from(widget.existing);
    final out = <Member>[];
    for (final c in all) {
      if (!picked.contains(c.id)) continue;
      final number = c.phones.first.number;
      final k = phoneKey(number);
      if (k.isNotEmpty && seen.contains(k)) continue;
      seen.add(k);
      out.add(Member(newId(), c.displayName, phone: number));
    }
    Navigator.pop(context, out);
  }

  @override
  Widget build(BuildContext context) {
    final q = query.toLowerCase();
    final shown = all
        .where((c) =>
            q.isEmpty ||
            c.displayName.toLowerCase().contains(q) ||
            c.phones.any((p) => p.number.contains(q)))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Add from contacts')),
      body: busy
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(error!, textAlign: TextAlign.center),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        onChanged: (v) => setState(() => query = v),
                        decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            hintText: 'Search name or number',
                            border: OutlineInputBorder()),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final c = shown[i];
                          final dup =
                              widget.existing.contains(phoneKey(c.phones.first.number));
                          return CheckboxListTile(
                            value: picked.contains(c.id),
                            title: Text(c.displayName),
                            subtitle: Text(dup
                                ? '${c.phones.first.number} · already added'
                                : c.phones.first.number),
                            onChanged: dup
                                ? null
                                : (v) => setState(() {
                                      if (v == true) {
                                        picked.add(c.id);
                                      } else {
                                        picked.remove(c.id);
                                      }
                                    }),
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(50)),
                          onPressed: picked.isEmpty ? null : addPicked,
                          child: Text('Add ${picked.length} members'),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

// ------------------------------------------------------------ activity tab

class _AItem {
  final Group g;
  final Expense? e;
  final Payment? p;
  _AItem(this.g, this.e, this.p);
  DateTime get date => e?.date ?? p!.date;
}

class ActivityTab extends StatelessWidget {
  const ActivityTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final items = <_AItem>[
          for (final g in store.groups) ...[
            for (final e in g.expenses) _AItem(g, e, null),
            for (final p in g.payments) _AItem(g, null, p),
          ],
        ];
        items.sort((a, b) => b.date.compareTo(a.date));
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            const Text('Activity',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 50),
                child: Center(
                    child: Text('No activity yet.',
                        style: TextStyle(color: Colors.black54))),
              )
            else
              Panel(
                child: Column(
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const Divider(height: 1, indent: 66),
                      if (items[i].e != null)
                        expenseTile(context, items[i].g, items[i].e!,
                            showGroup: true)
                      else
                        paymentTile(context, items[i].g, items[i].p!,
                            showGroup: true),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

// ------------------------------------------------------------ account tab

class AccountTab extends StatelessWidget {
  const AccountTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            const Text('Account',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Panel(
              child: Column(
                children: [
                  ListTile(
                    leading: Avatar(store.myName, kBlue, size: 40),
                    title: Text(store.myName),
                    subtitle: const Text('Tap to change your name'),
                    onTap: () => textDialog(context, 'Your name', store.myName,
                        (v) => store.setMyName(v)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Text('Data',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Panel(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.copy_outlined),
                    title: const Text('Copy backup (JSON)'),
                    subtitle:
                        const Text('Paste it in a note or chat to keep it safe'),
                    onTap: () async {
                      await Clipboard.setData(
                          ClipboardData(text: store.exportJson()));
                      if (context.mounted) snack(context, 'Backup copied');
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.restore),
                    title: const Text('Restore from JSON'),
                    subtitle: const Text('Paste a backup to load it'),
                    onTap: () => restoreDialog(context),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.contacts_outlined),
                    title: const Text('Allow contacts access'),
                    onTap: () async {
                      bool ok = false;
                      try {
                        ok = await FlutterContacts.requestPermission(
                            readonly: true);
                      } catch (_) {}
                      if (context.mounted) {
                        snack(
                            context,
                            ok
                                ? 'Contacts access allowed'
                                : 'Contacts access denied. Enable it in phone Settings.');
                      }
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.delete_outline, color: kRed),
                    title: const Text('Delete all data',
                        style: TextStyle(color: kRed)),
                    onTap: () async {
                      final ok = await confirmDialog(
                          context,
                          'Delete all data',
                          'This removes every group and expense from this phone.',
                          'Delete all');
                      if (ok) store.resetAll();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text(
                'Your data is saved on this phone in trip_data.json and is never uploaded.',
                style: TextStyle(fontSize: 12, color: Colors.black45)),
          ],
        );
      },
    );
  }
}

Future<void> restoreDialog(BuildContext context) async {
  final c = TextEditingController();
  String? err;
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('Restore from JSON'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: c,
                maxLines: 8,
                decoration: const InputDecoration(
                    hintText: 'Paste backup JSON here',
                    border: OutlineInputBorder()),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(err!, style: const TextStyle(color: kRed)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (store.importJson(c.text.trim())) {
                Navigator.pop(ctx);
              } else {
                setS(() => err = 'That is not a valid backup.');
              }
            },
            child: const Text('Restore'),
          ),
        ],
      ),
    ),
  );
}
