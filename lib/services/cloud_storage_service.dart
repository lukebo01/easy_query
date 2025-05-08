import 'dart:typed_data';
import 'package:googleapis/storage/v1.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'dart:developer';

class CloudStorageService {
  late StorageApi _storageApi;
  late String _bucketName; // Modificato a final per impedire modifiche
  bool _isInitialized = false;
  String _projectId = '';

  CloudStorageService({required String projectId}) {
    _projectId = projectId;
    _bucketName =
        'bronze-layer-bucket'; // Questo sarà l'unico bucket utilizzabile
  }

  Future<void> initialize(String credentialsJson) async {
    try {
      final credentials = ServiceAccountCredentials.fromJson(credentialsJson);
      final client = await clientViaServiceAccount(credentials, [
        StorageApi.devstorageFullControlScope,
      ]);
      _storageApi = StorageApi(client);
      _isInitialized = true;
      log('Cloud Storage service initialized successfully');

      // Stampa tutti i bucket disponibili
      await listBuckets();
    } catch (e) {
      log('Failed to initialize Cloud Storage: $e', error: e);
      throw Exception('Failed to initialize Cloud Storage: $e');
    }
  }

  /// Elenca tutti i bucket disponibili nel progetto e ritorna la lista
  Future<List<String>> listBuckets() async {
    _checkInitialized();

    try {
      final response = await _storageApi.buckets.list(_projectId);
      final buckets = response.items ?? [];

      List<String> bucketNames = [];
      log('Available buckets (note: uploads will always go to bronze bucket):');
      for (var bucket in buckets) {
        if (bucket.name != null) {
          bucketNames.add(bucket.name!);
          log(
            '- ${bucket.name}${bucket.name == _bucketName ? " (active upload bucket)" : ""}',
          );
        }
      }

      return bucketNames;
    } catch (e) {
      log('Error listing buckets: $e', error: e);
      throw Exception('Failed to list buckets: $e');
    }
  }

  /// Metodo per visualizzare la gerarchia delle cartelle in un bucket
  Future<Map<String, List<String>>> listFolderHierarchy({
    String? prefix,
  }) async {
    _checkInitialized();

    try {
      Map<String, List<String>> hierarchy = {};
      String? pageToken;

      do {
        final response = await _storageApi.objects.list(
          _bucketName,
          prefix: prefix,
          delimiter: '/',
          pageToken: pageToken,
        );

        // Ottieni le cartelle (prefixes)
        if (response.prefixes != null) {
          for (var folderPrefix in response.prefixes!) {
            String folderName = folderPrefix;
            if (prefix != null) {
              folderName = folderName.substring(prefix.length);
            }

            // Rimuovi l'ultimo slash se presente
            if (folderName.endsWith('/')) {
              folderName = folderName.substring(0, folderName.length - 1);
            }

            log('Folder: $folderName');

            // Ricorsivamente ottieni la struttura interna della cartella
            hierarchy[folderName] = [];

            // Ottieni i file nella cartella
            final filesResponse = await _storageApi.objects.list(
              _bucketName,
              prefix: folderPrefix,
              delimiter: '/',
            );

            if (filesResponse.items != null) {
              for (var file in filesResponse.items!) {
                if (file.name != null && !file.name!.endsWith('/')) {
                  String fileName = file.name!.split('/').last;
                  hierarchy[folderName]!.add(fileName);
                  log('  - File: $fileName');
                }
              }
            }
          }
        }

        // Ottieni i file nella cartella root (se nessun prefix specificato)
        if (response.items != null && prefix == null) {
          hierarchy['root'] = [];
          for (var file in response.items!) {
            if (file.name != null && !file.name!.contains('/')) {
              hierarchy['root']!.add(file.name!);
              log('File in root: ${file.name}');
            }
          }
        }

        pageToken = response.nextPageToken;
      } while (pageToken != null);

      return hierarchy;
    } catch (e) {
      log('Error listing folder hierarchy: $e', error: e);
      throw Exception('Failed to list folder hierarchy: $e');
    }
  }

  /// Verifica se il servizio è stato inizializzato
  void _checkInitialized() {
    if (!_isInitialized) {
      throw Exception(
        'Cloud Storage service not initialized. Call initialize() first.',
      );
    }
  }

  /// Uploads a file to Google Cloud Storage in the bronze bucket.
  /// [folderPath] optional folder path in the bucket (e.g. "folder1/subfolder")
  /// [fileName] name of the file (e.g. "myfile.csv")
  /// Returns the public URL of the uploaded file.
  Future<String> uploadFile({
    required String fileName,
    required Uint8List fileBytes,
    String? folderPath,
    String? contentType,
  }) async {
    _checkInitialized();

    try {
      // Stampa i bucket disponibili e la gerarchia del bucket bronze prima dell'upload
      log('Starting upload to bronze bucket: $_bucketName');
      log('Available folders in bronze bucket:');
      await listFolderHierarchy();

      // Sanitize and build the full object path
      final String sanitizedFileName = fileName.replaceAll(
        RegExp(r'[^\w\s\-\.\/]'),
        '_',
      );
      String fullPath = sanitizedFileName;

      if (folderPath != null && folderPath.isNotEmpty) {
        // Sanitize folder path and ensure it doesn't start/end with slash
        final String sanitizedPath = folderPath
            .replaceAll(RegExp(r'[^\w\s\-\.\/]'), '_')
            .replaceAll(RegExp(r'^\/+|\/+$'), '');

        fullPath = '$sanitizedPath/$sanitizedFileName';
      }

      // Create a media object from the file bytes
      final media = Media(
        Stream.value(fileBytes),
        fileBytes.length,
        contentType: contentType ?? 'application/octet-stream',
      );

      // Create the object to be uploaded with the full path
      final object = Object(name: fullPath, bucket: _bucketName);

      log('Uploading file to path: $fullPath in bucket: $_bucketName');

      // Upload the file
      final response = await _storageApi.objects.insert(
        object,
        _bucketName,
        uploadMedia: media,
      );

      if (response.id == null) {
        throw Exception('Failed to upload file: No object ID returned');
      }

      log('Upload successful. Object ID: ${response.id}');

      // Return the public URL
      return 'https://storage.googleapis.com/$_bucketName/${response.name}';
    } catch (e) {
      log('Failed to upload file to Cloud Storage: $e', error: e);
      throw Exception('Failed to upload file to Cloud Storage: $e');
    }
  }

  /// Returns a formatted string representing the bucket structure in a tree-like format
  Future<String> getAllFilesTree({String bucketName = ''}) async {
    _checkInitialized();
    final targetBucket = bucketName.isEmpty ? _bucketName : bucketName;

    try {
      StringBuffer treeBuilder = StringBuffer();
      treeBuilder.writeln('ROOT: gs://$targetBucket/');

      Map<String, List<Object>> folderContents = {};
      String? pageToken;

      do {
        final response = await _storageApi.objects.list(
          targetBucket,
          pageToken: pageToken,
        );

        if (response.items != null) {
          for (var item in response.items!) {
            if (item.name == null) continue;

            final parts = item.name!.split('/');
            if (parts.length > 1) {
              final folderPath = parts.sublist(0, parts.length - 1).join('/');
              if (!folderContents.containsKey(folderPath)) {
                folderContents[folderPath] = [];
              }
              folderContents[folderPath]!.add(item);
            } else if (parts.length == 1) {
              if (!folderContents.containsKey('')) {
                folderContents[''] = [];
              }
              folderContents['']!.add(item);
            }
          }
        }

        pageToken = response.nextPageToken;
      } while (pageToken != null);

      final sortedFolders = folderContents.keys.toList()..sort();

      for (var i = 0; i < sortedFolders.length; i++) {
        final folder = sortedFolders[i];
        final isLastFolder = i == sortedFolders.length - 1;
        final items = folderContents[folder]! as List<Object>;

        if (folder.isNotEmpty) {
          treeBuilder.writeln('├── ${folder}/');

          for (var j = 0; j < items.length; j++) {
            final item = items[j];
            final isLastFile = j == items.length - 1;
            final filePrefix = isLastFile ? '    └──' : '    ├──';

            // Get metadata for the file
            final metadata = await getFileMetadata(item.name!);
            final metaString = _formatMetadata(metadata);

            treeBuilder.writeln(
              '$filePrefix ${item.name!.split('/').last} ($metaString)',
            );
          }
        } else {
          for (var j = 0; j < items.length; j++) {
            final item = items[j];
            final isLastFile = j == items.length - 1;
            final filePrefix = isLastFile ? '└──' : '├──';

            final metadata = await getFileMetadata(item.name!);
            final metaString = _formatMetadata(metadata);

            treeBuilder.writeln('$filePrefix ${item.name!} ($metaString)');
          }
        }
      }

      return treeBuilder.toString();
    } catch (e) {
      log('Error generating files tree: $e', error: e);
      throw Exception('Failed to generate files tree: $e');
    }
  }

  String _formatMetadata(Object metadata) {
    if (metadata is! Object) return '';

    final parts = <String>[];
    if (metadata.size != null)
      parts.add(_formatSize(int.parse(metadata.size!)));
    if (metadata.contentType != null) parts.add(metadata.contentType!);
    if (metadata.timeCreated != null)
      parts.add(_formatDate(metadata.timeCreated!));

    return parts.join(', ');
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  //TODO metodo per gettare i metadati di un file
  Future<Object> getFileMetadata(String fileName) async {
    _checkInitialized();

    try {
      final response = await _storageApi.objects.get(_bucketName, fileName);
      return Future.value(response as Object);
    } catch (e) {
      log('Error fetching file metadata: $e', error: e);
      throw Exception('Failed to fetch file metadata: $e');
    }
  }
}
