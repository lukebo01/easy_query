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
    _bucketName = 'bronze-layer-bucket'; // Questo sarà l'unico bucket utilizzabile
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
          log('- ${bucket.name}${bucket.name == _bucketName ? " (active upload bucket)" : ""}');
        }
      }
      
      return bucketNames;
    } catch (e) {
      log('Error listing buckets: $e', error: e);
      throw Exception('Failed to list buckets: $e');
    }
  }
  
  /// Metodo per visualizzare la gerarchia delle cartelle in un bucket
  Future<Map<String, List<String>>> listFolderHierarchy({String? prefix}) async {
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
      throw Exception('Cloud Storage service not initialized. Call initialize() first.');
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
}
