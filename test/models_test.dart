import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_storage_cleaner/models/data_models.dart';
import 'package:mobile_storage_cleaner/services/duplicate_detector.dart';

PhotoModel _photo({
  required String id,
  int fileSize = 0,
  bool isSelected = false,
  String perceptualHash = '',
}) {
  return PhotoModel(
    id: id,
    path: '/photos/$id.jpg',
    fileSize: fileSize,
    blurScore: 500,
    isBlurry: false,
    isSelected: isSelected,
    dateTaken: DateTime(2026, 1, 1),
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
