import 'dart:async';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/utils/ext.dart';

class FileDownloader {
  final String url;
  final String savePath;
  final int maxConcurrent;

  FileDownloader(this.url, this.savePath, {this.maxConcurrent = 4});

  int _currentBytes = 0;

  int _lastBytes = 0;

  late int _fileSize;

  final _dio = Dio();

  RandomAccessFile? _file;

  bool _isWriting = false;

  int _kChunkSize = 16 * 1024 * 1024;

  bool _canceled = false;

  late List<_DownloadBlock> _blocks;

  Future<void> _writeStatus() async {
    var file = File("$savePath.download");
    await file.writeAsString(
      "$_fileSize\n${_blocks.map((e) => e.toString()).join("\n")}",
    );
  }

  Future<bool> _readStatus() async {
    var file = File("$savePath.download");
    if (!await file.exists()) {
      return false;
    }

    try {
      var lines = await file.readAsLines();
      if (lines.isEmpty) {
        return false;
      }
      var size = int.tryParse(lines.first);
      if (size == null || size != _fileSize) {
        return false;
      }
      var blocks = <_DownloadBlock>[];
      var expectedStart = 0;
      for (var line in lines.skip(1)) {
        if (line.trim().isEmpty) {
          continue;
        }
        var block = _DownloadBlock.tryParse(line);
        if (block == null ||
            block.start != expectedStart ||
            block.end <= block.start ||
            block.end > _fileSize ||
            block.downloadedBytes < 0 ||
            block.downloadedBytes > block.end - block.start) {
          return false;
        }
        expectedStart = block.end;
        blocks.add(block);
      }
      if (blocks.isEmpty || expectedStart != _fileSize) {
        return false;
      }
      _blocks = blocks;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Resolve the file size with HEAD, falling back to a ranged GET for
  /// servers that do not support HEAD or do not return a content length.
  Future<int> _resolveFileSize() async {
    try {
      var res = await _dio.head(url);
      var length = res.headers["content-length"]?.first;
      var size = length == null ? null : int.tryParse(length);
      if (size != null && size > 0) {
        return size;
      }
    } catch (_) {
      // Fall through to a ranged GET.
    }

    var res = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {"Range": "bytes=0-0", "Accept-Encoding": "identity"},
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    var contentRange = res.headers["content-range"]?.first;
    if (contentRange != null) {
      var match = RegExp(r'/(\d+)\s*$').firstMatch(contentRange);
      var size = match == null ? null : int.tryParse(match.group(1)!);
      if (size != null && size > 0) {
        await _closeResponse(res.data);
        return size;
      }
    }
    var length = res.headers["content-length"]?.first;
    var size = length == null ? null : int.tryParse(length);
    // A 206 response with content-length 1 only contains the probed byte.
    if (size != null && size > 0 && !(res.statusCode == 206 && size == 1)) {
      await _closeResponse(res.data);
      return size;
    }
    await _closeResponse(res.data);
    throw Exception("Unable to determine the file size of $url");
  }

  static Future<void> _closeResponse(ResponseBody? body) async {
    if (body == null) {
      return;
    }
    var subscription = body.stream.listen(null);
    await subscription.cancel();
  }

  /// Create the file and write empty bytes.
  Future<void> _prepareFile({required bool resume}) async {
    var file = File(savePath);
    if (resume && await file.exists() && file.lengthSync() == _fileSize) {
      _file = await file.open(mode: FileMode.append);
      return;
    }

    if (await file.exists()) {
      await file.delete();
    }
    await file.create(recursive: true);
    _file = await file.open(mode: FileMode.append);
    await _file!.truncate(_fileSize);
  }

  Future<void> _createTasks() async {
    _fileSize = await _resolveFileSize();

    var statusFile = File("$savePath.download");
    var dataFile = File(savePath);
    var resume = false;
    if (await statusFile.exists()) {
      if (!await dataFile.exists() || dataFile.lengthSync() != _fileSize) {
        await statusFile.delete();
      } else {
        resume = await _readStatus();
        if (!resume) {
          await statusFile.delete();
        }
      }
    }

    await _prepareFile(resume: resume);

    if (resume) {
      _currentBytes = _blocks.fold<int>(
        0,
        (previousValue, element) => previousValue + element.downloadedBytes,
      );
      return;
    }

    if (_fileSize > 1024 * 1024 * 1024) {
      _kChunkSize = 64 * 1024 * 1024;
    } else if (_fileSize > 512 * 1024 * 1024) {
      _kChunkSize = 32 * 1024 * 1024;
    }

    _blocks = [];
    for (var i = 0; i < _fileSize; i += _kChunkSize) {
      var end = i + _kChunkSize;
      if (end > _fileSize) {
        _blocks.add(_DownloadBlock(i, _fileSize, 0, false));
      } else {
        _blocks.add(_DownloadBlock(i, i + _kChunkSize, 0, false));
      }
    }
  }

  Stream<DownloadingStatus> start() {
    var stream = StreamController<DownloadingStatus>();
    _download(stream);
    return stream.stream;
  }

  void _reportStatus(StreamController<DownloadingStatus> stream) {
    stream.add(DownloadingStatus(_currentBytes, _fileSize, 0));
  }

  void _download(StreamController<DownloadingStatus> resultStream) async {
    Timer? statusTimer;
    try {
      var proxy = await getProxy();
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          return HttpClient()
            ..findProxy = (uri) => proxy == null ? "DIRECT" : "PROXY $proxy";
        },
      );

      // get file size
      await _createTasks();

      if (_canceled) return;

      // check if file is downloaded
      if (_currentBytes >= _fileSize) {
        await _file!.close();
        _file = null;
        resultStream.add(DownloadingStatus(_fileSize, _fileSize, 0, true));
        resultStream.close();
        return;
      }

      _reportStatus(resultStream);

      statusTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_canceled || _currentBytes >= _fileSize) {
          timer.cancel();
          return;
        }
        resultStream.add(
          DownloadingStatus(
            _currentBytes,
            _fileSize,
            _currentBytes - _lastBytes,
          ),
        );
        _lastBytes = _currentBytes;
      });

      // start downloading
      await _scheduleDownload();
      statusTimer.cancel();
      if (_canceled) {
        resultStream.close();
        return;
      }
      await _file!.close();
      _file = null;
      var statusFile = File("$savePath.download");
      if (await statusFile.exists()) {
        await statusFile.delete();
      }

      // check if download is finished
      if (_currentBytes < _fileSize) {
        resultStream.addError(
          Exception(
            "Download failed: Expected $_fileSize bytes, "
            "but only $_currentBytes bytes downloaded.",
          ),
        );
        resultStream.close();
        return;
      }

      resultStream.add(DownloadingStatus(_currentBytes, _fileSize, 0, true));
      resultStream.close();
    } catch (e, s) {
      statusTimer?.cancel();
      await _file?.close();
      _file = null;
      if (!_canceled) {
        resultStream.addError(e, s);
      }
      resultStream.close();
    } finally {
      statusTimer?.cancel();
    }
  }

  Future<void> _scheduleDownload() async {
    var tasks = <Future>[];
    while (true) {
      if (_canceled) return;
      if (tasks.length >= maxConcurrent) {
        await Future.any(tasks);
      }
      final block = _blocks.firstWhereOrNull(
        (element) =>
            !element.downloading &&
            element.end - element.start > element.downloadedBytes,
      );
      if (block == null) {
        break;
      }
      block.downloading = true;
      var task = _fetchBlock(block);
      // Errors are propagated by [Future.any]/[Future.wait]. Attach a handler
      // here so removing finished tasks does not create an unhandled error.
      task.then((value) => tasks.remove(task), onError: (e, s) {});
      tasks.add(task);
    }
    await Future.wait(tasks);
  }

  Future<void> _fetchBlock(_DownloadBlock block) async {
    final start = block.start;
    final end = block.end;

    if (start >= _fileSize) {
      return;
    }

    var options = Options(
      responseType: ResponseType.stream,
      headers: {
        "Range": "bytes=${start + block.downloadedBytes}-${end - 1}",
        "Accept": "*/*",
        "Accept-Encoding": "deflate, gzip",
      },
      preserveHeaderCase: true,
    );
    var res = await _dio.get<ResponseBody>(url, options: options);
    if (_canceled) return;
    if (res.data == null) {
      throw Exception("Failed to block $start-$end");
    }

    var buffer = <int>[];
    await for (var data in res.data!.stream) {
      if (_canceled) return;
      buffer.addAll(data);
      if (buffer.length > 16 * 1024) {
        if (_isWriting) continue;
        _currentBytes += buffer.length;
        _isWriting = true;
        await _file!.setPosition(start + block.downloadedBytes);
        await _file!.writeFrom(buffer);
        block.downloadedBytes += buffer.length;
        buffer.clear();
        await _writeStatus();
        _isWriting = false;
      }
    }

    if (buffer.isNotEmpty) {
      while (_isWriting) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      _isWriting = true;
      _currentBytes += buffer.length;
      await _file!.setPosition(start + block.downloadedBytes);
      await _file!.writeFrom(buffer);
      block.downloadedBytes += buffer.length;
      await _writeStatus();
      _isWriting = false;
    }

    block.downloading = false;
  }

  Future<void> stop() async {
    _canceled = true;
    await _file?.close();
    _file = null;
  }
}

class DownloadingStatus {
  /// The current downloaded bytes
  final int downloadedBytes;

  /// The total bytes of the file
  final int totalBytes;

  /// Whether the download is finished
  final bool isFinished;

  /// The download speed in bytes per second
  final int bytesPerSecond;

  const DownloadingStatus(
    this.downloadedBytes,
    this.totalBytes,
    this.bytesPerSecond, [
    this.isFinished = false,
  ]);

  @override
  String toString() {
    return "Downloaded: $downloadedBytes/$totalBytes ${isFinished ? "Finished" : ""}";
  }
}

class _DownloadBlock {
  final int start;
  final int end;
  int downloadedBytes;
  bool downloading;

  _DownloadBlock(this.start, this.end, this.downloadedBytes, this.downloading);

  @override
  String toString() {
    return "$start-$end-$downloadedBytes";
  }

  static _DownloadBlock? tryParse(String str) {
    var parts = str.split("-");
    if (parts.length != 3) {
      return null;
    }
    var start = int.tryParse(parts[0]);
    var end = int.tryParse(parts[1]);
    var downloadedBytes = int.tryParse(parts[2]);
    if (start == null || end == null || downloadedBytes == null) {
      return null;
    }
    return _DownloadBlock(start, end, downloadedBytes, false);
  }
}
