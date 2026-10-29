import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Where a new marker photo comes from.
enum PhotoSource { camera, gallery }

/// Takes or chooses a picture and returns its (temporary) file path, or null
/// if the user backed out. Scaled down so photos stay small on the phone.
Future<String?> pickPicture(PhotoSource source) async {
  final picked = await ImagePicker().pickImage(
    source: source == PhotoSource.camera ? ImageSource.camera : ImageSource.gallery,
    maxWidth: 1600,
    maxHeight: 1600,
    imageQuality: 85,
  );
  return picked?.path;
}

/// A marker's photo across the top of its card; tap for full screen.
class MarkerPhoto extends StatelessWidget {
  const MarkerPhoto({super.key, required this.file, required this.title});

  final File file;

  /// Shown over the full-screen view.
  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Photo of $title. Tap to view full screen.',
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PhotoViewer(file: file, title: title),
        )),
        child: Hero(
          tag: file.path,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              file,
              height: 200,
              width: double.infinity,
              fit: BoxFit.cover,
              cacheWidth: 1200,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}

/// A photo on black, pinch to zoom.
class PhotoViewer extends StatelessWidget {
  const PhotoViewer({super.key, required this.file, required this.title});

  final File file;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: Hero(tag: file.path, child: Image.file(file)),
        ),
      ),
    );
  }
}
