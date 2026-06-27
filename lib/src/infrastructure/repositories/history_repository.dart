import 'package:bshare/src/domain/entities/transfer_record.dart';
import 'package:hive_flutter/hive_flutter.dart';

class HistoryRepository {
  HistoryRepository(this._box);

  final Box<String> _box;

  List<TransferRecord> all() {
    final records = _box.values.map(TransferRecord.decode).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return records;
  }

  Future<void> add(TransferRecord record) =>
      _box.put(record.id, record.encode());

  Future<void> clear() => _box.clear();
}
