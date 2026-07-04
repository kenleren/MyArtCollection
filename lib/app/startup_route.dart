import 'app_routes.dart';
import 'storage/local_artwork_repository.dart';

Future<String> initialRouteForRepository(
  LocalArtworkRepository repository,
) async {
  final records = await repository.list();
  return records.isEmpty ? AppRoutes.splash : AppRoutes.collection;
}
