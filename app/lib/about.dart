import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where to make packs, learn how, and support the project.
const studioUrl = 'https://tome.rahulkannan.com';
const guideUrl = 'https://tome.rahulkannan.com/guide.html';
const sourceUrl = 'https://github.com/rahulskann/TOME';
const privacyUrl = 'https://tome.rahulkannan.com/privacy.html';
const supportUrl = 'https://buymeacoffee.com/rahulskann';

Future<void> _open(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
}

/// The app's About sheet: what TOME is, where to make packs, and how to support it.
void showTomeAbout(BuildContext context) {
  showAboutDialog(
    context: context,
    applicationName: 'TOME',
    applicationLegalese: 'Free and open source. Map packs are made by their authors.',
    children: [
      const SizedBox(height: 12),
      const Text('The Offline Map Engine', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text('Interactive maps that work with no connection. Made for games: find, filter and '
          'check off everything. And for anything else worth mapping, like the pizza places locals '
          'swear by or a scavenger hunt across town.'),
      const SizedBox(height: 12),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.edit_location_alt),
        title: const Text('Make your own map pack'),
        subtitle: const Text('TOME Studio, in your browser'),
        onTap: () => _open(studioUrl),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.menu_book),
        title: const Text('How to make a pack'),
        onTap: () => _open(guideUrl),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.local_cafe),
        title: const Text('Buy me a coffee'),
        subtitle: const Text('Like TOME? Support future projects'),
        onTap: () => _open(supportUrl),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.code),
        title: const Text('Source code'),
        onTap: () => _open(sourceUrl),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.privacy_tip_outlined),
        title: const Text('Privacy policy'),
        onTap: () => _open(privacyUrl),
      ),
    ],
  );
}
