import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

/// Extension with one [toShortString] method.
extension RoleToShortString on types.Role {
  /// Converts enum to the string equal to enum's name.
  String toShortString() => toString().split('.').last;
}

/// Extension with one [toShortString] method.
extension RoomTypeToShortString on types.RoomType {
  /// Converts enum to the string equal to enum's name.
  String toShortString() => toString().split('.').last;
}

/// Fetches user from Firebase and returns a promise.
Future<Map<String, dynamic>> fetchUser(
  FirebaseFirestore instance,
  String userId,
  String usersCollectionName, {
  String? role,
}) async {
  final doc = await instance.collection(usersCollectionName).doc(userId).get();

  final data = doc.data()!;

  data['createdAt'] = data['createdAt']?.millisecondsSinceEpoch;
  data['id'] = doc.id;
  data['lastSeen'] = data['lastSeen']?.millisecondsSinceEpoch;
  data['role'] = role;
  data['updatedAt'] = data['updatedAt']?.millisecondsSinceEpoch;

  return data;
}

Future<Map<String, dynamic>> fetchUserDatabase({required DatabaseReference usersRef, required String userId}) async {
  final Map<String, dynamic> data = {};
  final userRef = usersRef.child(userId);
  var snapshot = await userRef.child('id').get();
  if (snapshot.value == null) {
    return Future.error('No id parameter');
  } else {
    data['id'] = snapshot.value;
  }
  snapshot = await userRef.child('role').get();
  if (snapshot.value != 'admin') {
    return Future.error('Insufficient permissions');
  } else {
    data['role'] = snapshot.value;
  }
  snapshot = await userRef.child('email').get();
  if (snapshot.value != null) {
    data['email'] = snapshot.value;
  }
  snapshot = await userRef.child('name').get();
  if (snapshot.value != null) {
    data['name'] = snapshot.value;
  }
  snapshot = await userRef.child('registration').get();
  if (snapshot.value != null) {
    data['createdAt'] = formatToTimestamp(snapshot.value as String).millisecondsSinceEpoch;
  }
  data['imageUrl'] = null;
  data['lastSeen'] = null;

  return data;
}

Timestamp formatToTimestamp(String date) => Timestamp.fromDate(DateTime.parse(date));

/// Returns a list of [types.Room] created from Firebase query.
/// If room has 2 participants, sets correct room name and image.
Future<List<types.Room>> processRoomsQuery(
  String userId,
  QuerySnapshot<Map<String, dynamic>> query,
  DatabaseReference usersRef,
) async {
  final futures = query.docs.map(
    (doc) => processRoomDocument(doc, userId, usersRef),
  );

  return await Future.wait(futures);
}

/// Returns a [types.Room] created from Firebase document.
Future<types.Room> processRoomDocument(
  DocumentSnapshot<Map<String, dynamic>> doc,
  String userId,
  DatabaseReference usersRef,
) async {
  final data = doc.data()!;

  data['createdAt'] = data['createdAt']?.millisecondsSinceEpoch;
  data['id'] = doc.id;
  data['updatedAt'] = data['updatedAt']?.millisecondsSinceEpoch;

  var imageUrl = data['imageUrl'] as String?;
  var name = data['name'] as String?;
  final type = data['type'] as String;
  final userIds = data['userIds'] as List<dynamic>;
  final userRoles = data['userRoles'] as Map<String, dynamic>?;

  final users = await Future.wait(
    userIds.map(
      (userId) => fetchUserDatabase(usersRef: usersRef, userId: userId),
    ),
  );

  if (type == types.RoomType.direct.toShortString()) {
    try {
      final otherUser = users.firstWhere(
        (u) => u['id'] != userId,
      );

      imageUrl = otherUser['imageUrl'] as String?;
      name = '${otherUser['firstName'] ?? ''} ${otherUser['lastName'] ?? ''}'.trim();
    } catch (e) {
      // Do nothing if other user is not found, because he should be found.
      // Consider falling back to some default values.
    }
  }

  data['imageUrl'] = imageUrl;
  data['name'] = name;
  data['users'] = users;

  if (data['lastMessages'] != null) {
    final lastMessages = data['lastMessages'].map((lm) {
      final author = users.firstWhere(
        (u) => u['id'] == lm['authorId'],
        orElse: () => {'id': lm['authorId'] as String},
      );

      lm['author'] = author;
      lm['createdAt'] = lm['createdAt']?.millisecondsSinceEpoch;
      lm['id'] = lm['id'] ?? '';
      lm['updatedAt'] = lm['updatedAt']?.millisecondsSinceEpoch;

      return lm;
    }).toList();

    data['lastMessages'] = lastMessages;
  }

  return types.Room.fromJson(data);
}
