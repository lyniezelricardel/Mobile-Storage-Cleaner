import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/data_models.dart';

/// Snapshot of everything persisted between app launches.
class ScanSnapshot {
  final List<PhotoModel> photos;
  final List<DuplicateGroup> groups;
  final DateTime? lastScanAt;

  const ScanSnapshot({
    required this.photos,
    required this.groups,
    this.lastScanAt,
  });
}

/// SQLite-backed cache for scan results.
///
/// Photos and their hashes are written as each batch completes, so an
/// interrupted scan keeps its progress and never needs to decode those
/// photos again.
class ScanStore {
  static const _databaseName = 'photo_cleaner.db';
  static const _databaseVersion = 2;

  Database? _database;

  Future<Database> get _db async {
    final existing = _database;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, _databaseName),
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    _database = db;
    return db;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE photos (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        thumbnail_path TEXT,
        file_size INTEGER NOT NULL,
        blur_score REAL NOT NULL,
        is_blurry INTEGER NOT NULL,
        date_taken INTEGER NOT NULL,
        modified_at INTEGER NOT NULL,
        mime_type TEXT NOT NULL,
        perceptual_hash TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE duplicate_groups (
        group_id TEXT PRIMARY KEY,
        is_exact INTEGER NOT NULL,
        similarity REAL NOT NULL,
        position INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE group_members (
        photo_id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        position INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_group_members_group ON group_members(group_id)',
    );
    await db.execute('''
      CREATE TABLE meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await _createTrashTable(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createTrashTable(db);
    }
  }

  Future<void> _createTrashTable(Database db) async {
    await db.execute('''
      CREATE TABLE trashed_photos (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        date_taken INTEGER NOT NULL,
        mime_type TEXT NOT NULL,
        type_int INTEGER NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        trashed_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        thumbnail BLOB
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_trashed_photos_expires ON trashed_photos(expires_at)',
    );
  }

  Future<ScanSnapshot> loadSnapshot() async {
    final db = await _db;
    final photoRows = await db.query('photos', orderBy: 'date_taken DESC');
    final photos = photoRows.map(_photoFromRow).toList(growable: false);
    final photoById = {for (final photo in photos) photo.id: photo};

    final groupRows = await db.query('duplicate_groups', orderBy: 'position');
    final memberRows = await db.query(
      'group_members',
      orderBy: 'group_id, position',
    );
    final membersByGroup = <String, List<PhotoModel>>{};
    for (final row in memberRows) {
      final photo = photoById[row['photo_id'] as String];
      if (photo == null) continue;
      membersByGroup
          .putIfAbsent(row['group_id'] as String, () => [])
          .add(photo);
    }

    final groups = <DuplicateGroup>[];
    for (final row in groupRows) {
      final groupId = row['group_id'] as String;
      final members = membersByGroup[groupId];
      if (members == null || members.length < 2) continue;
      groups.add(
        DuplicateGroup(
          groupId: groupId,
          photos: members,
          isExactDuplicate: (row['is_exact'] as int) == 1,
          similarityScore: (row['similarity'] as num).toDouble(),
        ),
      );
    }

    final lastScan = await readMeta('last_scan_at');
    return ScanSnapshot(
      photos: photos,
      groups: groups,
      lastScanAt: lastScan == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(int.parse(lastScan)),
    );
  }

  Future<void> upsertPhotos(Iterable<PhotoModel> photos) async {
    if (photos.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final photo in photos) {
      batch.insert(
        'photos',
        _photoToRow(photo),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deletePhotos(Iterable<String> ids) async {
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final id in idList) {
      batch.delete('photos', where: 'id = ?', whereArgs: [id]);
      batch.delete('group_members', where: 'photo_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  Future<List<TrashedPhoto>> loadTrashedPhotos() async {
    final db = await _db;
    final rows = await db.query('trashed_photos', orderBy: 'trashed_at DESC');
    return rows.map(_trashedPhotoFromRow).toList(growable: false);
  }

  Future<void> upsertTrashedPhotos(Iterable<TrashedPhoto> photos) async {
    if (photos.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final photo in photos) {
      batch.insert(
        'trashed_photos',
        _trashedPhotoToRow(photo),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteTrashedPhotos(Iterable<String> ids) async {
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final id in idList) {
      batch.delete('trashed_photos', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> replaceGroups(List<DuplicateGroup> groups) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('group_members');
      await txn.delete('duplicate_groups');
      if (groups.isEmpty) return;

      final batch = txn.batch();
      for (var i = 0; i < groups.length; i++) {
        final group = groups[i];
        batch.insert('duplicate_groups', {
          'group_id': group.groupId,
          'is_exact': group.isExactDuplicate ? 1 : 0,
          'similarity': group.similarityScore,
          'position': i,
        });
        for (var j = 0; j < group.photos.length; j++) {
          batch.insert('group_members', {
            'photo_id': group.photos[j].id,
            'group_id': group.groupId,
            'position': j,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await batch.commit(noResult: true);
    });
  }

  Future<String?> readMeta(String key) async {
    final db = await _db;
    final rows = await db.query(
      'meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  Future<void> writeMeta(String key, String value) async {
    final db = await _db;
    await db.insert('meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clear() async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('group_members');
      await txn.delete('duplicate_groups');
      await txn.delete('photos');
      await txn.delete('meta');
    });
  }

  Map<String, Object?> _trashedPhotoToRow(TrashedPhoto photo) {
    return {
      'id': photo.id,
      'path': photo.path,
      'file_size': photo.fileSize,
      'date_taken': photo.dateTaken.millisecondsSinceEpoch,
      'mime_type': photo.mimeType,
      'type_int': photo.typeInt,
      'width': photo.width,
      'height': photo.height,
      'trashed_at': photo.trashedAt.millisecondsSinceEpoch,
      'expires_at': photo.expiresAt.millisecondsSinceEpoch,
      'thumbnail': photo.thumbnail,
    };
  }

  TrashedPhoto _trashedPhotoFromRow(Map<String, Object?> row) {
    return TrashedPhoto(
      id: row['id'] as String,
      path: row['path'] as String,
      fileSize: row['file_size'] as int,
      dateTaken: DateTime.fromMillisecondsSinceEpoch(row['date_taken'] as int),
      mimeType: row['mime_type'] as String,
      typeInt: row['type_int'] as int,
      width: row['width'] as int,
      height: row['height'] as int,
      trashedAt: DateTime.fromMillisecondsSinceEpoch(row['trashed_at'] as int),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int),
      thumbnail: row['thumbnail'] as Uint8List?,
    );
  }

  Map<String, Object?> _photoToRow(PhotoModel photo) {
    return {
      'id': photo.id,
      'path': photo.path,
      'thumbnail_path': photo.thumbnailPath,
      'file_size': photo.fileSize,
      'blur_score': photo.blurScore,
      'is_blurry': photo.isBlurry ? 1 : 0,
      'date_taken': photo.dateTaken.millisecondsSinceEpoch,
      'modified_at': photo.modifiedAt.millisecondsSinceEpoch,
      'mime_type': photo.mimeType,
      'perceptual_hash': photo.perceptualHash,
    };
  }

  PhotoModel _photoFromRow(Map<String, Object?> row) {
    return PhotoModel(
      id: row['id'] as String,
      path: row['path'] as String,
      thumbnailPath: row['thumbnail_path'] as String?,
      fileSize: row['file_size'] as int,
      blurScore: (row['blur_score'] as num).toDouble(),
      isBlurry: (row['is_blurry'] as int) == 1,
      dateTaken: DateTime.fromMillisecondsSinceEpoch(row['date_taken'] as int),
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        row['modified_at'] as int,
      ),
      mimeType: row['mime_type'] as String,
      perceptualHash: row['perceptual_hash'] as String,
    );
  }
}
