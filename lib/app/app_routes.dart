class AppRoutes {
  static const splash = '/splash';
  static const onboarding = '/onboarding';
  static const onboardingPrivacy = '/onboarding/privacy';
  static const onboardingFirstAdd = '/onboarding/first-add';

  static const collection = '/collection';
  static const collectionAdd = '/collection/add';
  static const collectionImportCsv = '/collection/import-csv';
  static const collectionIncomplete = '/collection/incomplete';
  static const collectionReport = '/collection/report';
  static const collectionSettings = '/collection/settings';
  static const collectionGroups = '/collection/groups';

  static const capture = '/capture';
  static const import = '/import';

  static const settings = '/settings';
  static const settingsPrivacy = '/settings/privacy';
  static const settingsStorage = '/settings/storage';
  static const settingsExport = '/settings/export';
  static const settingsBackup = '/settings/backup';
  static const billing = '/billing';

  static String artwork(String artworkId) => '/artwork/$artworkId';
  static String artworkDraft(String artworkId) => '${artwork(artworkId)}/draft';
  static String artworkEdit(String artworkId) => '${artwork(artworkId)}/edit';
  static String artworkDetails(String artworkId) =>
      '${artwork(artworkId)}/details';
  static String artworkDocuments(String artworkId) =>
      '${artwork(artworkId)}/documents';
  static String artworkSupportingPhotoCapture(String artworkId) =>
      '${artwork(artworkId)}/supporting-photo/capture';
  static String artworkSupportingPhotoImport(String artworkId) =>
      '${artwork(artworkId)}/supporting-photo/import';
  static String artworkReportPreview(String artworkId) =>
      '${artwork(artworkId)}/report-preview';
}
