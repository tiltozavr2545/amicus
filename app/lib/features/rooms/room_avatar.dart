import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/sized_memory_image.dart';
import '../connections/connections_screen.dart';
import '../profile/profile_repository.dart';
import 'rooms_repository.dart';

/// The circle that stands for a room.
///
/// Three cases, in order: the room's own picture if its owner set one; the
/// other person's avatar in a two-person room, because that room *is* that
/// person (which is also why it has no picture of its own by design); and a
/// plain group mark for a group that has no picture yet.
///
/// A group deliberately does NOT borrow a member's face. It looked reasonable
/// and read as a lie: the room showed one person's photograph, so the row
/// looked like that person, and tapping it opened their profile — for a room
/// with five other people in it, picked by nothing but who joined first.
class RoomAvatar extends ConsumerWidget {
  const RoomAvatar({
    super.key,
    required this.room,
    required this.viewerId,
    this.radius,
  });

  final Room room;
  final String? viewerId;
  final double? radius;

  /// The person this circle depicts, or null when it depicts the room
  /// itself — which is every group, and a two-person room whose other side
  /// has left. Callers use it to decide where a tap goes.
  static RoomMember? personBehind(Room room, String? viewerId) {
    if (!room.isDirect || room.avatarPath != null) return null;
    final others = room.othersThan(viewerId);
    return others.isEmpty ? null : others.first;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = room.avatarPath;
    if (path == null) {
      final person = personBehind(room, viewerId);
      return person == null
          ? CircleAvatar(radius: radius, child: const Icon(Icons.group))
          : FriendAvatar(avatarPath: person.avatarPath);
    }

    // Same provider the profile avatars use: it downloads by path from the
    // same bucket and keeps the bytes briefly after the last widget lets go,
    // which is exactly the scroll-back-up case in the room list.
    final bytes = ref.watch(avatarBytesProvider(path)).value;
    final size = radius ?? 20;
    return CircleAvatar(
      radius: radius,
      backgroundImage: bytes == null
          ? null
          : sizedMemoryImage(context, bytes, logicalWidth: size * 2),
      child: bytes == null ? const Icon(Icons.group) : null,
    );
  }
}
