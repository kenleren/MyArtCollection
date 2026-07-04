import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

enum ArtworkImagePickMode { camera, gallery }

abstract class ArtworkImagePicker {
  Future<XFile?> pick(ArtworkImagePickMode mode);

  Future<XFile?> retrieveLostImage();
}

class SystemArtworkImagePicker implements ArtworkImagePicker {
  SystemArtworkImagePicker({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  static void configurePlatformPicker() {
    final implementation = ImagePickerPlatform.instance;
    if (implementation is ImagePickerAndroid) {
      implementation.useAndroidPhotoPicker = true;
    }
  }

  @override
  Future<XFile?> pick(ArtworkImagePickMode mode) {
    final source = switch (mode) {
      ArtworkImagePickMode.camera => ImageSource.camera,
      ArtworkImagePickMode.gallery => ImageSource.gallery,
    };

    return _picker.pickImage(source: source, imageQuality: 95);
  }

  @override
  Future<XFile?> retrieveLostImage() async {
    final response = await _picker.retrieveLostData();
    if (response.isEmpty) {
      return null;
    }
    if (response.exception != null) {
      throw response.exception!;
    }
    return response.file;
  }
}
