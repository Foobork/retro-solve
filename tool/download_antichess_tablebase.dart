// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class TablebaseFile {
  final String filename;
  final String sha256;
  final String url;

  TablebaseFile({
    required this.filename,
    required this.sha256,
    required this.url,
  });
}

Future<void> main(List<String> args) async {
  final targetDir = Directory(
    args.isNotEmpty ? args.first : p.join('data', 'tablebases', 'antichess'),
  );

  print('====================================================');
  print('Lichess Antichess 2-3-4 Piece DTW Tablebase Downloader (.an0)');
  print('Target directory: ${targetDir.absolute.path}');
  print('====================================================');

  if (!targetDir.existsSync()) {
    targetDir.createSync(recursive: true);
  }

  final client = http.Client();
  const baseUrl = 'https://tablebase.lichess.ovh/tables/antichess/antichess-tb';

  try {
    print('Fetching tablebase file manifest (antichess-tb.sha256)...');
    final manifestResp = await client.get(Uri.parse('$baseUrl/antichess-tb.sha256'));

    if (manifestResp.statusCode != 200) {
      print('Failed to fetch checksum manifest. HTTP ${manifestResp.statusCode}');
      return;
    }

    final files = <TablebaseFile>[];
    final lines = const LineSplitter().convert(manifestResp.body);
    for (final line in lines) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final hash = parts[0];
        final name = parts[1];
        files.add(
          TablebaseFile(
            filename: name,
            sha256: hash,
            url: '$baseUrl/$name',
          ),
        );
      }
    }

    print('Discovered ${files.length} DTW tablebase files (.an0) to download.');

    File(p.join(targetDir.path, 'antichess-tb.sha256')).writeAsStringSync(manifestResp.body);

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
      print(
        'Found $skippedCount already downloaded files (${(alreadyDownloadedBytes / (1024 * 1024)).toStringAsFixed(1)} MB). '
        'Resuming remaining ${toDownload.length} files...',
      );
    }

    if (toDownload.isEmpty) {
      print('All ${files.length} tablebase files are already present and downloaded!');
      return;
    }

    int completedCount = skippedCount;
    int downloadedBytes = alreadyDownloadedBytes;
    final stopwatch = Stopwatch()..start();

    const concurrency = 8;
    int currentIndex = 0;

    Future<void> worker(int workerId) async {
      final workerHttpClient = HttpClient();
      workerHttpClient.connectionTimeout = const Duration(seconds: 15);

      while (true) {
        if (currentIndex >= toDownload.length) {
          workerHttpClient.close();
          return;
        }
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

              final finalFile = File(targetPath);
              if (finalFile.existsSync()) finalFile.deleteSync();
              outFile.renameSync(targetPath);

              success = true;
              completedCount++;

              if (completedCount % 25 == 0 || completedCount == files.length) {
                final elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
                final speedMBs = elapsedSec > 0
                    ? ((downloadedBytes - alreadyDownloadedBytes) / (1024 * 1024)) / elapsedSec
                    : 0.0;
                final totalMB = downloadedBytes / (1024 * 1024);
                print(
                  '[$completedCount/${files.length}] ${totalMB.toStringAsFixed(1)} MB | '
                  '${speedMBs.toStringAsFixed(1)} MB/s | ${file.filename}',
                );
              }
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
          print('[Error] Failed to download ${file.filename} after retries.');
        }
      }
    }

    print('Starting download with $concurrency parallel connections...');
    final workers = List.generate(concurrency, (i) => worker(i));
    await Future.wait(workers);

    stopwatch.stop();
    print('====================================================');
    print('Download completed in ${stopwatch.elapsed.inMinutes}m ${(stopwatch.elapsed.inSeconds % 60)}s!');
    print('Total files: $completedCount / ${files.length}');
    print('Directory: ${targetDir.absolute.path}');
    print('====================================================');
  } finally {
    client.close();
  }
}
