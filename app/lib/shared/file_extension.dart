/// Extracts a lowercase file extension from [name], defaulting to `jpg`.
///
/// Some gallery/image sources hand back an extensionless name (or one whose
/// only dot isn't really an extension separator). Splitting on `.` blindly then
/// yields the whole filename as the "extension", producing a garbage storage
/// object name like `avatar_123.IMG_4021`. This guards those cases.
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return 'jpg';
  final ext = name.substring(dot + 1).toLowerCase();
  return ext.length <= 5 ? ext : 'jpg';
}
