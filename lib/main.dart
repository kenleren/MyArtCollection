import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/app_dependencies.dart';
import 'app/intake/artwork_image_picker.dart';
import 'app/storage/local_artwork_repository.dart';
import 'app/storage/local_attachment_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemArtworkImagePicker.configurePlatformPicker();

  final dependencies = AppDependencies(
    artworkRepository: await LocalArtworkRepository.open(),
    attachmentStore: await LocalAttachmentStore.open(),
    imagePicker: SystemArtworkImagePicker(),
  );

  runApp(MyArtCollectionApp(dependencies: dependencies));
}
