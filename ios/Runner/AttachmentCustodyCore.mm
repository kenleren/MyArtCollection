#include "../../android/app/src/main/cpp/AttachmentCustody.cpp"

extern "C" const char* AttachmentCustodyExecute(
    const char* flutter_root,
    const char* operation,
    const char* source_path,
    const char* operation_id,
    const char* artwork_id,
    const char* attachment_id,
    const char* canonical_name) {
  static thread_local std::string output;
  output = custody::to_json(custody::execute(
      flutter_root == nullptr ? "" : flutter_root,
      operation == nullptr ? "" : operation,
      source_path == nullptr ? "" : source_path,
      operation_id == nullptr ? "" : operation_id,
      artwork_id == nullptr ? "" : artwork_id,
      attachment_id == nullptr ? "" : attachment_id,
      canonical_name == nullptr ? "" : canonical_name));
  return output.c_str();
}

extern "C" int AttachmentCustodyOpenExportPair(
    const char* flutter_root,
    const char* source_path,
    int* payload_descriptor,
    int* metadata_descriptor) {
  if (payload_descriptor == nullptr || metadata_descriptor == nullptr) return 0;
  auto pair = custody::open_export_pair(
      flutter_root == nullptr ? "" : flutter_root,
      source_path == nullptr ? "" : source_path);
  if (!pair.valid()) return 0;
  *payload_descriptor = pair.payload.release();
  *metadata_descriptor = pair.metadata.release();
  return 1;
}
