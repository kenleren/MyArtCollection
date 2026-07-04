import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/app_dependencies.dart';
import 'app/ai/on_device_ai_draft_service.dart';
import 'app/intake/artwork_image_picker.dart';
import 'app/startup_route.dart';
import 'app/storage/local_artwork_repository.dart';
import 'app/storage/local_attachment_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemArtworkImagePicker.configurePlatformPicker();

  final artworkRepository = await LocalArtworkRepository.open();
  final dependencies = AppDependencies(
    artworkRepository: artworkRepository,
    attachmentStore: await LocalAttachmentStore.open(),
    imagePicker: SystemArtworkImagePicker(),
    onDeviceAiDraftProvider: MethodChannelOnDeviceAiDraftProvider(),
  );

  runApp(
    MyArtCollectionApp(
      dependencies: dependencies,
      initialRoute: await initialRouteForRepository(artworkRepository),
    ),
  );
}
