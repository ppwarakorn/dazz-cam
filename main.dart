import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  try {
    _cameras = await availableCameras();
  } catch (_) {
    _cameras = [];
  }
  runApp(const RetroCamApp());
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

/// Builds a 4x5 color matrix (same layout as Flutter's ColorFilter.matrix)
/// from contrast, saturation, per-channel gain and per-channel lift (0-255).
List<double> buildMatrix({
  double contrast = 1,
  double saturation = 1,
  double r = 1,
  double g = 1,
  double b = 1,
  double lr = 0,
  double lg = 0,
  double lb = 0,
}) {
  const lumR = 0.2126, lumG = 0.7152, lumB = 0.0722;
  final s = saturation;
  final sat = [
    [lumR * (1 - s) + s, lumG * (1 - s), lumB * (1 - s)],
    [lumR * (1 - s), lumG * (1 - s) + s, lumB * (1 - s)],
    [lumR * (1 - s), lumG * (1 - s), lumB * (1 - s) + s],
  ];
  final gains = [r, g, b];
  final lifts = [lr, lg, lb];
  final out = <double>[];
  for (var i = 0; i < 3; i++) {
    final k = gains[i] * contrast;
    out.addAll([
      sat[i][0] * k,
      sat[i][1] * k,
      sat[i][2] * k,
      0,
      gains[i] * 128 * (1 - contrast) + lifts[i],
    ]);
  }
  out.addAll([0, 0, 0, 1, 0]);
  return out;
}

class FilmFilter {
  FilmFilter(
    this.name,
    this.matrix, {
    this.grain = 0,
    this.vignette = 0,
    this.leak = 0xFFFFFFFF,
    this.leakStrength = 0,
  });

  final String name;
  final List<double> matrix;
  final double grain; // 0..1
  final double vignette; // 0..1
  final int leak; // 0xAARRGGBB light-leak color
  final double leakStrength; // 0..1
}

final List<FilmFilter> kFilters = [
  FilmFilter('Original', buildMatrix()),
  FilmFilter(
    'Warm Film',
    buildMatrix(contrast: 1.1, saturation: 1.15, r: 1.08, b: 0.88, lr: 6, lg: 3),
    grain: 0.35,
    vignette: 0.35,
    leak: 0xFFFF5A1F,
    leakStrength: 0.55,
  ),
  FilmFilter(
    'CCD 2000',
    buildMatrix(
        contrast: 1.2, saturation: 1.3, r: 0.97, g: 1.04, b: 1.06, lr: 10, lg: 10, lb: 14),
    grain: 0.15,
    vignette: 0.2,
  ),
  FilmFilter(
    'Pastel Fade',
    buildMatrix(
        contrast: 0.85, saturation: 0.85, r: 1.04, b: 1.05, lr: 22, lg: 14, lb: 22),
    grain: 0.25,
    vignette: 0.15,
    leak: 0xFFFF8FB8,
    leakStrength: 0.35,
  ),
  FilmFilter(
    'Mono',
    buildMatrix(contrast: 1.25, saturation: 0),
    grain: 0.5,
    vignette: 0.5,
  ),
];

String stampText(DateTime n) {
  String two(int v) => v.toString().padLeft(2, '0');
  return "'${two(n.year % 100)} ${two(n.month)} ${two(n.day)}";
}

// ---------------------------------------------------------------------------
// Photo processing (runs in a background isolate)
// ---------------------------------------------------------------------------

class _Job {
  _Job(this.path, this.outPath, this.filterIndex, this.stamp, this.mirror);
  final String path;
  final String outPath;
  final int filterIndex;
  final bool stamp;
  final bool mirror;
}

String _processPhoto(_Job job) {
  final f = kFilters[job.filterIndex];
  final decoded = img.decodeJpg(File(job.path).readAsBytesSync());
  if (decoded == null) throw Exception('Cannot decode photo');
  var image = img.bakeOrientation(decoded);

  // Limit size so processing stays fast.
  const maxSide = 2048;
  if (max(image.width, image.height) > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide)
        : img.copyResize(image, height: maxSide);
  }
  if (job.mirror) image = img.flipHorizontal(image);

  final w = image.width, h = image.height;
  final cx = w / 2, cy = h / 2;
  final maxD = sqrt(cx * cx + cy * cy);
  final rnd = Random(42);
  final m = f.matrix;
  final leakR = (f.leak >> 16) & 255;
  final leakG = (f.leak >> 8) & 255;
  final leakB = f.leak & 255;

  for (final p in image) {
    final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
    var nr = m[0] * r + m[1] * g + m[2] * b + m[4];
    var ng = m[5] * r + m[6] * g + m[7] * b + m[9];
    var nb = m[10] * r + m[11] * g + m[12] * b + m[14];

    if (f.vignette > 0) {
      final dx = p.x - cx, dy = p.y - cy;
      final d = sqrt(dx * dx + dy * dy) / maxD;
      final v = 1 - f.vignette * d * d;
      nr *= v;
      ng *= v;
      nb *= v;
    }

    if (f.leakStrength > 0) {
      // Light leak glowing in from the left edge (screen blend).
      final t = max(0.0, 1 - p.x / (w * 0.5));
      final k = t * t * f.leakStrength;
      nr = 255 - (255 - nr) * (255 - leakR * k) / 255;
      ng = 255 - (255 - ng) * (255 - leakG * k) / 255;
      nb = 255 - (255 - nb) * (255 - leakB * k) / 255;
    }

    if (f.grain > 0) {
      final n = (rnd.nextDouble() - 0.5) * 80 * f.grain;
      nr += n;
      ng += n;
      nb += n;
    }

    p.r = nr.clamp(0, 255);
    p.g = ng.clamp(0, 255);
    p.b = nb.clamp(0, 255);
  }

  if (job.stamp) {
    final text = stampText(DateTime.now());
    img.drawString(
      image,
      text,
      font: img.arial48,
      x: w - text.length * 26 - w ~/ 25,
      y: h - 48 - h ~/ 25,
      color: img.ColorRgb8(255, 140, 30),
    );
  }

  File(job.outPath).writeAsBytesSync(img.encodeJpg(image, quality: 92));
  return job.outPath;
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

class RetroCamApp extends StatelessWidget {
  const RetroCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Retro Cam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  CameraLensDirection _lens = CameraLensDirection.back;
  int _filterIndex = 1;
  bool _stamp = true;
  bool _busy = false;
  bool _initializing = false;
  String? _error;

  FilmFilter get _filter => kFilters[_filterIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      final c = _controller;
      if (c != null) {
        setState(() => _controller = null);
        c.dispose();
      }
    } else if (state == AppLifecycleState.resumed &&
        _controller == null &&
        !_initializing) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    _initializing = true;
    final old = _controller;
    if (old != null) {
      setState(() => _controller = null);
      await old.dispose();
    }

    final cam = _cameras.where((c) => c.lensDirection == _lens).firstOrNull ??
        (_cameras.isNotEmpty ? _cameras.first : null);
    if (cam == null) {
      if (mounted) setState(() => _error = 'ไม่พบกล้องบนอุปกรณ์นี้');
      _initializing = false;
      return;
    }

    final c = CameraController(
      cam,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
      } else {
        setState(() {
          _controller = c;
          _error = null;
        });
      }
    } on CameraException catch (e) {
      if (mounted) {
        setState(() => _error = e.code == 'CameraAccessDenied'
            ? 'ต้องอนุญาตให้แอพใช้กล้องก่อน'
            : 'เปิดกล้องไม่สำเร็จ (${e.code})');
      }
    } finally {
      _initializing = false;
    }
  }

  Future<void> _flip() async {
    _lens = _lens == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    await _initCamera();
  }

  Future<void> _shoot() async {
    final c = _controller;
    if (c == null || _busy || c.value.isTakingPicture) return;
    setState(() => _busy = true);
    try {
      HapticFeedback.mediumImpact();
      final shot = await c.takePicture();
      final dir = await getTemporaryDirectory();
      final out = '${dir.path}/retro_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final done = await compute(
        _processPhoto,
        _Job(shot.path, out, _filterIndex, _stamp, _lens == CameraLensDirection.front),
      );
      if (!await Gal.hasAccess()) {
        if (!await Gal.requestAccess()) {
          _toast('ไม่ได้รับอนุญาตให้บันทึกรูป');
          return;
        }
      }
      await Gal.putImage(done);
      _toast('บันทึกลงแกลเลอรีแล้ว');
      try {
        File(shot.path).deleteSync();
        File(done).deleteSync();
      } catch (_) {}
    } catch (e) {
      _toast('ถ่ายไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _viewfinder()),
            _filterBar(),
            _controls(),
          ],
        ),
      ),
    );
  }

  Widget _viewfinder() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    final f = _filter;
    return Center(
      child: AspectRatio(
        aspectRatio: 1 / c.value.aspectRatio,
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColorFiltered(
                colorFilter: ColorFilter.matrix(f.matrix),
                child: CameraPreview(c),
              ),
              if (f.leakStrength > 0)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Color(f.leak).withAlpha((255 * f.leakStrength * 0.7).round()),
                          Color(f.leak).withAlpha(0),
                        ],
                        stops: const [0, 0.5],
                      ),
                    ),
                  ),
                ),
              if (f.vignette > 0)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        radius: 0.95,
                        colors: [
                          Colors.transparent,
                          Color.fromRGBO(0, 0, 0, f.vignette),
                        ],
                        stops: const [0.55, 1],
                      ),
                    ),
                  ),
                ),
              if (f.grain > 0)
                IgnorePointer(
                  child: CustomPaint(painter: _GrainPainter(f.grain)),
                ),
              if (_stamp)
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: Text(
                    stampText(DateTime.now()),
                    style: const TextStyle(
                      color: Color(0xFFFF8C1E),
                      fontFamily: 'monospace',
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterBar() {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: kFilters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => ChoiceChip(
          label: Text(kFilters[i].name),
          selected: i == _filterIndex,
          onSelected: (_) => setState(() => _filterIndex = i),
        ),
      ),
    );
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            iconSize: 28,
            tooltip: 'วันที่บนรูป',
            onPressed: () => setState(() => _stamp = !_stamp),
            icon: Icon(
              Icons.calendar_month,
              color: _stamp ? const Color(0xFFFF8C1E) : Colors.white54,
            ),
          ),
          GestureDetector(
            onTap: _shoot,
            child: Container(
              width: 78,
              height: 78,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 4),
              ),
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                child: _busy
                    ? const Padding(
                        padding: EdgeInsets.all(18),
                        child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black),
                      )
                    : null,
              ),
            ),
          ),
          IconButton(
            iconSize: 30,
            tooltip: 'สลับกล้อง',
            onPressed: _busy ? null : _flip,
            icon: const Icon(Icons.cameraswitch),
          ),
        ],
      ),
    );
  }
}

/// Static film grain overlay for the live preview.
class _GrainPainter extends CustomPainter {
  _GrainPainter(this.amount);
  final double amount;

  @override
  void paint(Canvas canvas, Size size) {
    final n = (size.width * size.height / 40).toInt();
    void layer(int seed, Color color) {
      final rnd = Random(seed);
      final pts = Float32List(n * 2);
      for (var i = 0; i < n * 2; i += 2) {
        pts[i] = rnd.nextDouble() * size.width;
        pts[i + 1] = rnd.nextDouble() * size.height;
      }
      canvas.drawRawPoints(
        ui.PointMode.points,
        pts,
        Paint()
          ..color = color
          ..strokeWidth = 1.5,
      );
    }

    layer(1, Color.fromRGBO(255, 255, 255, 0.12 * amount));
    layer(2, Color.fromRGBO(0, 0, 0, 0.18 * amount));
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.amount != amount;
}
