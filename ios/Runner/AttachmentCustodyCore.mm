#include "../../android/app/src/main/cpp/AttachmentCustody.cpp"

extern "C" const char* AttachmentCustodyExecute(
    const char* flutter_root,
    const char* operation,
    const char* source_path,
    const char* artwork_id,
    const char* attachment_id,
    const char* canonical_name) {
  static thread_local std::string output;
  output = custody::to_json(custody::execute(
      flutter_root == nullptr ? "" : flutter_root,
      operation == nullptr ? "" : operation,
      source_path == nullptr ? "" : source_path,
      artwork_id == nullptr ? "" : artwork_id,
      attachment_id == nullptr ? "" : attachment_id,
      canonical_name == nullptr ? "" : canonical_name));
  return output.c_str();
}
