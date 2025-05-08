import 'dart:typed_data';
import 'package:googleapis/storage/v1.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'dart:developer';

class CloudStorageService {
  late StorageApi _storageApi;
  late String _bucketName;
  bool _isInitialized = false;

  CloudStorageService({required String projectId}) {
    _bucketName = '$projectId.appspot.com'; // Default bucket name pattern
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
    } catch (e) {
      log('Failed to initialize Cloud Storage: $e', error: e);
      throw Exception('Failed to initialize Cloud Storage: $e');
    }
  }

  /// Uploads a file to Google Cloud Storage.
  /// [folderPath] optional folder path in the bucket (e.g. "folder1/subfolder")
  /// [fileName] name of the file (e.g. "myfile.csv")
  /// Returns the public URL of the uploaded file.
  Future<String> uploadFile({
    required String fileName,
    required Uint8List fileBytes,
    String? folderPath,
    String? contentType,
  }) async {
    try {
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

      // Upload the file
      final response = await _storageApi.objects.insert(
        object,
        _bucketName,
        uploadMedia: media,
      );

      if (response.id == null) {
        throw Exception('Failed to upload file: No object ID returned');
      }

      // Return the public URL
      return 'https://storage.googleapis.com/$_bucketName/${response.name}';
    } catch (e) {
      throw Exception('Failed to upload file to Cloud Storage: $e');
    }
  }
}
