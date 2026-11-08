import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/data_models.dart';
import '../providers/photo_provider.dart';
import '../providers/storage_provider.dart';
import '../services/ai_enhance_service.dart';
import '../services/ai_enhance_settings.dart';
import '../services/enhance_service.dart';
import '../widgets/ui_widgets.dart';

enum _EnhanceMode { smart, manual, ai }

/// Editor for on-device Smart Enhance, on-device Manual Enhance, and cloud AI
/// Enhance.
///
/// Smart Enhance sharpens the painted area and never leaves the device. Manual
/// Enhance applies tonal sliders to the whole photo, also fully on-device. AI
/// Enhance uploads the whole photo to Stability AI only after an explicit
/// confirmation. Every result is saved as a new gallery image; the original is
/// left untouched unless the user explicitly moves it to the system trash.
class EnhancePhotoScreen extends StatefulWidget {
  final PhotoModel photo;

  const EnhancePhotoScreen({super.key, required this.photo});

  @override
  State<EnhancePhotoScreen> createState() => _EnhancePhotoScreenState();
}

class _EnhancePhotoScreenState extends State<EnhancePhotoScreen> {
  EnhancePreview? _preview;
  Uint8List? _result;
  Uint8List? _aiFullBytes;
  String? _loadError;

  AiEnhanceService? _aiService;
  AiKeyInfo _keyInfo = const AiKeyInfo(
    key: null,
    fromBuild: false,
    hasStoredOverride: false,
  );
  bool _consentGranted = false;
  double? _credits;
  DateTime? _creditsUpdatedAt;
  bool _loadingCredits = false;
  String? _creditsError;

  _EnhanceMode _mode = _EnhanceMode.smart;

  bool _loading = true;
  bool _processing = false;
  bool _saving = false;
  bool _saved = false;
  bool _movingOriginal = false;
  bool _originalTrashed = false;
  bool _eraser = false;
  bool _wholePhoto = false;

  double _brushRadius = 0.06;
  double _strength = 0.75;
  double _split = 0.5;
  ManualAdjustments _manual = ManualAdjustments.neutral;

  Timer? _manualPreviewTimer;
  Uint8List? _manualLiveSource;
  Future<Uint8List>? _manualLiveSourceFuture;
  Uint8List? _manualLivePreview;
  bool _manualLiveRendering = false;
  bool _manualLivePending = false;
  bool _manualLivePendingFast = true;
  bool _manualDragging = false;
  int _manualRenderGeneration = 0;

  final List<_PaintStroke> _strokes = [];
  _PaintStroke? _activeStroke;

  bool get _isAiResult => _aiFullBytes != null;

  bool get _hasUnsavedAiResult => _isAiResult && !_saved;

  String get _resultTitle {
    if (_isAiResult) return 'AI Enhance';
    return _mode == _EnhanceMode.manual ? 'Manual Enhance' : 'Smart Enhance';
  }

  bool get _canEnhance =>
      _preview != null &&
      (_mode == _EnhanceMode.manual
          ? !_manual.isNeutral
          : _mode == _EnhanceMode.smart &&
                (_wholePhoto || _strokes.any((stroke) => !stroke.erase)));

  @override
  void initState() {
    super.initState();
    _aiService = AiEnhanceService();
    _loadPreview();
    _loadAiSettings();
  }

  @override
  void dispose() {
    _manualPreviewTimer?.cancel();
    _aiService?.dispose();
    super.dispose();
  }

  Future<void> _loadPreview() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final preview = await EnhanceService.loadPreview(
        photoId: widget.photo.id,
        path: widget.photo.path,
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
        _manualLiveSource = null;
        _manualLiveSourceFuture = null;
        _manualLivePreview = null;
      });
      // Decode the small manual source now, not when the first slider moves.
      _ensureManualLiveSource();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            'This photo could not be opened. It may have been moved or '
            'removed from the gallery.';
      });
    }
  }

  Future<void> _loadAiSettings() async {
    final keyInfo = await AiEnhanceSettings.loadKeyInfo();
    final consent = await AiEnhanceSettings.isUploadConsentGranted();
    final cached = await AiEnhanceSettings.loadCachedCredits();
    if (!mounted) return;
    setState(() {
      _keyInfo = keyInfo;
      _consentGranted = consent;
      if (cached != null) {
        _credits = cached.credits;
        _creditsUpdatedAt = cached.updatedAt;
      }
    });
  }

  List<MaskStroke> _maskStrokes() {
    return _strokes
        .map((stroke) {
          final points = <double>[];
          for (final point in stroke.points) {
            points
              ..add(point.dx)
              ..add(point.dy);
          }
          return MaskStroke(
            points: points,
            radius: stroke.radius,
            erase: stroke.erase,
          );
        })
        .toList(growable: false);
  }

  void _selectMode(_EnhanceMode mode) {
    if (_processing || _saving || mode == _mode) return;
    setState(() {
      _mode = mode;
      _result = null;
      _aiFullBytes = null;
      _saved = false;
      _activeStroke = null;
    });
    if (mode == _EnhanceMode.ai) {
      unawaited(_refreshCredits(silent: true));
    } else if (mode == _EnhanceMode.manual) {
      _ensureManualLiveSource();
      _scheduleManualPreview();
    } else {
      _manualPreviewTimer?.cancel();
    }
  }

  Future<void> _enhanceSmart() async {
    final preview = _preview;
    if (preview == null || !_canEnhance || _processing) return;

    setState(() => _processing = true);
    try {
      final result = await EnhanceService.renderPreview(
        previewBytes: preview.bytes,
        strokes: _maskStrokes(),
        strength: _strength,
        wholePhoto: _wholePhoto,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _aiFullBytes = null;
        _saved = false;
        _split = 0.5;
        _processing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _processing = false);
      _showMessage('Enhancement failed: $e', isError: true);
    }
  }

  void _updateManual(ManualAdjustments value) {
    final dragged = _manualDragging;
    setState(() => _manual = value);
    _scheduleManualPreview(immediate: dragged, fast: dragged);
  }

  void _onManualDragStart(double _) {
    _manualDragging = true;
    _manualPreviewTimer?.cancel();
  }

  void _onManualDragEnd(double _) {
    _manualDragging = false;
    // Replace the small drag frame with a clean, higher-resolution preview.
    _scheduleManualPreview(immediate: true);
  }

  /// Decodes the small live-preview source once, in the background.
  ///
  /// Doing this when the editor opens means the first slider move can render
  /// immediately instead of waiting for a full decode.
  void _ensureManualLiveSource() {
    final preview = _preview;
    if (preview == null ||
        _manualLiveSource != null ||
        _manualLiveSourceFuture != null) {
      return;
    }

    final future = EnhanceService.prepareManualLiveSource(preview.bytes);
    _manualLiveSourceFuture = future;
    unawaited(
      future
          .then<void>((source) {
            if (!mounted) return;
            _manualLiveSource = source;
            if (_mode == _EnhanceMode.manual &&
                _result == null &&
                !_manual.isNeutral &&
                !_manualLiveRendering) {
              _scheduleManualPreview(immediate: true, fast: _manualDragging);
            }
          })
          .catchError((Object _) {
            if (identical(_manualLiveSourceFuture, future)) {
              _manualLiveSourceFuture = null;
            }
          }),
    );
  }

  void _scheduleManualPreview({bool immediate = false, bool fast = false}) {
    if (_mode != _EnhanceMode.manual || _result != null) return;
    _manualPreviewTimer?.cancel();

    if (_manual.isNeutral) {
      _manualRenderGeneration++;
      _manualLivePending = false;
      if (_manualLivePreview != null) {
        setState(() => _manualLivePreview = null);
      }
      return;
    }

    _ensureManualLiveSource();

    if (immediate) {
      if (_manualLiveRendering) {
        _manualLivePending = true;
        _manualLivePendingFast = fast;
        return;
      }
      unawaited(_renderManualLivePreview(fast: fast));
      return;
    }

    if (_manualLiveRendering) {
      _manualLivePending = true;
      _manualLivePendingFast = fast;
      return;
    }
    if (_manualPreviewTimer?.isActive ?? false) return;

    _manualPreviewTimer = Timer(const Duration(milliseconds: 60), () {
      unawaited(_renderManualLivePreview(fast: fast));
    });
  }

  Future<void> _renderManualLivePreview({bool fast = false}) async {
    if (_manualLiveRendering) {
      _manualLivePending = true;
      _manualLivePendingFast = fast;
      return;
    }
    final preview = _preview;
    if (preview == null ||
        _mode != _EnhanceMode.manual ||
        _result != null ||
        _manual.isNeutral) {
      return;
    }

    _manualLiveRendering = true;
    final generation = ++_manualRenderGeneration;
    final adjustments = _manual;

    try {
      var source = _manualLiveSource;
      if (source == null) {
        _ensureManualLiveSource();
        final sourceFuture = _manualLiveSourceFuture;
        if (sourceFuture == null) return;
        source = await sourceFuture;
        if (!mounted) return;
        _manualLiveSource = source;
        if (_mode != _EnhanceMode.manual || _result != null) return;
      }
      final bytes = await EnhanceService.renderManualLivePreview(
        previewBytes: source,
        adjustments: adjustments,
        fast: fast,
      );
      if (!mounted ||
          generation != _manualRenderGeneration ||
          _mode != _EnhanceMode.manual ||
          _result != null) {
        return;
      }
      setState(() => _manualLivePreview = bytes);
    } catch (_) {
      // Keep the last good frame; Apply reports errors through a snackbar.
    } finally {
      _manualLiveRendering = false;
      if (_manualLivePending && mounted) {
        final pendingFast = _manualLivePendingFast;
        _manualLivePending = false;
        _scheduleManualPreview(immediate: true, fast: pendingFast);
      }
    }
  }

  Future<void> _enhanceManual() async {
    final preview = _preview;
    if (preview == null || !_canEnhance || _processing) return;

    _manualPreviewTimer?.cancel();
    setState(() => _processing = true);
    try {
      final result = await EnhanceService.renderManualPreview(
        previewBytes: preview.bytes,
        adjustments: _manual,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _aiFullBytes = null;
        _saved = false;
        _split = 0.5;
        _processing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _processing = false);
      _showMessage('Enhancement failed: $e', isError: true);
    }
  }

  Future<void> _prepareAiEnhance() async {
    if (_processing || _saving) return;

    if (!_keyInfo.hasKey) {
      await _openKeySettings();
      return;
    }

    final needsFreshBalance =
        _credits == null ||
        _creditsUpdatedAt == null ||
        DateTime.now().difference(_creditsUpdatedAt!) >
            const Duration(seconds: 90);
    if (needsFreshBalance) {
      final refreshed = await _refreshCredits(silent: true);
      if (!mounted || !refreshed) {
        if (mounted) {
          _showMessage(
            _creditsError ??
                'Could not check the credit balance. Connect to the internet '
                    'and try again.',
            isError: true,
          );
        }
        return;
      }
    }

    if (_credits == null) {
      _showMessage(
        _creditsError ??
            'Could not check the credit balance. Connect to the internet and '
                'try again.',
        isError: true,
      );
      return;
    }
    if (_credits! < AiEnhanceService.creditsPerEnhance) {
      _showMessage(
        'This account has ${AiEnhanceSettings.formatCredits(_credits!)} '
        'credits left. AI Enhance needs '
        '${AiEnhanceService.creditsPerEnhance}. Add credits or use Smart '
        'Enhance.',
        isError: true,
      );
      return;
    }

    final allowed = await _ensureUploadConsent();
    if (!allowed || !mounted) return;

    final confirmed = await _confirmAiCall();
    if (confirmed != true || !mounted) return;

    await _runAiEnhance();
  }

  Future<void> _runAiEnhance() async {
    final key = _keyInfo.key;
    if (key == null || _processing) return;

    setState(() => _processing = true);
    try {
      final source = await EnhanceService.loadAiSource(
        photoId: widget.photo.id,
        path: widget.photo.path,
      );
      final result = await _aiService!.upscale(apiKey: key, imageBytes: source);

      final nextCredits = math.max(
        0.0,
        (_credits ?? AiEnhanceService.creditsPerEnhance.toDouble()) -
            AiEnhanceService.creditsPerEnhance,
      );
      await AiEnhanceSettings.cacheCredits(nextCredits);

      if (!mounted) return;
      setState(() {
        _result = result.previewBytes;
        _aiFullBytes = result.fullBytes;
        _saved = false;
        _split = 0.5;
        _processing = false;
        _credits = nextCredits;
        _creditsUpdatedAt = DateTime.now();
      });
      unawaited(_refreshCredits(silent: true));
      _showMessage(
        'AI enhancement complete. '
        '${AiEnhanceService.creditsPerEnhance} credits were used.',
      );
    } on AiEnhanceException catch (e) {
      if (!mounted) return;
      setState(() => _processing = false);
      _showMessage(e.message, isError: true);
      unawaited(_refreshCredits(silent: true));
    } catch (e) {
      if (!mounted) return;
      setState(() => _processing = false);
      _showMessage('AI enhancement failed: $e', isError: true);
    }
  }

  Future<void> _regenerateAi() async {
    setState(() {
      _result = null;
      _aiFullBytes = null;
      _saved = false;
    });
    await _prepareAiEnhance();
  }

  Future<bool> _refreshCredits({bool silent = false}) async {
    final key = _keyInfo.key;
    if (key == null || key.trim().isEmpty) return false;
    if (_loadingCredits) return false;

    setState(() {
      _loadingCredits = true;
      _creditsError = null;
    });
    try {
      final credits = await _aiService!.fetchBalance(apiKey: key);
      await AiEnhanceSettings.cacheCredits(credits);
      if (!mounted) return false;
      setState(() {
        _credits = credits;
        _creditsUpdatedAt = DateTime.now();
        _loadingCredits = false;
      });
      return true;
    } on AiEnhanceException catch (e) {
      if (!mounted) return false;
      setState(() {
        _loadingCredits = false;
        _creditsError = e.message;
      });
      if (!silent) _showMessage(e.message, isError: true);
      return false;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _loadingCredits = false;
        _creditsError = 'Could not check the credit balance. Try again.';
      });
      if (!silent) {
        _showMessage('Could not check the credit balance: $e', isError: true);
      }
      return false;
    }
  }

  Future<bool> _ensureUploadConsent() async {
    if (_consentGranted) return true;

    final allowed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Allow cloud enhancement?'),
        content: const Text(
          'AI Enhance uploads this photo to Stability AI\'s Fast Upscaler '
          'over HTTPS so it can add detail. The photo is used only to create '
          'this result, and Stability AI\'s API terms apply.\n\n'
          'Smart Enhance never uploads anything. You will still confirm each '
          'AI enhancement before any credits are used.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    if (allowed != true) return false;

    await AiEnhanceSettings.grantUploadConsent();
    if (!mounted) return false;
    setState(() => _consentGranted = true);
    return true;
  }

  Future<bool?> _confirmAiCall() {
    final credits = _credits;
    final remaining = credits == null
        ? null
        : math.max(0.0, credits - AiEnhanceService.creditsPerEnhance);

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = context.colors;
        return AlertDialog(
          title: const Text('Use 2 AI credits?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Stability AI charges 2 credits only when the upscale '
                'succeeds. The whole photo will be uploaded for this request.',
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.cardAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colors.border),
                ),
                child: Column(
                  children: [
                    _BalanceRow(
                      label: 'Current balance',
                      value: credits == null
                          ? 'Unknown'
                          : '${AiEnhanceSettings.formatCredits(credits)} credits',
                    ),
                    const SizedBox(height: 6),
                    _BalanceRow(
                      label: 'After success',
                      value: remaining == null
                          ? 'Unknown'
                          : '${AiEnhanceSettings.formatCredits(remaining)} credits',
                      valueColor: colors.green,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'You can keep the result, save a copy, or enhance again. '
                'Nothing is charged automatically.',
                style: TextStyle(fontSize: 11.5, color: colors.textMuted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              label: const Text('Enhance'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _save() async {
    if (_saving || _result == null) return false;
    setState(() => _saving = true);
    try {
      if (_isAiResult) {
        await EnhanceService.saveEnhanced(
          _aiFullBytes!,
          sourceName: widget.photo.path,
          suffix: '_ai_enhanced',
          description:
              'AI enhanced with Stability AI via Mobile Storage Cleaner',
        );
      } else if (_mode == _EnhanceMode.manual) {
        final bytes = await EnhanceService.renderManualEnhanced(
          photoId: widget.photo.id,
          path: widget.photo.path,
          adjustments: _manual,
        );
        await EnhanceService.saveEnhanced(
          bytes,
          sourceName: widget.photo.path,
          description: 'Manually enhanced with Mobile Storage Cleaner',
        );
      } else {
        final bytes = await EnhanceService.renderEnhanced(
          photoId: widget.photo.id,
          path: widget.photo.path,
          strokes: _maskStrokes(),
          strength: _strength,
          wholePhoto: _wholePhoto,
        );
        await EnhanceService.saveEnhanced(bytes, sourceName: widget.photo.path);
      }
      if (!mounted) return true;
      setState(() {
        _saving = false;
        _saved = true;
      });
      unawaited(context.read<PhotoProvider>().checkForNewPhotos());
      unawaited(context.read<StorageProvider>().refreshStorage());
      _showMessage('Saved as a new photo in your gallery.');
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _saving = false);
      _showMessage('The enhanced copy could not be saved: $e', isError: true);
      return false;
    }
  }

  Future<void> _moveOriginalToTrash() async {
    if (_movingOriginal || _originalTrashed) return;
    final colors = context.colors;
    final provider = context.read<PhotoProvider>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        title: 'Move the original to trash?',
        content:
            'The enhanced copy is already saved. The original will move to '
            "Android's trash and can be restored from Recently Deleted for "
            'about 30 days.',
        photoCount: 1,
        detail:
            'About ${widget.photo.sizeString} stays in the trash until it '
            'is emptied or expires.',
        note: 'Android will ask you to confirm.',
        confirmLabel: 'Move to trash',
        icon: Icons.delete_sweep_outlined,
        onConfirm: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _movingOriginal = true);
    final result = await provider.movePhotosToTrash([widget.photo]);
    if (!mounted) return;
    setState(() => _movingOriginal = false);

    if (result.error != null) {
      _showMessage(result.error!, isError: true, background: colors.red);
    } else if (result.canceled) {
      _showMessage('Canceled — the original was not moved.');
    } else {
      setState(() => _originalTrashed = true);
      _showMessage('Original moved to Recently Deleted.');
    }
  }

  void _showMessage(String message, {bool isError = false, Color? background}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: isError ? const TextStyle(color: Colors.white) : null,
          ),
          backgroundColor: isError ? (background ?? context.colors.red) : null,
        ),
      );
  }

  void _startStroke(Offset local, Size size) {
    if (_mode != _EnhanceMode.smart || _wholePhoto) return;
    final point = _normalize(local, size);
    final stroke = _PaintStroke(
      points: [point],
      radius: _brushRadius,
      erase: _eraser,
    );
    setState(() {
      _strokes.add(stroke);
      _activeStroke = stroke;
    });
  }

  void _extendStroke(Offset local, Size size) {
    final stroke = _activeStroke;
    if (_mode != _EnhanceMode.smart || stroke == null || _wholePhoto) return;
    final point = _normalize(local, size);
    if (stroke.points.isNotEmpty) {
      final last = stroke.points.last;
      final dx = point.dx - last.dx;
      final dy = point.dy - last.dy;
      if (dx * dx + dy * dy < 0.000004) return;
    }
    setState(() => stroke.points.add(point));
  }

  Offset _normalize(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) return Offset.zero;
    return Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
  }

  void _endStroke() {
    _activeStroke = null;
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.removeLast());
  }

  void _clear() {
    if (_strokes.isEmpty) return;
    setState(_strokes.clear);
  }

  void _backToEdit() {
    setState(() {
      _result = null;
      _aiFullBytes = null;
      _saved = false;
    });
  }

  Future<void> _openKeySettings() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ApiKeySheet(initial: _keyInfo),
    );
    if (changed != true || !mounted) return;

    final info = await AiEnhanceSettings.loadKeyInfo();
    if (!mounted) return;
    setState(() {
      _keyInfo = info;
      _credits = null;
      _creditsUpdatedAt = null;
      _creditsError = null;
    });
    if (info.hasKey) {
      await _refreshCredits(silent: true);
    } else {
      await _loadAiSettings();
    }
  }

  Future<void> _handleClose() async {
    if (_saving) return;
    if (!_hasUnsavedAiResult) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save this AI result?'),
        content: const Text(
          'This result used 2 credits. Save a copy before closing, or discard '
          'it and enhance again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('discard'),
            child: const Text('Discard'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop('save'),
            child: const Text('Save copy'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;

    if (choice == 'save') {
      final saved = await _save();
      if (saved && mounted) Navigator.of(context).pop();
      return;
    }

    setState(() {
      _result = null;
      _aiFullBytes = null;
      _saved = false;
    });
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasUnsavedAiResult,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_handleClose());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_result != null ? _resultTitle : 'Enhance Photo'),
          actions: [
            if (_result != null && !_saving && !_isAiResult)
              TextButton(onPressed: _backToEdit, child: const Text('Adjust')),
            if (_result != null)
              IconButton(
                onPressed: _saving ? null : _handleClose,
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Close',
              ),
            const SizedBox(width: 4),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(child: _buildBody(context)),
            if (_processing || _saving)
              Positioned.fill(
                child: _ProcessingOverlay(
                  label: _saving
                      ? 'Saving the full-resolution copy…'
                      : _mode == _EnhanceMode.ai
                      ? 'Upscaling with Stability AI…'
                      : _mode == _EnhanceMode.manual
                      ? 'Applying manual adjustments…'
                      : _wholePhoto
                      ? 'Enhancing the whole photo…'
                      : 'Enhancing the painted area…',
                  detail: _saving
                      ? 'The photo stays on this device.'
                      : _mode == _EnhanceMode.ai
                      ? 'The photo is sent over HTTPS for this request only.'
                      : 'Everything happens on this device.',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null || _preview == null) {
      return EmptyState(
        icon: Icons.broken_image_outlined,
        title: 'Photo Unavailable',
        subtitle: _loadError ?? 'This photo could not be opened.',
        onAction: _loadPreview,
        actionLabel: 'Try Again',
      );
    }
    if (_result != null) {
      return _buildResult(context);
    }
    return _buildEditor(context);
  }

  Widget _buildEditor(BuildContext context) {
    final colors = context.colors;
    final preview = _preview!;
    final isSmart = _mode == _EnhanceMode.smart;
    final isManual = _mode == _EnhanceMode.manual;
    final displayBytes = isManual
        ? (_manualLivePreview ?? preview.bytes)
        : preview.bytes;

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = _fitSize(constraints.biggest, preview.aspectRatio);
                return Center(
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanDown: isSmart
                          ? (details) =>
                                _startStroke(details.localPosition, size)
                          : null,
                      onPanUpdate: isSmart
                          ? (details) =>
                                _extendStroke(details.localPosition, size)
                          : null,
                      onPanEnd: isSmart ? (_) => _endStroke() : null,
                      onPanCancel: isSmart ? _endStroke : null,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(
                              displayBytes,
                              fit: BoxFit.fill,
                              gaplessPlayback: true,
                            ),
                            if (isSmart)
                              CustomPaint(
                                painter: _MaskPainter(
                                  strokes: _strokes,
                                  color: colors.brand,
                                ),
                              ),
                            if (isSmart && _wholePhoto)
                              ColoredBox(
                                color: colors.brand.withValues(alpha: 0.12),
                              ),
                            Positioned(
                              left: 10,
                              bottom: 10,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  _mode == _EnhanceMode.ai
                                      ? 'Whole photo • 4× AI upscale'
                                      : _mode == _EnhanceMode.manual
                                      ? (_manualLivePreview == null
                                            ? 'Whole photo • manual controls'
                                            : 'Live preview • manual controls')
                                      : _wholePhoto
                                      ? 'Whole photo selected'
                                      : 'Paint the area to sharpen',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        _buildControls(context),
      ],
    );
  }

  Widget _buildControls(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: colors.card,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<_EnhanceMode>(
                segments: const [
                  ButtonSegment(
                    value: _EnhanceMode.smart,
                    icon: Icon(Icons.phone_android_rounded, size: 17),
                    label: Text('Smart'),
                  ),
                  ButtonSegment(
                    value: _EnhanceMode.manual,
                    icon: Icon(Icons.tune_rounded, size: 17),
                    label: Text('Manual'),
                  ),
                  ButtonSegment(
                    value: _EnhanceMode.ai,
                    icon: Icon(Icons.cloud_outlined, size: 17),
                    label: Text('AI'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: _processing || _saving
                    ? null
                    : (selection) => _selectMode(selection.first),
                showSelectedIcon: false,
                expandedInsets: EdgeInsets.zero,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ),
            const SizedBox(height: 6),
            _buildModeControls(context),
          ],
        ),
      ),
    );
  }

  Widget _buildModeControls(BuildContext context) {
    // A stable height keeps the mode buttons from moving when the active
    // panel changes, so a tap cannot land on a slider that just appeared.
    final panelHeight = math.min(
      MediaQuery.sizeOf(context).height * 0.36,
      300.0,
    );
    switch (_mode) {
      case _EnhanceMode.smart:
        return SizedBox(
          height: panelHeight,
          child: SingleChildScrollView(
            child: Column(children: _buildSmartControls(context)),
          ),
        );
      case _EnhanceMode.manual:
        return SizedBox(
          height: panelHeight,
          child: _buildManualControls(context),
        );
      case _EnhanceMode.ai:
        return SizedBox(
          height: panelHeight,
          child: SingleChildScrollView(
            child: Column(children: _buildAiControls(context)),
          ),
        );
    }
  }

  List<Widget> _buildSmartControls(BuildContext context) {
    final colors = context.colors;
    return [
      Row(
        children: [
          Expanded(
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.brush_rounded, size: 18),
                  label: Text('Brush'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.auto_fix_off_rounded, size: 18),
                  label: Text('Eraser'),
                ),
              ],
              selected: {_eraser},
              onSelectionChanged: _wholePhoto
                  ? null
                  : (selection) => setState(() => _eraser = selection.first),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            onPressed: _strokes.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo_rounded),
            tooltip: 'Undo last stroke',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: _strokes.isEmpty ? null : _clear,
            icon: const Icon(Icons.layers_clear_outlined),
            tooltip: 'Clear painted area',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
      _SliderRow(
        label: 'Brush',
        value: _brushRadius,
        min: 0.02,
        max: 0.16,
        display: '${(_brushRadius * 200).round()}%',
        onChanged: _wholePhoto
            ? null
            : (value) => setState(() => _brushRadius = value),
      ),
      _SliderRow(
        label: 'Strength',
        value: _strength,
        min: 0.2,
        max: 1,
        display: '${(_strength * 100).round()}%',
        onChanged: (value) => setState(() => _strength = value),
      ),
      Row(
        children: [
          Expanded(
            child: Text(
              'Enhance the whole photo',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          Switch(
            value: _wholePhoto,
            onChanged: (value) => setState(() => _wholePhoto = value),
          ),
        ],
      ),
      Text(
        _wholePhoto
            ? 'Strong on-device detail recovery is applied to the whole photo.'
            : 'Paint the soft areas. Only the painted area changes, and the '
                  'rest stays untouched.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: colors.textMuted),
      ),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _canEnhance ? _enhanceSmart : null,
          icon: const Icon(Icons.auto_awesome_rounded, size: 19),
          label: Text(
            _wholePhoto ? 'Enhance Whole Photo' : 'Enhance Painted Area',
          ),
        ),
      ),
    ];
  }

  Widget _buildManualControls(BuildContext context) {
    final colors = context.colors;
    final manual = _manual;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.tune_rounded, size: 16, color: colors.brand),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Manual Enhance',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: manual.isNeutral
                  ? null
                  : () => _updateManual(ManualAdjustments.neutral),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.restart_alt_rounded, size: 17),
              label: const Text('Reset', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                _SliderRow(
                  label: 'Lighting',
                  value: manual.lighting,
                  min: -100,
                  max: 100,
                  display: _signed(manual.lighting),
                  onChangeStart: _onManualDragStart,
                  onChangeEnd: _onManualDragEnd,
                  onChanged: (value) =>
                      _updateManual(_manual.copyWith(lighting: value)),
                ),
                _SliderRow(
                  label: 'Sharpness',
                  value: manual.sharpness,
                  min: 0,
                  max: 100,
                  display: '${manual.sharpness.round()}',
                  onChangeStart: _onManualDragStart,
                  onChangeEnd: _onManualDragEnd,
                  onChanged: (value) =>
                      _updateManual(_manual.copyWith(sharpness: value)),
                ),
                _SliderRow(
                  label: 'Contrast',
                  value: manual.contrast,
                  min: -100,
                  max: 100,
                  display: _signed(manual.contrast),
                  onChangeStart: _onManualDragStart,
                  onChangeEnd: _onManualDragEnd,
                  onChanged: (value) =>
                      _updateManual(_manual.copyWith(contrast: value)),
                ),
                _SliderRow(
                  label: 'Clarity',
                  value: manual.clarity,
                  min: 0,
                  max: 100,
                  display: '${manual.clarity.round()}',
                  onChangeStart: _onManualDragStart,
                  onChangeEnd: _onManualDragEnd,
                  onChanged: (value) =>
                      _updateManual(_manual.copyWith(clarity: value)),
                ),
                _SliderRow(
                  label: 'Saturation',
                  value: manual.saturation,
                  min: -100,
                  max: 100,
                  display: _signed(manual.saturation),
                  onChangeStart: _onManualDragStart,
                  onChangeEnd: _onManualDragEnd,
                  onChanged: (value) =>
                      _updateManual(_manual.copyWith(saturation: value)),
                ),
                _SliderRow(
                  label: 'Hue',
                  value: manual.hue,
                  min: -180,
                  max: 180,
                  display: '${_signed(manual.hue)}°',
                  onChangeStart: _onManualDragStart,
                  onChangeEnd: _onManualDragEnd,
                  onChanged: (value) =>
                      _updateManual(_manual.copyWith(hue: value)),
                ),
                _SliderRow(
                  label: 'Highlights',
                  value: manual.highlights,
                  min: -100,
                  max: 100,
                  display: _signed(manual.highlights),
                  onChangeStart: _onManualDragStart,
                  onChangeEnd: _onManualDragEnd,
                  onChanged: (value) =>
                      _updateManual(_manual.copyWith(highlights: value)),
                ),
                _SliderRow(
                  label: 'Temperature',
                  value: manual.temperature,
                  min: -100,
                  max: 100,
                  display: _signed(manual.temperature),
                  onChangeStart: _onManualDragStart,
                  onChangeEnd: _onManualDragEnd,
                  onChanged: (value) =>
                      _updateManual(_manual.copyWith(temperature: value)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          manual.isNeutral
              ? 'Move a slider to update the preview live, then save a new copy.'
              : 'Live preview on this device. Saving creates a new copy.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10.5, color: colors.textMuted),
        ),
        const SizedBox(height: 6),
        ElevatedButton.icon(
          onPressed: _canEnhance && !_processing && !_saving
              ? _enhanceManual
              : null,
          icon: const Icon(Icons.tune_rounded, size: 19),
          label: const Text('Apply Manual Enhance'),
        ),
      ],
    );
  }

  String _signed(double value) {
    final rounded = value.round();
    return rounded > 0 ? '+$rounded' : '$rounded';
  }

  List<Widget> _buildAiControls(BuildContext context) {
    final colors = context.colors;
    final hasKey = _keyInfo.hasKey;
    final credits = _credits;
    final lowCredits =
        credits != null && credits < AiEnhanceService.creditsPerEnhance;
    final balanceColor = credits == null
        ? colors.textMuted
        : lowCredits
        ? colors.red
        : colors.green;

    return [
      Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: colors.cardAlt,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colors.brand.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    color: colors.brand,
                    size: 19,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Stability AI Fast Upscaler',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '4× detail in the cloud • 2 credits on success',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: colors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                _CreditChip(
                  credits: credits,
                  loading: _loadingCredits,
                  color: balanceColor,
                  onTap: hasKey ? () => _refreshCredits() : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  hasKey ? Icons.key_rounded : Icons.key_off_rounded,
                  size: 15,
                  color: hasKey ? colors.green : colors.amber,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    hasKey
                        ? '${_keyInfo.fromBuild ? 'Demo' : 'Custom'} key '
                              '${AiEnhanceSettings.maskKey(_keyInfo.key!)}'
                        : 'Add a Stability AI key to use AI.',
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: _processing || _saving ? null : _openKeySettings,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(
                    hasKey ? 'Change' : 'Add key',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      if (_creditsError != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _creditsError!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: colors.red),
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Only this photo is uploaded, and only after you confirm. Smart '
            'mode stays on-device.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: colors.textMuted),
          ),
        ),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _aiButtonAction(),
          icon: Icon(
            !hasKey
                ? Icons.key_rounded
                : lowCredits
                ? Icons.block_rounded
                : Icons.cloud_upload_outlined,
            size: 19,
          ),
          label: Text(_aiButtonLabel()),
        ),
      ),
    ];
  }

  VoidCallback? _aiButtonAction() {
    if (_processing || _saving) return null;
    if (!_keyInfo.hasKey) return _openKeySettings;
    if (_loadingCredits && _credits == null) return null;
    if (_credits != null && _credits! < AiEnhanceService.creditsPerEnhance) {
      return null;
    }
    return _prepareAiEnhance;
  }

  String _aiButtonLabel() {
    if (!_keyInfo.hasKey) return 'Add API Key';
    if (_loadingCredits && _credits == null) return 'Checking balance…';
    if (_credits != null && _credits! < AiEnhanceService.creditsPerEnhance) {
      return 'Not Enough Credits';
    }
    return 'Enhance with AI • 2 credits';
  }

  Widget _buildResult(BuildContext context) {
    final colors = context.colors;
    final preview = _preview!;
    final result = _result!;
    final ai = _isAiResult;

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: _BeforeAfterView(
              before: preview.bytes,
              after: result,
              aspectRatio: preview.aspectRatio,
              split: _split,
              beforeLabel: ai ? 'ORIGINAL' : 'BEFORE',
              afterLabel: ai ? 'AI 4×' : 'AFTER',
              onChanged: (value) => setState(() => _split = value),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: BoxDecoration(
              color: colors.card,
              border: Border(top: BorderSide(color: colors.border)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _saved
                      ? 'Saved as a new photo. The original is unchanged.'
                      : 'Drag the divider to compare the original with the '
                            'result.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
                const SizedBox(height: 4),
                Text(
                  ai
                      ? (_saved
                            ? 'Full 4× resolution saved. 2 credits were used.'
                            : 'AI adds detail and may slightly reinterpret '
                                  'fine textures. 2 credits were used.')
                      : _mode == _EnhanceMode.manual
                      ? (_saved
                            ? 'The adjusted full-resolution copy is saved. '
                                  'The original is unchanged.'
                            : 'Manual Enhance applies your adjustments on '
                                  'this device; the original is unchanged.')
                      : 'Smart Enhance recovers detail already in the photo; '
                            'it cannot invent missing detail.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: colors.textMuted),
                ),
                if (ai && _credits != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Balance: ${AiEnhanceSettings.formatCredits(_credits!)} '
                    'credits',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: colors.green,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                if (_saved)
                  _buildSavedActions(context)
                else
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _saving
                              ? null
                              : ai
                              ? _regenerateAi
                              : _backToEdit,
                          icon: Icon(
                            ai ? Icons.refresh_rounded : Icons.tune_rounded,
                            size: 18,
                          ),
                          label: Text(
                            ai
                                ? 'Enhance Again'
                                : _mode == _EnhanceMode.manual
                                ? 'Adjust Settings'
                                : 'Adjust Area',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: const Icon(Icons.save_alt_rounded, size: 18),
                          label: const Text('Save Copy'),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSavedActions(BuildContext context) {
    final colors = context.colors;
    if (_originalTrashed) {
      return Row(
        children: [
          Icon(Icons.check_circle_rounded, color: colors.green, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'The original is in Recently Deleted.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done'),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _movingOriginal ? null : _moveOriginalToTrash,
            icon: _movingOriginal
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_sweep_outlined, size: 18),
            label: const Text('Trash Original'),
            style: OutlinedButton.styleFrom(foregroundColor: colors.red),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }

  Size _fitSize(Size available, double aspectRatio) {
    var width = available.width;
    var height = width / aspectRatio;
    if (height > available.height) {
      height = available.height;
      width = height * aspectRatio;
    }
    return Size(width, height);
  }
}

class _BalanceRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _BalanceRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: valueColor ?? colors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _CreditChip extends StatelessWidget {
  final double? credits;
  final bool loading;
  final Color color;
  final VoidCallback? onTap;

  const _CreditChip({
    required this.credits,
    required this.loading,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = credits == null
        ? 'Balance'
        : '${AiEnhanceSettings.formatCredits(credits!)} cr';
    return Tooltip(
      message: onTap == null
          ? 'Add a key to check your balance'
          : 'Tap to refresh the balance',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: color,
                  ),
                )
              else
                Icon(Icons.toll_rounded, size: 13, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApiKeySheet extends StatefulWidget {
  final AiKeyInfo initial;

  const _ApiKeySheet({required this.initial});

  @override
  State<_ApiKeySheet> createState() => _ApiKeySheetState();
}

class _ApiKeySheetState extends State<_ApiKeySheet> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.length < 20 || !value.startsWith('sk-')) {
      setState(() {
        _error = 'Enter a valid Stability AI key. It starts with "sk-".';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AiEnhanceSettings.saveApiKey(value);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'The key could not be saved securely. Try again.';
      });
    }
  }

  Future<void> _removeOverride() async {
    setState(() => _saving = true);
    await AiEnhanceSettings.clearStoredApiKey();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final initial = widget.initial;

    final statusText = initial.hasStoredOverride
        ? 'Custom key saved • ${AiEnhanceSettings.maskKey(initial.key!)}'
        : initial.fromBuild
        ? 'Demo key active • ${AiEnhanceSettings.maskKey(initial.key!)}'
        : 'No key saved yet';

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'AI settings',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'The key is stored in Android secure storage and is never '
              'written to logs or included in a photo.',
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.cardAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                children: [
                  Icon(
                    initial.hasKey ? Icons.key_rounded : Icons.key_off_rounded,
                    size: 18,
                    color: initial.hasKey ? colors.green : colors.amber,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
                labelText: 'Stability AI API key',
                hintText: initial.fromBuild
                    ? 'Enter a key to override the demo key'
                    : 'sk-...',
                errorText: _error,
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  tooltip: _obscure ? 'Show key' : 'Hide key',
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Get a free key at platform.stability.ai. The demo account has '
              'limited credits; each successful AI enhancement uses 2.',
              style: TextStyle(fontSize: 11, color: colors.textMuted),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                if (initial.hasStoredOverride)
                  TextButton(
                    onPressed: _saving ? null : _removeOverride,
                    child: const Text('Remove override'),
                  ),
                const Spacer(),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Save key'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChangeStart: onChangeStart,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaintStroke {
  final List<Offset> points;
  final double radius;
  final bool erase;

  _PaintStroke({
    required this.points,
    required this.radius,
    required this.erase,
  });
}

class _MaskPainter extends CustomPainter {
  final List<_PaintStroke> strokes;
  final Color color;

  const _MaskPainter({required this.strokes, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (strokes.isEmpty) return;

    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final strokeWidth = stroke.radius * 2 * size.width;
      final paint = Paint()
        ..style = stroke.points.length == 1
            ? PaintingStyle.fill
            : PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = stroke.erase
            ? Colors.transparent
            : color.withValues(alpha: 0.4)
        ..blendMode = stroke.erase ? BlendMode.clear : BlendMode.srcOver
        ..maskFilter = stroke.erase
            ? null
            : MaskFilter.blur(
                BlurStyle.normal,
                stroke.radius * size.width * 0.2,
              );

      if (stroke.points.length == 1) {
        final point = stroke.points.first;
        canvas.drawCircle(
          Offset(point.dx * size.width, point.dy * size.height),
          stroke.radius * size.width,
          paint,
        );
        continue;
      }

      final path = Path();
      final first = stroke.points.first;
      path.moveTo(first.dx * size.width, first.dy * size.height);
      for (var i = 1; i < stroke.points.length; i++) {
        final point = stroke.points[i];
        path.lineTo(point.dx * size.width, point.dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MaskPainter oldDelegate) => true;
}

class _BeforeAfterView extends StatelessWidget {
  final Uint8List before;
  final Uint8List after;
  final double aspectRatio;
  final double split;
  final ValueChanged<double> onChanged;
  final String beforeLabel;
  final String afterLabel;

  const _BeforeAfterView({
    required this.before,
    required this.after,
    required this.aspectRatio,
    required this.split,
    required this.onChanged,
    this.beforeLabel = 'BEFORE',
    this.afterLabel = 'AFTER',
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.biggest;
        var width = available.width;
        var height = width / aspectRatio;
        if (height > available.height) {
          height = available.height;
          width = height * aspectRatio;
        }
        final size = Size(width, height);
        final divider = size.width * split;

        return Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => onChanged(
                (details.localPosition.dx / size.width).clamp(0, 1),
              ),
              onHorizontalDragUpdate: (details) => onChanged(
                (details.localPosition.dx / size.width).clamp(0, 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      after,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    ),
                    ClipRect(
                      clipper: _SplitClipper(split),
                      child: Image.memory(
                        before,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                      ),
                    ),
                    Positioned(
                      left: 10,
                      top: 10,
                      child: _label(context, beforeLabel),
                    ),
                    Positioned(
                      right: 10,
                      top: 10,
                      child: _label(context, afterLabel),
                    ),
                    Positioned(
                      left: divider - 1,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 2,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                    Positioned(
                      left: divider - 18,
                      top: size.height / 2 - 18,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.drag_indicator_rounded,
                          size: 20,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _label(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _SplitClipper extends CustomClipper<Rect> {
  final double split;

  const _SplitClipper(this.split);

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, size.width * split, size.height);
  }

  @override
  bool shouldReclip(covariant _SplitClipper oldClipper) =>
      oldClipper.split != split;
}

class _ProcessingOverlay extends StatelessWidget {
  final String label;
  final String detail;

  const _ProcessingOverlay({required this.label, required this.detail});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.45),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 16),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
