import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_storage_cleaner/models/data_models.dart';
import 'package:mobile_storage_cleaner/services/duplicate_detector.dart';

PhotoModel _photo({
  required String id,
  int fileSize = 0,
  double blurScore = 500,
  bool isSelected = false,
  DateTime? dateTaken,
  String perceptualHash = '',
}) {
  return PhotoModel(
    id: id,
    path: '/photos/$id.jpg',
    fileSize: fileSize,
    blurScore: blurScore,
    isBlurry: false,
    isSelected: isSelected,
    dateTaken: dateTaken ?? DateTime(2026, 1, 1),
    mimeType: 'image/jpeg',
    perceptualHash: perceptualHash,
  );
}

void main() {
  group('PhotoModel', () {
    test('sizeString formats bytes, kilobytes and megabytes', () {
      expect(_photo(id: 'a', fileSize: 512).sizeString, '512 B');
      expect(_photo(id: 'b', fileSize: 2048).sizeString, '2.0 KB');
      expect(_photo(id: 'c', fileSize: 5 * 1024 * 1024).sizeString, '5.0 MB');
    });

    test('totalSelectedSize only counts selected photos', () {
      final photos = [
        _photo(id: 'a', fileSize: 100, isSelected: true),
        _photo(id: 'b', fileSize: 200),
        _photo(id: 'c', fileSize: 300, isSelected: true),
      ];

      expect(PhotoModel.totalSelectedSize(photos), 400);
    });
  });

  group('DuplicateGroup', () {
    test('savableSize excludes the largest photo', () {
      final group = DuplicateGroup(
        groupId: 'g1',
        photos: [
          _photo(id: 'small', fileSize: 100),
          _photo(id: 'large', fileSize: 500),
          _photo(id: 'medium', fileSize: 300),
        ],
      );

      expect(group.savableSize, 400);
    });

    test('selectedCount reflects photo selection state', () {
      final group = DuplicateGroup(
        groupId: 'g2',
        photos: [
          _photo(id: 'a', isSelected: true),
          _photo(id: 'b', isSelected: true),
          _photo(id: 'c'),
        ],
      );

      expect(group.selectedCount, 2);
    });
  });

  group('StorageInfo', () {
    test('usedPercent and freePercent are calculated from totals', () {
      final info = StorageInfo(
        totalBytes: 1000,
        usedBytes: 750,
        freeBytes: 250,
        photosBytes: 300,
        videosBytes: 200,
        appsBytes: 150,
        othersBytes: 100,
      );

      expect(info.usedPercent, 75);
      expect(info.freePercent, 25);
    });

    test('percentages are zero when total is zero', () {
      final info = StorageInfo(
        totalBytes: 0,
        usedBytes: 0,
        freeBytes: 0,
        photosBytes: 0,
        videosBytes: 0,
        appsBytes: 0,
        othersBytes: 0,
      );

      expect(info.usedPercent, 0);
      expect(info.freePercent, 0);
    });
  });

  group('TrashedPhoto', () {
    test('exposes file name, size and expiry labels', () {
      final now = DateTime.now();
      final photo = TrashedPhoto(
        id: 'trash-1',
        path: r'C:\photos\holiday.jpg',
        fileSize: 2 * 1024 * 1024,
        dateTaken: DateTime(2026, 1, 1),
        mimeType: 'image/jpeg',
        trashedAt: now,
        expiresAt: now.add(const Duration(days: 5, hours: 1)),
      );

      expect(photo.fileName, 'holiday.jpg');
      expect(photo.sizeString, '2.0 MB');
      expect(photo.daysLeft, 5);
      expect(photo.expiryLabel, 'Expires in 5 days');
    });

    test('uses a singular label for the final day', () {
      final now = DateTime.now();
      final photo = TrashedPhoto(
        id: 'trash-2',
        path: '/photos/one.png',
        fileSize: 512,
        dateTaken: DateTime(2026, 1, 1),
        mimeType: 'image/png',
        trashedAt: now,
        expiresAt: now.add(const Duration(days: 1, hours: 1)),
      );

      expect(photo.daysLeft, 1);
      expect(photo.expiryLabel, 'Expires in 1 day');
    });

    test('reports an empty file name fallback', () {
      final now = DateTime.now();
      final photo = TrashedPhoto(
        id: 'trash-3',
        path: '',
        fileSize: 0,
        dateTaken: now,
        mimeType: 'image/jpeg',
        trashedAt: now,
        expiresAt: now.add(const Duration(days: 2)),
      );

      expect(photo.fileName, 'Photo');
      expect(photo.sizeString, '0 B');
    });
  });

  group('TrashResult, RestoreResult and PermanentDeleteResult', () {
    test('trashedBytes sums the photos that moved', () {
      final now = DateTime.now();
      final result = TrashResult(
        requestedCount: 3,
        trashedCount: 2,
        trashedPhotos: [
          TrashedPhoto(
            id: 'a',
            path: '/photos/a.jpg',
            fileSize: 100,
            dateTaken: now,
            mimeType: 'image/jpeg',
            trashedAt: now,
            expiresAt: now.add(const Duration(days: 30)),
          ),
          TrashedPhoto(
            id: 'b',
            path: '/photos/b.jpg',
            fileSize: 250,
            dateTaken: now,
            mimeType: 'image/jpeg',
            trashedAt: now,
            expiresAt: now.add(const Duration(days: 30)),
          ),
        ],
      );

      expect(result.trashedBytes, 350);
      expect(result.success, isTrue);
      expect(result.partial, isTrue);
    });

    test('restore result tracks cancel, failure and partial states', () {
      expect(const RestoreResult().success, isFalse);
      expect(const RestoreResult(canceled: true).success, isFalse);
      expect(
        const RestoreResult(requestedCount: 2, restoredCount: 1).partial,
        isTrue,
      );
      expect(
        const RestoreResult(requestedCount: 1, restoredCount: 1).success,
        isTrue,
      );
    });

    test('permanent delete result sums bytes and tracks outcomes', () {
      final now = DateTime.now();
      final photos = [
        TrashedPhoto(
          id: 'a',
          path: '/photos/a.jpg',
          fileSize: 100,
          dateTaken: now,
          mimeType: 'image/jpeg',
          trashedAt: now,
          expiresAt: now.add(const Duration(days: 30)),
        ),
        TrashedPhoto(
          id: 'b',
          path: '/photos/b.jpg',
          fileSize: 250,
          dateTaken: now,
          mimeType: 'image/jpeg',
          trashedAt: now,
          expiresAt: now.add(const Duration(days: 30)),
        ),
      ];
      final result = PermanentDeleteResult(
        requestedCount: 3,
        deletedPhotos: photos,
      );

      expect(result.deletedCount, 2);
      expect(result.deletedBytes, 350);
      expect(result.success, isTrue);
      expect(result.partial, isTrue);
      expect(const PermanentDeleteResult(canceled: true).success, isFalse);
    });
  });

  group('DuplicateGroup', () {
    test('bestPhoto is the largest file regardless of list position', () {
      final group = DuplicateGroup(
        groupId: 'g1',
        photos: [
          _photo(id: 'small', fileSize: 100),
          _photo(id: 'best', fileSize: 900),
          _photo(id: 'medium', fileSize: 400),
        ],
      );

      expect(group.bestPhoto.id, 'best');
      expect(group.photosBestFirst.map((photo) => photo.id), [
        'best',
        'small',
        'medium',
      ]);
    });

    test('bestPhoto breaks size ties by sharpness, then date', () {
      final sharper = DuplicateGroup(
        groupId: 'g2',
        photos: [
          _photo(id: 'soft', fileSize: 500, blurScore: 120),
          _photo(id: 'sharp', fileSize: 500, blurScore: 800),
        ],
      );
      expect(sharper.bestPhoto.id, 'sharp');

      final newer = DuplicateGroup(
        groupId: 'g3',
        photos: [
          _photo(
            id: 'old',
            fileSize: 500,
            blurScore: 800,
            dateTaken: DateTime(2025, 1, 1),
          ),
          _photo(
            id: 'new',
            fileSize: 500,
            blurScore: 800,
            dateTaken: DateTime(2026, 1, 1),
          ),
        ],
      );
      expect(newer.bestPhoto.id, 'new');
    });

    test('savableSize counts every copy except the best', () {
      final group = DuplicateGroup(
        groupId: 'g4',
        photos: [
          _photo(id: 'best', fileSize: 900),
          _photo(id: 'copy-a', fileSize: 100),
          _photo(id: 'copy-b', fileSize: 200),
        ],
      );

      expect(group.savableSize, 300);
      expect(
        DuplicateGroup(
          groupId: 'g5',
          photos: [_photo(id: 'only')],
        ).savableSize,
        0,
      );
    });

    test('keep-best selects every copy except the best', () {
      final group = DuplicateGroup(
        groupId: 'g6',
        photos: [
          _photo(id: 'small', fileSize: 100),
          _photo(id: 'best', fileSize: 900),
          _photo(id: 'medium', fileSize: 400),
        ],
      );

      final updated = group.photosAllButBestSelected;
      final selectedIds = updated
          .where((photo) => photo.isSelected)
          .map((photo) => photo.id)
          .toList();

      expect(selectedIds, ['small', 'medium']);
      expect(
        updated.firstWhere((photo) => photo.id == 'best').isSelected,
        isFalse,
      );
      // The original group is untouched; the provider swaps in the copy.
      expect(group.photos.every((photo) => !photo.isSelected), isTrue);
    });
  });

  group('DuplicateDetector', () {
    test('hammingDistance compares differing bits', () {
      expect(DuplicateDetector.hammingDistance('0000', '0000'), 0);
      expect(DuplicateDetector.hammingDistance('0000', '1010'), 2);
      expect(DuplicateDetector.hammingDistance('0000', '1111'), 4);
    });

    test('groups identical hashes as exact duplicates', () {
      final hash = '01' * 128;
      final groups = DuplicateDetector.groupDuplicates([
        _photo(id: 'a', perceptualHash: hash, fileSize: 100),
        _photo(id: 'b', perceptualHash: hash, fileSize: 200),
      ]);

      expect(groups, hasLength(1));
      expect(groups.first.photos.map((p) => p.id), ['a', 'b']);
      expect(groups.first.isExactDuplicate, isTrue);
      expect(groups.first.similarityScore, 1.0);
    });

    test('groups near hashes at or below the threshold', () {
      final groups = DuplicateDetector.groupDuplicates([
        _photo(id: 'a', perceptualHash: '0' * 256),
        _photo(id: 'b', perceptualHash: '${'1' * 24}${'0' * 232}'),
      ]);

      expect(groups, hasLength(1));
      expect(groups.first.isExactDuplicate, isFalse);
      expect(groups.first.similarityScore, closeTo(0.90625, 0.001));
    });

    test('does not group hashes beyond the threshold', () {
      final groups = DuplicateDetector.groupDuplicates([
        _photo(id: 'a', perceptualHash: '0' * 256),
        _photo(id: 'b', perceptualHash: '${'1' * 25}${'0' * 231}'),
      ]);

      expect(groups, isEmpty);
    });

    test('ignores photos without a hash', () {
      final groups = DuplicateDetector.groupDuplicates([
        _photo(id: 'a', perceptualHash: '0' * 256),
        _photo(id: 'b'),
      ]);

      expect(groups, isEmpty);
    });
  });
}
