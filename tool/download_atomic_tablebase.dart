// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class TablebaseFile {
  final String filename;
  final String md5;
  final String url;
  int size;

  TablebaseFile({
    required this.filename,
    required this.md5,
    required this.url,
    this.size = 0,
  });
}

Future<void> main(List<String> args) async {
  final targetDir = Directory(
    args.isNotEmpty ? args.first : p.join('data', 'tablebases', 'atomic'),
  );

  print('====================================================');
  print('Lichess Atomic 3-4-5 Piece Tablebase Downloader');
  print('Target directory: ${targetDir.absolute.path}');
  print('====================================================');

  if (!targetDir.existsSync()) {
    targetDir.createSync(recursive: true);
  }

  final client = http.Client();
  const baseUrl = 'https://tablebase.lichess.ovh/tables/atomic/3-4-5';

  try {
    print('Fetching tablebase file manifests (MD5 checksums)...');
    final wdlMd5Resp = await client.get(Uri.parse('$baseUrl/3-4-5.atbw.md5'));
    final dtzMd5Resp = await client.get(Uri.parse('$baseUrl/3-4-5.atbz.md5'));

    if (wdlMd5Resp.statusCode != 200 || dtzMd5Resp.statusCode != 200) {
      print('Failed to fetch checksum manifests. HTTP ${wdlMd5Resp.statusCode} / ${dtzMd5Resp.statusCode}');
      return;
    }

    final files = <TablebaseFile>[];

    void parseManifest(String content) {
      final lines = const LineSplitter().convert(content);
      for (final line in lines) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 2) {
          final hash = parts[0];
          final name = parts[1];
          files.add(
            TablebaseFile(
              filename: name,
              md5: hash,
              url: '$baseUrl/$name',
            ),
          );
        }
      }
    }

    parseManifest(wdlMd5Resp.body);
    parseManifest(dtzMd5Resp.body);

    print('Discovered ${files.length} tablebase files to download.');

    // Save manifest files locally for offline verification
    File(p.join(targetDir.path, '3-4-5.atbw.md5')).writeAsStringSync(wdlMd5Resp.body);
    File(p.join(targetDir.path, '3-4-5.atbz.md5')).writeAsStringSync(dtzMd5Resp.body);

    // Concurrently fetch file sizes if needed, or filter already downloaded files
    int skippedCount = 0;
    int alreadyDownloadedBytes = 0;
    final toDownload = <TablebaseFile>[];

    for (final f in files) {
      final localFile = File(p.join(targetDir.path, f.filename));
      if (localFile.existsSync() && localFile.lengthSync() > 0) {
        skippedCount++;
        alreadyDownloadedBytes += localFile.lengthSync();
      } else {
        toDownload.add(f);
      }
    }

    if (skippedCount > 0) {
      print('Found $skippedCount already downloaded files (${(alreadyDownloadedBytes / (1024 * 1024)).toStringAsFixed(1)} MB). Resuming remaining ${toDownload.length} files...');
    }

    if (toDownload.isEmpty) {
      print('All ${files.length} tablebase files are already present and downloaded!');
      return;
    }

    int completedCount = skippedCount;
    int downloadedBytes = alreadyDownloadedBytes;
    final stopwatch = Stopwatch()..start();

    // Concurrent worker pool
    const concurrency = 6;
    int currentIndex = 0;

    Future<void> worker(int workerId) async {
      final workerHttpClient = HttpClient();
      workerHttpClient.connectionTimeout = const Duration(seconds: 15);

      while (true) {
        if (currentIndex >= toDownload.length) return;
        final fileIndex = currentIndex++;
        final file = toDownload[fileIndex];

        final targetPath = p.join(targetDir.path, file.filename);
        final tempPath = '$targetPath.part';

        bool success = false;
        int retries = 3;

        while (!success && retries > 0) {
          try {
            final request = await workerHttpClient.getUrl(Uri.parse(file.url));
            final response = await request.close();

            if (response.statusCode == 200) {
              final outFile = File(tempPath);
              final sink = outFile.openWrite();

              await for (final chunk in response) {
                sink.add(chunk);
                downloadedBytes += chunk.length;
              }
              await sink.flush();
              await sink.close();

              // Rename from .part to final name
              final finalFile = File(targetPath);
              if (finalFile.existsSync()) finalFile.deleteSync();
              outFile.renameSync(targetPath);

              success = true;
              completedCount++;

              final elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
              final speedMBs = elapsedSec > 0 ? ((downloadedBytes - alreadyDownloadedBytes) / (1024 * 1024)) / elapsedSec : 0.0;
              final totalMB = downloadedBytes / (1024 * 1024);

              stdout.write('\r[$completedCount/${files.length}] ${totalMB.toStringAsFixed(1)} MB | ${speedMBs.toStringAsFixed(1)} MB/s | ${file.filename}        ');
            } else {
              retries--;
              await Future.delayed(const Duration(milliseconds: 500));
            }
          } catch (e) {
            retries--;
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }

        if (!success) {
          print('\n[Error] Failed to download ${file.filename} after retries.');
        }
      }
    }

    print('Starting download with $concurrency parallel connections...');
    final workers = List.generate(concurrency, (i) => worker(i));
    await Future.wait(workers);

    stopwatch.stop();
    print('\n====================================================');
    print('Download completed in ${stopwatch.elapsed.inMinutes}m ${(stopwatch.elapsed.inSeconds % 60)}s!');
    print('Total files: $completedCount / ${files.length}');
    print('Directory: ${targetDir.absolute.path}');
    print('====================================================');
  } finally {
    client.close();
  }
}
