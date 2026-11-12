import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'design.dart';

/// Prototype illustration is never presented as a real route. Without a map
/// key, live mode uses a location card and the form's coordinate inputs.
class PickupMap extends StatelessWidget {
  const PickupMap({
    super.key,
    this.latitude = 5.64,
    this.longitude = -.16,
    this.demo = false,
    this.onPick,
    this.driver,
  });
  final double latitude, longitude;
  final bool demo;
  final ValueChanged<LatLng>? onPick;
  final LatLng? driver;
  @override
  Widget build(BuildContext context) {
    const enabled = bool.fromEnvironment('MAPS_ENABLED');
    if (enabled &&
        !demo &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      return GoogleMap(
        key: ValueKey('$latitude/$longitude'),
        initialCameraPosition: CameraPosition(
          target: LatLng(latitude, longitude),
          zoom: 15,
        ),
        zoomControlsEnabled: false,
        myLocationButtonEnabled: false,
        mapToolbarEnabled: false,
        onTap: onPick,
        markers: {
          Marker(
            markerId: const MarkerId('pickup'),
            position: LatLng(latitude, longitude),
            draggable: onPick != null,
            onDragEnd: onPick,
          ),
          if (driver != null)
            Marker(
              markerId: const MarkerId('driver'),
              position: driver!,
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueGreen,
              ),
            ),
        },
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _MapArt()),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: ink,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: const [
                    BoxShadow(color: Colors.black12, blurRadius: 18),
                  ],
                ),
                child: const Icon(
                  Icons.location_on_rounded,
                  color: green,
                  size: 30,
                ),
              ),
              const SizedBox(height: 10),
              Tag(demo ? 'East Legon · illustrative map' : 'Pickup location'),
              if (!demo)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Tag(
                    '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}',
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          bottom: 12,
          left: 16,
          right: 16,
          child: Text(
            demo ? 'ILLUSTRATIVE MAP · NOT FOR NAVIGATION' : 'Map display unavailable · confirm your pickup with GPS or coordinates',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, color: muted),
          ),
        ),
      ],
    );
  }
}

class _MapArt extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFE7EFE8),
    );
    final park = Paint()..color = const Color(0xFFCADFCE);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * .04,
          size.height * .12,
          size.width * .25,
          size.height * .3,
        ),
        const Radius.circular(35),
      ),
      park,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * .72,
          size.height * .59,
          size.width * .25,
          size.height * .5,
        ),
        const Radius.circular(26),
      ),
      park,
    );
    for (var i = -2; i < 8; i++) {
      final p = Path()
        ..moveTo(i * 85.0, -30)
        ..lineTo(i * 85.0 + 95, size.height * .53)
        ..lineTo(i * 85.0 + 40, size.height + 30);
      canvas.drawPath(
        p,
        Paint()
          ..color = const Color(0xFFD9E1D9)
          ..strokeWidth = 15
          ..style = PaintingStyle.stroke,
      );
      canvas.drawPath(
        p,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 10
          ..style = PaintingStyle.stroke,
      );
    }
    for (var i = 0; i < 5; i++) {
      final p = Path()
        ..moveTo(-30, i * 90.0)
        ..quadraticBezierTo(
          size.width * .5,
          i * 90.0 + 70,
          size.width + 30,
          i * 90.0 + 15,
        );
      canvas.drawPath(
        p,
        Paint()
          ..color = Colors.white
          ..strokeWidth = i == 2 ? 17 : 9
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
