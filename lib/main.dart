import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const TripSplitApp());

const kBlue = Color(0xFF2F6FED);
const kOrange = Color(0xFFFF8A3D);
const kGroupColors = <Color>[
  Color(0xFF7C4DFF),
  Color(0xFF00A98F),
  Color(0xFFFF8A3D),
  Color(0xFFE91E8C),
  Color(0xFF2F6FED),
];

String money(double v) {
  final r = v.roundToDouble();
  final s = (v - r).abs() < 0.005 ? r.toStringAsFixed(0) : v.toStringAsFixed(2);
  return '₹$s';
}

String newId() => DateTime.now().microsecondsSinceEpoch.toString();

// ---------------------------------------------------------------- models

class Group {
  final String id;
  String name;
  int color;
  Group(this.id, this.name, this.color);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color};
  factory Group.fromJson(Map<String, dynamic> j) =>
      Group(j['id'], j['name'], j['color']);
}

class Member {
  final String id;
  String name;
  String groupId;
  Member(this.id, this.name, this.groupId);
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'groupId': groupId};
  factory Member.fromJson(Map<String, dynamic> j) =>
      Member(j['id'], j['name'], j['groupId']);
}

class Expense {
  final String id;
  String title;
  double amount;
  String paidBy;
  List<String> participants;
  DateTime date;
  Expense(this.id, this.title, this.amount, this.paidBy, this.participants,
      this.date);
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'amount': amount,
        'paidBy': paidBy,
        'participants': participants,
        'date': date.toIso8601String(),
      };
  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        j['id'],
        j['title'],
        (j['amount'] as num).toDouble(),
        j['paidBy'],
        List<String>.from(j['participants']),
        DateTime.parse(j['date']),
      );
}

class Transfer {
  final String from;
  final String to;
  final double amount;
  Transfer(this.from, this.to, this.amount);
}

// ----------------------------------------------------------------- store

class Store extends ChangeNotifier {
  String tripName = 'Goa trip';
  List<Group> groups = [];
  List<Member> members = [];
  List<Expense> expenses = [];
  bool loaded = false;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('data');
    if (raw == null) {
      _seed();
    } else {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        tripName = j['tripName'] ?? 'Trip';
        groups = (j['groups'] as List)
            .map((e) => Group.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        members = (j['members'] as List)
            .map((e) => Member.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        expenses = (j['expenses'] as List)
            .map((e) => Expense.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } catch (_) {
        _seed();
      }
    }
    loaded = true;
    notifyListeners();
  }

  void _seed() {
    groups = [Group('g1', 'My side', 0), Group('g2', 'Anna side', 1)];
    members = [
      Member('m1', 'Me', 'g1'),
      Member('m2', 'Friend 2', 'g1'),
      Member('m3', 'Friend 3', 'g1'),
      Member('m4', 'Anna', 'g2'),
      Member('m5', 'Member 5', 'g2'),
      Member('m6', 'Member 6', 'g2'),
      Member('m7', 'Member 7', 'g2'),
      Member('m8', 'Member 8', 'g2'),
      Member('m9', 'Member 9', 'g2'),
    ];
    expenses = [];
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'data',
        jsonEncode({
          'tripName': tripName,
          'groups': groups.map((e) => e.toJson()).toList(),
          'members': members.map((e) => e.toJson()).toList(),
          'expenses': expenses.map((e) => e.toJson()).toList(),
        }));
  }

  void _changed() {
    notifyListeners();
    _save();
  }

  // lookups
  Group groupOf(String id) =>
      groups.firstWhere((g) => g.id == id, orElse: () => groups.first);
  Member? memberById(String id) {
    for (final m in members) {
      if (m.id == id) return m;
    }
    return null;
  }

  Color colorOfGroup(String groupId) =>
      kGroupColors[groupOf(groupId).color % kGroupColors.length];
  List<Member> membersOf(String groupId) =>
      members.where((m) => m.groupId == groupId).toList();

  // mutations
  void renameTrip(String n) {
    tripName = n;
    _changed();
  }

  void addGroup(String name) {
    groups.add(Group(newId(), name, groups.length % kGroupColors.length));
    _changed();
  }

  void renameGroup(String id, String name) {
    groupOf(id).name = name;
    _changed();
  }

  bool removeGroup(String id) {
    if (groups.length <= 1 || membersOf(id).isNotEmpty) return false;
    groups.removeWhere((g) => g.id == id);
    _changed();
    return true;
  }

  void addMember(String name, String groupId) {
    members.add(Member(newId(), name, groupId));
    _changed();
  }

  void updateMember(String id, String name, String groupId) {
    final m = memberById(id);
    if (m == null) return;
    m.name = name;
    m.groupId = groupId;
    _changed();
  }

  bool removeMember(String id) {
    final used =
        expenses.any((e) => e.paidBy == id || e.participants.contains(id));
    if (used || members.length <= 1) return false;
    members.removeWhere((m) => m.id == id);
    _changed();
    return true;
  }

  void addExpense(Expense e) {
    expenses.add(e);
    _changed();
  }

  void removeExpense(String id) {
    expenses.removeWhere((e) => e.id == id);
    _changed();
  }

  // calculations
  double get total => expenses.fold(0.0, (s, e) => s + e.amount);

  Map<String, double> get nets {
    final n = {for (final m in members) m.id: 0.0};
    for (final e in expenses) {
      if (e.participants.isEmpty) continue;
      final share = e.amount / e.participants.length;
      n[e.paidBy] = (n[e.paidBy] ?? 0) + e.amount;
      for (final p in e.participants) {
        n[p] = (n[p] ?? 0) - share;
      }
    }
    return n;
  }

  Map<String, double> get shares {
    final s = {for (final m in members) m.id: 0.0};
    for (final e in expenses) {
      if (e.participants.isEmpty) continue;
      final share = e.amount / e.participants.length;
      for (final p in e.participants) {
        s[p] = (s[p] ?? 0) + share;
      }
    }
    return s;
  }

  double groupNet(String groupId) {
    final n = nets;
    return membersOf(groupId).fold(0.0, (s, m) => s + (n[m.id] ?? 0));
  }

  double groupShare(String groupId) {
    final sh = shares;
    return membersOf(groupId).fold(0.0, (s, m) => s + (sh[m.id] ?? 0));
  }

  List<Transfer> settlements() {
    final n = nets;
    final debtors = <MapEntry<String, double>>[];
    final creditors = <MapEntry<String, double>>[];
    n.forEach((id, v) {
      if (v < -0.005) debtors.add(MapEntry(id, -v));
      if (v > 0.005) creditors.add(MapEntry(id, v));
    });
    debtors.sort((a, b) => b.value.compareTo(a.value));
    creditors.sort((a, b) => b.value.compareTo(a.value));
    final out = <Transfer>[];
    var i = 0, j = 0;
    var dv = debtors.isEmpty ? 0.0 : debtors[0].value;
    var cv = creditors.isEmpty ? 0.0 : creditors[0].value;
    while (i < debtors.length && j < creditors.length) {
      final x = dv < cv ? dv : cv;
      if (x > 0.005) out.add(Transfer(debtors[i].key, creditors[j].key, x));
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

final store = Store();

// ------------------------------------------------------------------- app

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
        final pages = <Widget>[
          const HomeTab(),
          const GroupsTab(),
          const BalancesTab(),
        ];
        return Scaffold(
          body: SafeArea(child: pages[tab]),
          floatingActionButton: FloatingActionButton(
            backgroundColor: kOrange,
            foregroundColor: Colors.white,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AddExpensePage()),
            ),
            child: const Icon(Icons.add),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Home'),
              NavigationDestination(
                  icon: Icon(Icons.groups_outlined),
                  selectedIcon: Icon(Icons.groups),
                  label: 'Groups'),
              NavigationDestination(
                  icon: Icon(Icons.balance_outlined),
                  selectedIcon: Icon(Icons.balance),
                  label: 'Balances'),
            ],
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------ shared UI

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

IconData iconForTitle(String t) {
  final s = t.toLowerCase();
  bool has(List<String> k) => k.any(s.contains);
  if (has(['food', 'dinner', 'lunch', 'breakfast', 'snack', 'tea', 'coffee'])) {
    return Icons.restaurant;
  }
  if (has(['cab', 'taxi', 'fuel', 'petrol', 'diesel', 'bus', 'train', 'car'])) {
    return Icons.directions_car;
  }
  if (has(['hotel', 'room', 'stay', 'resort'])) return Icons.hotel;
  if (has(['ticket', 'entry', 'ride'])) return Icons.confirmation_number;
  return Icons.receipt_long;
}

Color tintForIndex(int i) =>
    [kOrange, kBlue, const Color(0xFF00A98F), const Color(0xFF7C4DFF)][i % 4];

// ------------------------------------------------------------------ home

class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final me = store.members.isNotEmpty ? store.members.first : null;
    final myNet = me == null ? 0.0 : (store.nets[me.id] ?? 0.0);
    final per =
        store.members.isEmpty ? 0.0 : store.total / store.members.length;
    final w = (MediaQuery.of(context).size.width - 32 - 12) / 2;
    final recent = store.expenses.reversed.toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
      children: [
        GestureDetector(
          onTap: () => textDialog(context, 'Trip name', store.tripName,
              (v) => store.renameTrip(v)),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Trip',
                        style: TextStyle(fontSize: 12, color: Colors.black54)),
                    Text(store.tripName,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const Icon(Icons.edit_outlined, size: 18, color: Colors.black45),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
              color: kBlue, borderRadius: BorderRadius.circular(20)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(myNet >= 0 ? 'You are owed' : 'You owe',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 2),
              Text(money(myNet.abs()),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Row(
                children: [
                  _heroChip('Total spent', money(store.total)),
                  const SizedBox(width: 10),
                  _heroChip('Per head', money(per)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text('Groups',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: store.groups.map((g) => _groupCard(g, w)).toList(),
        ),
        const SizedBox(height: 20),
        const Text('Recent',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (recent.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
                child: Text('No expenses yet. Tap + to add one.',
                    style: TextStyle(color: Colors.black54))),
          ),
        for (var i = 0; i < recent.length; i++) _expenseTile(context, recent[i], i),
      ],
    );
  }

  Widget _heroChip(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.18),
            borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _groupCard(Group g, double width) {
    final color = kGroupColors[g.color % kGroupColors.length];
    final ms = store.membersOf(g.id);
    final net = store.groupNet(g.id);
    return Container(
      width: width,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 26,
            child: Stack(
              children: [
                for (var i = 0; i < ms.length && i < 3; i++)
                  Positioned(
                    left: i * 18.0,
                    child: Container(
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2)),
                      child: Avatar(ms[i].name, color, size: 26),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(g.name,
              style: TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 15, color: color)),
          Text('${ms.length} members',
              style: TextStyle(fontSize: 12, color: color)),
          const SizedBox(height: 6),
          Text('Share ${money(store.groupShare(g.id))}',
              style: TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 16, color: color)),
          Text(
            net >= 0 ? 'Gets back ${money(net)}' : 'Owes ${money(-net)}',
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ),
    );
  }

  Widget _expenseTile(BuildContext context, Expense e, int i) {
    final payer = store.memberById(e.paidBy);
    final tint = tintForIndex(i);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
            color: tint.withOpacity(0.14),
            borderRadius: BorderRadius.circular(12)),
        child: Icon(iconForTitle(e.title), color: tint),
      ),
      title: Text(e.title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
          'Paid by ${payer?.name ?? '?'} · ${e.participants.length} people'),
      trailing: Text(money(e.amount),
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      onLongPress: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete expense'),
            content: Text('Delete "${e.title}"?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Delete')),
            ],
          ),
        );
        if (ok == true) store.removeExpense(e.id);
      },
    );
  }
}

Future<void> textDialog(BuildContext context, String title, String initial,
    void Function(String) onSave) async {
  final c = TextEditingController(text: initial);
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true),
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

// ---------------------------------------------------------------- groups

class GroupsTab extends StatelessWidget {
  const GroupsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Groups and members',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            ),
            TextButton.icon(
              onPressed: () => textDialog(context, 'New group', '',
                  (v) => store.addGroup(v)),
              icon: const Icon(Icons.add),
              label: const Text('Group'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final g in store.groups) _groupBlock(context, g),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () => memberDialog(context),
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('Add member'),
        ),
        const SizedBox(height: 8),
        const Text('Tap a member to edit or move to another group.',
            style: TextStyle(fontSize: 12, color: Colors.black54)),
      ],
    );
  }

  Widget _groupBlock(BuildContext context, Group g) {
    final color = kGroupColors[g.color % kGroupColors.length];
    final ms = store.membersOf(g.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text('${g.name} · ${ms.length}',
                      style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w600,
                          fontSize: 15)),
                ),
                IconButton(
                  icon: Icon(Icons.edit_outlined, color: color, size: 20),
                  onPressed: () => textDialog(context, 'Rename group', g.name,
                      (v) => store.renameGroup(g.id, v)),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: color, size: 20),
                  onPressed: () {
                    final ok = store.removeGroup(g.id);
                    if (!ok) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text(
                              'Move all members out first. Keep at least one group.')));
                    }
                  },
                ),
              ],
            ),
          ),
          for (final m in ms)
            ListTile(
              dense: true,
              leading: Avatar(m.name, color, size: 32),
              title: Text(m.name),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => memberDialog(context, m: m),
            ),
          if (ms.isEmpty)
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('No members', style: TextStyle(color: Colors.black45)),
            ),
        ],
      ),
    );
  }
}

Future<void> memberDialog(BuildContext context, {Member? m}) async {
  final name = TextEditingController(text: m?.name ?? '');
  String gid = m?.groupId ?? store.groups.first.id;
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(m == null ? 'Add member' : 'Edit member'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: gid,
              decoration: const InputDecoration(labelText: 'Group'),
              items: [
                for (final g in store.groups)
                  DropdownMenuItem(value: g.id, child: Text(g.name)),
              ],
              onChanged: (v) => setS(() => gid = v ?? gid),
            ),
          ],
        ),
        actions: [
          if (m != null)
            TextButton(
              onPressed: () {
                final ok = store.removeMember(m.id);
                Navigator.pop(ctx);
                if (!ok) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text(
                          'This member is part of expenses, so it cannot be deleted.')));
                }
              },
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final n = name.text.trim();
              if (n.isEmpty) return;
              if (m == null) {
                store.addMember(n, gid);
              } else {
                store.updateMember(m.id, n, gid);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

// -------------------------------------------------------------- balances

class BalancesTab extends StatelessWidget {
  const BalancesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final transfers = store.settlements();
    final nets = store.nets;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
      children: [
        const Text('Settle up',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        if (transfers.isEmpty)
          const Text('All settled. Nobody owes anything.',
              style: TextStyle(color: Colors.black54)),
        for (final t in transfers)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${store.memberById(t.from)?.name ?? '?'} pays ${store.memberById(t.to)?.name ?? '?'}',
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
          ),
        const SizedBox(height: 18),
        const Text('Member balances',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (final m in store.members)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Avatar(m.name, store.colorOfGroup(m.groupId), size: 38),
            title: Text(m.name),
            subtitle: Text(store.groupOf(m.groupId).name),
            trailing: Text(
              (nets[m.id] ?? 0) >= 0
                  ? '+${money(nets[m.id] ?? 0)}'
                  : '-${money((nets[m.id] ?? 0).abs())}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: (nets[m.id] ?? 0) >= 0
                    ? const Color(0xFF00A98F)
                    : Colors.red,
              ),
            ),
          ),
      ],
    );
  }
}

// ----------------------------------------------------------- add expense

class AddExpensePage extends StatefulWidget {
  const AddExpensePage({super.key});
  @override
  State<AddExpensePage> createState() => _AddExpensePageState();
}

class _AddExpensePageState extends State<AddExpensePage> {
  final title = TextEditingController();
  final amount = TextEditingController();
  String? paidBy;
  int mode = 0; // 0 everyone, 1 by group, 2 custom
  late Set<String> selGroups;
  late Set<String> selMembers;

  @override
  void initState() {
    super.initState();
    paidBy = store.members.isEmpty ? null : store.members.first.id;
    selGroups = store.groups.map((g) => g.id).toSet();
    selMembers = store.members.map((m) => m.id).toSet();
  }

  List<String> get participants {
    switch (mode) {
      case 0:
        return store.members.map((m) => m.id).toList();
      case 1:
        return store.members
            .where((m) => selGroups.contains(m.groupId))
            .map((m) => m.id)
            .toList();
      default:
        return store.members
            .where((m) => selMembers.contains(m.id))
            .map((m) => m.id)
            .toList();
    }
  }

  double get amt => double.tryParse(amount.text.trim()) ?? 0;

  void save() {
    final p = participants;
    String? err;
    if (amt <= 0) {
      err = 'Enter an amount';
    } else if (paidBy == null) {
      err = 'Choose who paid';
    } else if (p.isEmpty) {
      err = 'Choose at least one person to split with';
    }
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final t = title.text.trim().isEmpty ? 'Expense' : title.text.trim();
    store.addExpense(Expense(newId(), t, amt, paidBy!, p, DateTime.now()));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = participants;
    final per = p.isEmpty ? 0.0 : amt / p.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Add expense')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
                prefixText: '₹ ', labelText: 'Amount', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: title,
            decoration: const InputDecoration(
                labelText: 'What for (dinner, cab...)',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: paidBy,
            decoration: const InputDecoration(
                labelText: 'Paid by', border: OutlineInputBorder()),
            items: [
              for (final m in store.members)
                DropdownMenuItem(value: m.id, child: Text(m.name)),
            ],
            onChanged: (v) => setState(() => paidBy = v),
          ),
          const SizedBox(height: 18),
          const Text('Split between',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Everyone')),
              ButtonSegment(value: 1, label: Text('By group')),
              ButtonSegment(value: 2, label: Text('Custom')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => setState(() => mode = s.first),
          ),
          const SizedBox(height: 12),
          if (mode == 1)
            Wrap(
              spacing: 8,
              children: [
                for (final g in store.groups)
                  FilterChip(
                    label: Text('${g.name} (${store.membersOf(g.id).length})'),
                    selected: selGroups.contains(g.id),
                    onSelected: (v) => setState(() {
                      v ? selGroups.add(g.id) : selGroups.remove(g.id);
                    }),
                  ),
              ],
            ),
          if (mode == 2)
            Wrap(
              spacing: 8,
              children: [
                for (final m in store.members)
                  FilterChip(
                    label: Text(m.name),
                    selected: selMembers.contains(m.id),
                    onSelected: (v) => setState(() {
                      v ? selMembers.add(m.id) : selMembers.remove(m.id);
                    }),
                  ),
              ],
            ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: kBlue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${p.length} people · ${money(per)} each',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: kBlue)),
                const SizedBox(height: 6),
                for (final g in store.groups)
                  Builder(builder: (_) {
                    final n = store
                        .membersOf(g.id)
                        .where((m) => p.contains(m.id))
                        .length;
                    if (n == 0) return const SizedBox.shrink();
                    return Text('${g.name}: $n × ${money(per)} = ${money(per * n)}');
                  }),
              ],
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: save,
            child: const Text('Save expense'),
          ),
        ],
      ),
    );
  }
}
