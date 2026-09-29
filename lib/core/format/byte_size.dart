/// Human-readable byte size shared by download rows and the reverse image
/// search header (moved out of `reverse_image_search_page.dart`, C5):
/// `1023 B`, `1.0 KiB`, `1.5 MiB` — one decimal for KiB/MiB.
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
