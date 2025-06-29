import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../ffmpeg_helper.dart';

class FFMpegHelper {
  static final FFMpegHelper _singleton = FFMpegHelper._internal();
  factory FFMpegHelper() => _singleton;
  FFMpegHelper._internal();
  static FFMpegHelper get instance => _singleton;

  //
  final String _ffmpegUrl =
      "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip";
  String? _tempFolderPath;
  String? _ffmpegBinDirectory;
  String? _ffmpegInstallationPath;
  String? _ffmpegDownloadUrl;
  bool _actived = false;

  Future<void> initialize({
    Directory? ffmpegBaseDir,
    String? ffmpegDownloadUrl,
  }) async {
    _ffmpegDownloadUrl = ffmpegDownloadUrl;
    if (Platform.isWindows) {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String appName = packageInfo.appName;
      Directory tempDir = await getTemporaryDirectory();
      _tempFolderPath = path.join(tempDir.path, "ffmpeg");
      Directory ffmpegInstallDir = ffmpegBaseDir ?? await getApplicationDocumentsDirectory();
      _ffmpegInstallationPath = path.join(ffmpegInstallDir.path, appName, "ffmpeg");
      _ffmpegBinDirectory = path.join(_ffmpegInstallationPath!, "ffmpeg-master-latest-win64-gpl", "bin");
    }
  }

  Future<bool> isFFMpegPresent() async {
    if (Platform.isWindows) {
      if ((_ffmpegBinDirectory == null) || (_tempFolderPath == null)) {
        await initialize();
      }
      File ffmpeg = File(path.join(_ffmpegBinDirectory!, "ffmpeg.exe"));
      File ffprobe = File(path.join(_ffmpegBinDirectory!, "ffprobe.exe"));
      if ((await ffmpeg.exists()) && (await ffprobe.exists())) {
        return true;
      } else {
        return false;
      }
    } else if (Platform.isLinux) {
      try {
        Process process = await Process.start(
          'ffmpeg',
          ['--help'],
        );
        return await process.exitCode == ReturnCode.success;
      } catch (e) {
        return false;
      }
    } else {
      return true;
    }
  }

  static Future<void> extractZipFileIsolate(Map data) async {
    try {
      String? zipFilePath = data['zipFile'];
      String? targetPath = data['targetPath'];
      if ((zipFilePath != null) && (targetPath != null)) {
        await extractFileToDisk(zipFilePath, targetPath);
      }
    } catch (e) {
      return;
    }
  }

  Future<FFMpegHelperSession> runAsync(
    FFMpegCommand command, {
    Function(Statistics statistics)? statisticsCallback,
    Function(File? outputFile)? onComplete,
  }) async {
    if (Platform.isWindows || Platform.isLinux) {
      return _runAsyncOnWindows(
        command,
        statisticsCallback: statisticsCallback,
        onComplete: onComplete,
      );
    } else {
      return _runAsyncOnNonWindows(
        command,
        statisticsCallback: statisticsCallback,
        onComplete: onComplete,
      );
    }
  }

  Future<FFMpegHelperSession> _runAsyncOnWindows(
    FFMpegCommand command, {
    Function(Statistics statistics)? statisticsCallback,
    Function(File? outputFile)? onComplete,
  }) async {
    Process process = await _startWindowsProcess(
      command,
      statisticsCallback: statisticsCallback,
    );
    process.exitCode.then((value) {
      if (value == ReturnCode.success) {
        onComplete?.call(File(command.outputFilepath));
      } else {
        onComplete?.call(null);
      }
    });
    return FFMpegHelperSession(
      windowSession: process,
      cancelSession: () async {
        process.kill();
      },
    );
  }

  Future<FFMpegHelperSession> _runAsyncOnNonWindows(
    FFMpegCommand command, {
    Function(Statistics statistics)? statisticsCallback,
    Function(File? outputFile)? onComplete,
  }) async {
    FFmpegSession sess = await FFmpegKit.executeAsync(
      command.toCli().join(' '),
      (FFmpegSession session) async {
        final code = await session.getReturnCode();
        if (code?.isValueSuccess() == true) {
          onComplete?.call(File(command.outputFilepath));
        } else {
          onComplete?.call(null);
        }
      },
      null,
      (Statistics statistics) {
        statisticsCallback?.call(statistics);
      },
    );
    return FFMpegHelperSession(
      nonWindowSession: sess,
      cancelSession: () async {
        await sess.cancel();
      },
    );
  }

  Future<File?> runSync(
    FFMpegCommand command, {
    Function(Statistics statistics)? statisticsCallback,
  }) async {
    if (Platform.isWindows || Platform.isLinux) {
      return _runSyncOnWindows(
        command,
        statisticsCallback: statisticsCallback,
      );
    } else {
      return _runSyncOnNonWindows(
        command,
        statisticsCallback: statisticsCallback,
      );
    }
  }

  Future<Process> _startWindowsProcess(
    FFMpegCommand command, {
    Function(Statistics statistics)? statisticsCallback,
  }) async {
    String ffmpeg = 'ffmpeg';
    if ((_ffmpegBinDirectory != null) && (Platform.isWindows)) {
      ffmpeg = path.join(_ffmpegBinDirectory!, "ffmpeg.exe");
    }
    Process process = await Process.start(
      ffmpeg,
      command.toCli(),
    );
    process.stdout.transform(utf8.decoder).listen((String event) {
      List<String> data = event.split("\n");
      Map<String, dynamic> temp = {};
      for (String element in data) {
        List<String> kv = element.split("=");
        if (kv.length == 2) {
          temp[kv.first] = kv.last;
        }
      }
      if (temp.isNotEmpty) {
        try {
          statisticsCallback?.call(Statistics(
            process.pid,
            int.tryParse(temp['frame']) ?? 0,
            double.tryParse(temp['fps']) ?? 0.0,
            double.tryParse(temp['stream_0_0_q']) ?? 0.0,
            int.tryParse(temp['total_size']) ?? 0,
            int.tryParse(temp['out_time_us']) ?? 0,
            // 2189.6kbits/s => 2189.6
            double.tryParse(temp['bitrate']?.replaceAll(RegExp('[a-z/]'), '')) ?? 0.0,
            // 2.15x => 2.15
            double.tryParse(temp['speed']?.replaceAll(RegExp('[a-z/]'), '')) ?? 0.0,
          ));
        } catch (e) {
          if (kDebugMode) {
            print(e);
          }
        }
      }
    });
    process.stderr.transform(utf8.decoder).listen((event) {
      if (kDebugMode) {
        print("stderr: $event");
      }
    });
    return process;
  }

  Future<File?> _runSyncOnWindows(
    FFMpegCommand command, {
    Function(Statistics statistics)? statisticsCallback,
  }) async {
    Process process = await _startWindowsProcess(
      command,
      statisticsCallback: statisticsCallback,
    );
    if (await process.exitCode == ReturnCode.success) {
      return File(command.outputFilepath);
    } else {
      return null;
    }
  }

  Future<File?> _runSyncOnNonWindows(
    FFMpegCommand command, {
    Function(Statistics statistics)? statisticsCallback,
  }) async {
    Completer<File?> completer = Completer<File?>();
    await FFmpegKit.executeAsync(
      command.toCli().join(' '),
      (FFmpegSession session) async {
        final code = await session.getReturnCode();
        if (code?.isValueSuccess() == true) {
          if (!completer.isCompleted) {
            completer.complete(File(command.outputFilepath));
          }
        } else {
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        }
      },
      null,
      (Statistics statistics) {
        statisticsCallback?.call(statistics);
      },
    );
    return completer.future;
  }

  Future<MediaInformation?> runProbeFromPath(String filePath) async {
    if (Platform.isWindows || Platform.isLinux) {
      return _runProbeOnWindows(filePath);
    } else {
      return _runProbeOnNonWindows(filePath);
    }
  }

  Future<MediaInformation?> _runProbeOnNonWindows(String filePath) async {
    Completer<MediaInformation?> completer = Completer<MediaInformation?>();
    try {
      await FFprobeKit.getMediaInformationAsync(filePath, (MediaInformationSession session) async {
        final MediaInformation? information = session.getMediaInformation();
        if (information != null) {
          if (!completer.isCompleted) {
            completer.complete(information);
          }
        } else {
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        }
      });
    } catch (e) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }
    return completer.future;
  }

  Future<MediaInformation?> runProbeProcess(List<String> arguments) async {
    if (!_actived) {
      return null;
    }
    String ffprobe = 'ffprobe';
    if (((_ffmpegBinDirectory != null) && (Platform.isWindows))) {
      ffprobe = path.join(_ffmpegBinDirectory!, "ffprobe.exe");
    }
    final result = await Process.run(ffprobe, arguments,stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.stdout == null || result.stdout is! String || (result.stdout as String).isEmpty) {
      return null;
    }
    if (result.exitCode == ReturnCode.success) {
      try {
        final json = jsonDecode(result.stdout);
        return MediaInformation(json);
      } catch (e) {
        return null;
      }
    } else {
      return null;
    }
  }

  Future<MediaInformation?> _runProbeOnWindows(String filePath) async {
    String ffprobe = 'ffprobe';
    if (((_ffmpegBinDirectory != null) && (Platform.isWindows))) {
      ffprobe = path.join(_ffmpegBinDirectory!, "ffprobe.exe");
    }
    final result = await Process.run(ffprobe, [
      '-v',
      'quiet',
      '-print_format',
      'json',
      '-show_format',
      '-show_streams',
      '-show_chapters',
      filePath,
    ]);
    if (result.stdout == null || result.stdout is! String || (result.stdout as String).isEmpty) {
      return null;
    }
    if (result.exitCode == ReturnCode.success) {
      try {
        final json = jsonDecode(result.stdout);
        return MediaInformation(json);
      } catch (e) {
        return null;
      }
    } else {
      return null;
    }
  }

  Future<FFMpegHelperSession> getThumbnailFileAsync({
    required String videoPath,
    required Duration fromDuration,
    required String outputPath,
    String? ffmpegPath,
    FilterGraph? filterGraph,
    int qualityPercentage = 100,
    Function(Statistics statistics)? statisticsCallback,
    Function(File? outputFile)? onComplete,
  }) async {
    int quality = 1;
    if ((qualityPercentage > 0) && (qualityPercentage < 100)) {
      quality = (((100 - qualityPercentage) * 31) / 100).ceil();
    }
    final FFMpegCommand cliCommand = FFMpegCommand(
      returnProgress: true,
      inputs: [FFMpegInput.asset(videoPath)],
      args: [
        const OverwriteArgument(),
        SeekArgument(fromDuration),
        const CustomArgument(["-frames:v", '1']),
        CustomArgument(["-q:v", '$quality']),
      ],
      outputFilepath: outputPath,
      filterGraph: filterGraph,
    );
    FFMpegHelperSession session = await runAsync(
      cliCommand,
      onComplete: onComplete,
      statisticsCallback: statisticsCallback,
    );
    return session;
  }

  Future<File?> getThumbnailFileSync({
    required String videoPath,
    required Duration fromDuration,
    required String outputPath,
    String? ffmpegPath,
    FilterGraph? filterGraph,
    int qualityPercentage = 100,
    Function(Statistics statistics)? statisticsCallback,
    Function(File? outputFile)? onComplete,
  }) async {
    int quality = 1;
    if ((qualityPercentage > 0) && (qualityPercentage < 100)) {
      quality = (((100 - qualityPercentage) * 31) / 100).ceil();
    }
    final FFMpegCommand cliCommand = FFMpegCommand(
      returnProgress: true,
      inputs: [FFMpegInput.asset(videoPath)],
      args: [
        const OverwriteArgument(),
        SeekArgument(fromDuration),
        const CustomArgument(["-frames:v", '1']),
        CustomArgument(["-q:v", '$quality']),
      ],
      outputFilepath: outputPath,
      filterGraph: filterGraph,
    );
    File? session = await runSync(
      cliCommand,
      statisticsCallback: statisticsCallback,
    );
    return session;
  }

  Future<bool> setupFFMpegOnWindows({
    CancelToken? cancelToken,
    void Function(FFMpegProgress progress)? onProgress,
    Map<String, dynamic>? queryParameters,
  }) async {
    if (Platform.isWindows) {
      if ((_ffmpegBinDirectory == null) || (_tempFolderPath == null)) {
        await initialize();
      }
      Directory tempDir = Directory(_tempFolderPath!);
      if (await tempDir.exists() == false) {
        await tempDir.create(recursive: true);
      }
      Directory installationDir = Directory(_ffmpegInstallationPath!);
      if (await installationDir.exists() == false) {
        await installationDir.create(recursive: true);
      }
      final String ffmpegZipPath = path.join(_tempFolderPath!, "ffmpeg.zip");
      final File tempZipFile = File(ffmpegZipPath);
      if (await tempZipFile.exists() == false) {
        try {
          Dio dio = Dio();
          Response response = await dio.download(
            _ffmpegDownloadUrl ?? _ffmpegUrl,
            ffmpegZipPath,
            cancelToken: cancelToken,
            onReceiveProgress: (int received, int total) {
              onProgress?.call(FFMpegProgress(
                downloaded: received,
                fileSize: total,
                phase: FFMpegProgressPhase.downloading,
              ));
            },
            queryParameters: queryParameters,
          );
          if (response.statusCode == HttpStatus.ok) {
            onProgress?.call(FFMpegProgress(
              downloaded: 0,
              fileSize: 0,
              phase: FFMpegProgressPhase.decompressing,
            ));
            await compute(extractZipFileIsolate, {
              'zipFile': tempZipFile.path,
              'targetPath': _ffmpegInstallationPath,
            });
            onProgress?.call(FFMpegProgress(
              downloaded: 0,
              fileSize: 0,
              phase: FFMpegProgressPhase.active,
            ));
            _actived = true;
            return true;
          } else {
            onProgress?.call(FFMpegProgress(
              downloaded: 0,
              fileSize: 0,
              phase: FFMpegProgressPhase.inactive,
            ));
            return false;
          }
        } catch (e) {
          onProgress?.call(FFMpegProgress(
            downloaded: 0,
            fileSize: 0,
            phase: FFMpegProgressPhase.inactive,
          ));
          return false;
        }
      } else {
        var directory = Directory(_ffmpegBinDirectory!);
        if (await directory.exists()) {
          onProgress?.call(FFMpegProgress(
            downloaded: 0,
            fileSize: 0,
            phase: FFMpegProgressPhase.active,
          ));
          _actived = true;
          return true;
        }
        onProgress?.call(FFMpegProgress(
          downloaded: 0,
          fileSize: 0,
          phase: FFMpegProgressPhase.decompressing,
        ));
        try {
          await compute(extractZipFileIsolate, {
            'zipFile': tempZipFile.path,
            'targetPath': _ffmpegInstallationPath,
          });
          onProgress?.call(FFMpegProgress(
            downloaded: 0,
            fileSize: 0,
            phase: FFMpegProgressPhase.active,
          ));
          _actived = true;
          return true;
        } catch (e) {
          onProgress?.call(FFMpegProgress(
            downloaded: 0,
            fileSize: 0,
            phase: FFMpegProgressPhase.inactive,
          ));
          return false;
        }
      }
    } else {
      onProgress?.call(FFMpegProgress(
        downloaded: 0,
        fileSize: 0,
        phase: FFMpegProgressPhase.inactive,
      ));
      return true;
    }
  }
}
