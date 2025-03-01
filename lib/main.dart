import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:mime/mime.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '文件共享',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: FileSharingScreen(),
    );
  }
}

class FileSharingScreen extends StatefulWidget {
  @override
  _FileSharingScreenState createState() => _FileSharingScreenState();
}

class _FileSharingScreenState extends State<FileSharingScreen> {
  String? selectedDirectory;
  HttpServer? _server;
  String _status = "服务器未运行";
  String _address = "";
  final int _port = 8080;

  Future<void> _pickDirectory() async {
    final status = await Permission.manageExternalStorage.request();
    print("Storage permission status: ${status.toString()}"); // 添加日志输出
    if (!status.isGranted) {
      _showSnackBar("需要存储权限");
      return;
    }

    final path = await FilePicker.platform.getDirectoryPath();
    if (path != null) {
      setState(() => selectedDirectory = path);
    }
  }

  Future<void> _toggleServer() async {
    if (_server != null) {
      await _server!.close();
      setState(() {
        _server = null;
        _status = "服务器已停止";
        _address = "";
      });
    } else {
      if (selectedDirectory == null) {
        _showSnackBar("请先选择目录");
        return;
      }

      try {
        final ip = await _getLocalIp();
        _server = await HttpServer.bind(ip, _port);

        setState(() {
          _status = "运行中: http://$ip:$_port";
          _address = "http://$ip:$_port";
        });

        _server!.listen(_handleRequest);
      } catch (e) {
        _showSnackBar("启动失败: $e");
      }
    }
  }

  Future<String> _getLocalIp() async {
    for (var interface in await NetworkInterface.list()) {
      for (var address in interface.addresses) {
        if (!address.isLoopback && address.type == InternetAddressType.IPv4) {
          return address.address;
        }
      }
    }
    return "0.0.0.0";
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final safePath = _validatePath(path);

      if (safePath == null) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..write('禁止访问')
          ..close();
        return;
      }

      final entityType = await FileSystemEntity.type(safePath); // 获取实体类型

      if (entityType != FileSystemEntityType.notFound) { // 检查实体是否存在 (文件或目录)
        if (entityType == FileSystemEntityType.directory) {
          await _sendDirectoryListing(request, safePath);
        } else if (entityType == FileSystemEntityType.file) { // 显式检查文件类型
          final fileEntity = File(safePath); // 为文件创建 File 对象
          await _sendFile(request, fileEntity);
        } else {
          // 处理其他类型 (如果需要，例如 FileSystemEntityType.link) - 可选
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('文件未找到')
            ..close();
        }
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('文件未找到')
          ..close();
      }
    } catch (e) {
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('服务器错误: $e')
        ..close();
    }
  }

  String? _validatePath(String uriPath) {
    print("原始 uriPath: $uriPath");

    if (uriPath == "/") { // Root path special case - MUST KEEP
      print("请求根路径 '/', 直接返回 selectedDirectory");
      print("路径验证成功，返回 selectedDirectory: $selectedDirectory");
      return selectedDirectory;
    }

    //  Ensure decodedPath does NOT start with a leading '/'
    String decodedPath = Uri.decodeComponent(uriPath);
    if (decodedPath.startsWith('/')) {
      decodedPath = decodedPath.substring(1); // Remove leading slash if present AFTER decoding
    }
    print("decodedPath (leading slash removed): $decodedPath");


    final fullPath = p.join(selectedDirectory!, decodedPath);
    print("fullPath: $fullPath");
    final normalizedPath = p.normalize(fullPath);
    print("normalizedPath: $normalizedPath");
    final normalizedSelectedDir = p.normalize(selectedDirectory!);
    print("normalizedSelectedDir: $normalizedSelectedDir");

    bool isWithin = p.isWithin(normalizedSelectedDir, normalizedPath);
    print("p.isWithin(normalizedSelectedDir, normalizedPath): $isWithin");

    if (!isWithin) {
      print("路径验证失败，返回 null");
      return null;
    }
    print("路径验证成功，返回 normalizedPath: $normalizedPath");
    return normalizedPath;
  }

  Future<void> _sendDirectoryListing(HttpRequest request, String path) async {
    final dir = Directory(path);
    final files = await dir.list().toList();

    request.response.headers.contentType = ContentType.html;
    request.response.write('''
      <html>
        <h1>目录: ${request.uri.path}</h1>
        ${files.map((e) => _buildFileLink(e, request.uri)).join()}
      </html>
    ''');
    await request.response.close();
  }

  String _buildFileLink(FileSystemEntity entity, Uri currentUri) {
    final name = p.basename(entity.path);
    // final link = currentUri.resolve(name).toString(); //  生成绝对路径链接
    final link = name; // 生成相对路径链接
    return '<a href="$link">$name</a><br>';
  }

  Future<void> _sendFile(HttpRequest request, File file) async {
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    request.response.headers
      ..contentType = ContentType.parse(mimeType)
      ..add('Content-Length', await file.length());

    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  void _showSnackBar(String text) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    _server?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('文件共享')),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: _pickDirectory,
              child: Text("选择目录"),
            ),
            SizedBox(height: 10),
            Text("当前目录: ${selectedDirectory ?? '未选择'}"),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _toggleServer,
              child: Text(_server == null ? "启动服务器" : "停止服务器"),
              style: ElevatedButton.styleFrom(
                backgroundColor: _server == null ? Colors.green : Colors.red,
              ),
            ),
            SizedBox(height: 20),
            Text("状态: $_status", style: TextStyle(fontSize: 16)),
            if (_address.isNotEmpty) ...[
              SizedBox(height: 10),
              SelectableText("访问地址: $_address"),
            ],
          ],
        ),
      ),
    );
  }
}