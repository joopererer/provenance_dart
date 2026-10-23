// Reads and writes provenance metadata of a media file.
//
// Run with: dart run example/provenance_dart_example.dart <file>

import 'dart:io';

import 'package:provenance_dart/provenance_dart.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln(
      'usage: dart run example/provenance_dart_example.dart <file>',
    );
    exitCode = 64;
    return;
  }

  final path = arguments.first;
  if (!await File(path).exists()) {
    stderr.writeln('no such file: $path');
    exitCode = 66;
    return;
  }

  final format = await MetadataService.detectFormat(path);
  stdout.writeln('format: ${format.name}');
  stdout.writeln('C2PA:   ${await MetadataService.hasC2pa(path)}');

  final existing = await MetadataService.readProvenance(path);
  if (existing != null) {
    stdout.writeln('existing provenance:');
    existing.toJson().forEach((key, value) => stdout.writeln('  $key: $value'));
  } else {
    stdout.writeln('no provenance metadata');
  }

  final provenance = ProvenanceBuilder(
    platform: 'web',
    capturedBy: 'provenance_dart-example/0.1.0',
    sourceUrl: 'https://example.com/articles/42?utm_source=newsletter',
    title: 'Example title',
    caption: 'Written by the provenance_dart example.',
    existingAssetId: existing?.assetId,
  ).build();

  final result = await MetadataService.embedProvenance(
    filePath: path,
    provenance: provenance,
  );

  if (result.skippedC2pa || result.isFormatError) {
    stdout.writeln(
      'embedding skipped (${result.errorMessage}); writing a sidecar',
    );
    await MetadataService.writeSidecar(path, provenance);
    stdout.writeln('sidecar: ${sidecarPathFor(path)}');
  } else if (result.success) {
    stdout.writeln('embedded provenance into $path');
  } else {
    stderr.writeln('failed: ${result.errorMessage}');
    exitCode = 1;
  }
}
